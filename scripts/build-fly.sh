#!/usr/bin/env bash
# build-fly.sh — Fly.io Machine entrypoint.
#
# Boots a local dockerd inside the Firecracker microVM, waits until the
# socket is responsive, then exec's the existing `build.sh`. Same env
# contract as build.sh — DOCKER_HOST is left unset so docker uses the
# default unix socket at /var/run/docker.sock.
#
# Auto-destroy: the Fly Machine is created with `auto_destroy: true`
# and `restart.policy = "no"`, so when this script exits (success OR
# failure) the entire microVM is reaped. No cleanup required from us.

set -euo pipefail

echo "[build-fly] starting embedded dockerd…"

# Vendor's dockerd-entrypoint.sh sets up storage drivers + cgroups for
# us, but it tail-execs `dockerd` in the foreground. We need it
# detached so build.sh can take over. Run it via setsid + & and then
# poll the socket until ready.
#
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
    >/tmp/dockerd.log 2>&1 &

DOCKERD_PID=$!
echo "[build-fly] dockerd pid=$DOCKERD_PID"

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

# Optional pre-baked base image load.
#
# Legacy fast-path for the default docker driver (DOCKER_BUILDKIT=1).
# Currently disabled — Dockerfile.fly stopped shipping the tarball after
# we switched build.sh to a docker-container buildx driver (which
# ignores dockerd's image store). Left in place as a soft probe so that
# if anyone restores the skopeo step in Dockerfile.fly for a debug run,
# the runtime side still picks it up without a script change.
NIXPACKS_BASE_ARCHIVE=/opt/nixpacks-base.tar
if [ -f "$NIXPACKS_BASE_ARCHIVE" ]; then
    echo "[build-fly] loading pre-baked nixpacks base image…"
    if ! docker load -i "$NIXPACKS_BASE_ARCHIVE"; then
        echo "[build-fly] WARNING: pre-baked base load failed — falling back to live pull" >&2
    fi
fi

# Hand off to the canonical build script. Unset DOCKER_HOST so docker
# defaults to /var/run/docker.sock (build.sh only logs the value,
# nothing else reads it).
unset DOCKER_HOST
exec /app/build.sh
