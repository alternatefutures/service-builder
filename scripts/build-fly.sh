#!/usr/bin/env bash
# build-fly.sh — Fly.io Machine entrypoint.
#
# Boots a local dockerd inside the Firecracker microVM, waits until the
# socket is responsive, then exec's the existing `build.sh`. Same env
# contract as build.sh — DOCKER_HOST is left unset so docker uses the
# default unix socket at /var/run/docker.sock.
#
# Persistent cache (Phase 1 — Fly Volume):
#   If $AF_CACHE_ROOT is set and points at a real mount, we use it to
#   persist dockerd's data-root across machines. That's what makes
#   repeat builds fast: docker image store, buildkit's snapshotter,
#   and all `--mount=type=cache` dirs live under data-root, so they
#   survive machine reaping. The volume is created once
#   (`fly volumes create af_build_cache_0 -a af-builders`) and attached
#   by `flyioBuilder.ts` on every spawn.
#
#   If $AF_CACHE_ROOT is unset or the mount is missing, we fall back
#   to ephemeral state (dockerd writes to the root filesystem, gets
#   reaped with the machine). Same behavior as pre-volume — slow but
#   not broken.
#
# Auto-destroy: the Fly Machine is created with `auto_destroy: true`
# and `restart.policy = "no"`, so when this script exits (success OR
# failure) the entire microVM is reaped. Fly detaches the volume as
# part of destruction so the next machine can claim it.

set -euo pipefail

echo "[build-fly] starting embedded dockerd…"

# ---------------------------------------------------------------------------
# Resolve dockerd data-root.
# ---------------------------------------------------------------------------
# Prefer a mounted Fly Volume when available. We distinguish "volume
# attached" from "AF_CACHE_ROOT happened to be set but is just a
# regular dir" by checking `findmnt` — this avoids writing docker's
# image store onto the root filesystem if the mount silently failed
# (would fill up the Firecracker rootfs and wedge the build).
DATA_ROOT_FLAG=""
if [ -n "${AF_CACHE_ROOT:-}" ]; then
    if findmnt -T "$AF_CACHE_ROOT" >/dev/null 2>&1; then
        DOCKER_DATA_ROOT="$AF_CACHE_ROOT/dockerd"
        mkdir -p "$DOCKER_DATA_ROOT"
        DATA_ROOT_FLAG="--data-root=$DOCKER_DATA_ROOT"
        echo "[build-fly] using persistent cache at $AF_CACHE_ROOT"
        # First-boot friendliness: print free space on the volume so a
        # "full volume" failure mode is obvious in the build logs
        # rather than surfacing as a cryptic ENOSPC from buildkit.
        df -h "$AF_CACHE_ROOT" | tail -n 1 | awk '{printf "[build-fly] volume: size=%s used=%s avail=%s use=%s\n", $2,$3,$4,$5}'
    else
        echo "[build-fly] WARNING: AF_CACHE_ROOT=$AF_CACHE_ROOT is set but not a mount — falling back to ephemeral dockerd state" >&2
    fi
fi

# DNS: Fly Machines hand the VM a working /etc/resolv.conf, but dockerd
# doesn't propagate that into the default bridge network it creates for
# `docker build` steps. Without --dns flags, nested build containers
# can't resolve ANYTHING — most visibly, `nix-env -if` fetching
# nixpkgs archives from github.com dies with "Could not resolve host".
# Pin to Google + Cloudflare public resolvers; they're always reachable
# from Fly's 6PN network and have no meaningful failure mode here.
nohup dockerd-entrypoint.sh dockerd \
    --host=unix:///var/run/docker.sock \
    --log-level=warn \
    --dns=8.8.8.8 \
    --dns=1.1.1.1 \
    ${DATA_ROOT_FLAG} \
    >/tmp/dockerd.log 2>&1 &

DOCKERD_PID=$!
echo "[build-fly] dockerd pid=$DOCKERD_PID data-root=${DOCKER_DATA_ROOT:-<default>}"

# Wait up to 60s for the daemon to come up. Mirrors the timeout in
# build.sh's `docker version` loop so failures surface in one place.
for i in $(seq 1 60); do
    if docker version >/dev/null 2>&1; then
        echo "[build-fly] dockerd is ready (after ${i}s)"
        break
    fi
    if [ "$i" = "60" ]; then
        echo "[build-fly] dockerd never came up — last 50 log lines:" >&2
        tail -n 50 /tmp/dockerd.log >&2 || true
        exit 65
    fi
    sleep 1
done

# Hand off to the canonical build script. Unset DOCKER_HOST so docker
# defaults to /var/run/docker.sock (build.sh only logs the value,
# nothing else reads it). Export AF_CACHE_ROOT so build.sh can emit
# cache stats in the per-build telemetry line.
unset DOCKER_HOST
export AF_CACHE_ROOT="${AF_CACHE_ROOT:-}"

# ---------------------------------------------------------------------------
# Hard runtime cap.
# ---------------------------------------------------------------------------
# Enforced here, not inside build.sh, because build.sh has its own
# ERR trap that will not fire on SIGTERM from `timeout`. Wrapping from
# the outer script lets us intercept the 124/137 exit codes, post a
# clean FAILED callback to service-cloud-api (otherwise the BuildJob
# would sit as RUNNING forever once the machine auto-destroys), then
# exit non-zero so Fly reaps the VM.
#
# Defaults:
#   AF_BUILD_TIMEOUT_SECONDS — 15 min. A real Next.js cold build is
#     ~3-4 min; anything past 15 is almost certainly a runaway user
#     script (infinite build loop, memory thrash, OOM reboot storm).
#     Cap corresponds to ~$0.09 of Fly compute at performance-8x.
#   TIMEOUT_KILL_GRACE — 30s of SIGTERM → SIGKILL grace so dockerd/
#     buildkit get a chance to flush their metadata back to the volume
#     cleanly instead of leaving a half-written snapshotter state.
AF_BUILD_TIMEOUT_SECONDS="${AF_BUILD_TIMEOUT_SECONDS:-900}"
TIMEOUT_KILL_GRACE="${TIMEOUT_KILL_GRACE:-30}"

echo "[build-fly] running /app/build.sh with timeout=${AF_BUILD_TIMEOUT_SECONDS}s (kill-after=${TIMEOUT_KILL_GRACE}s)"

set +e
timeout --signal=TERM --kill-after="${TIMEOUT_KILL_GRACE}s" \
    "${AF_BUILD_TIMEOUT_SECONDS}s" /app/build.sh
rc=$?
set -e

# 124 = timeout expired, child exited on TERM.
# 137 = timeout expired, child had to be SIGKILLed after grace.
# Both mean the build was force-killed by us.
if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "[build-fly] ERROR: build.sh exceeded ${AF_BUILD_TIMEOUT_SECONDS}s cap — posting FAILED callback" >&2
    # Guard against missing callback env. This is the "stuck machine"
    # failure mode we're fixing; if the callback envs aren't set (e.g.
    # running in a prime-cache context) there's nothing to post.
    if [ -n "${CALLBACK_URL:-}" ] && [ -n "${CALLBACK_TOKEN:-}" ] && [ -n "${BUILD_JOB_ID:-}" ]; then
        # Best-effort POST; never let the callback itself wedge the exit path.
        payload=$(jq -nc \
            --arg id "$BUILD_JOB_ID" \
            --arg cap "$AF_BUILD_TIMEOUT_SECONDS" \
            --arg rc "$rc" \
            '{
                buildJobId: $id,
                status: "FAILED",
                logs: "[build-fly] build exceeded \($cap)s runtime cap (exit=\($rc)) — killed by watchdog",
                errorMessage: "build exceeded \($cap)s runtime cap"
             }')
        curl -fsS -X POST "$CALLBACK_URL" \
            -H "Content-Type: application/json" \
            -H "X-AF-Build-Token: $CALLBACK_TOKEN" \
            --max-time 30 \
            -d "$payload" >/dev/null \
            || echo "[build-fly] WARNING: timeout-FAILED callback POST failed (continuing)" >&2
    fi
fi

exit $rc
