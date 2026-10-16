#!/usr/bin/env bash
# Fly Machines entrypoint. The machine is an ephemeral Firecracker VM, so it
# can safely boot its own Docker daemon without exposing a provider console or
# host socket. The canonical build.sh still owns clone/build/publish behavior.

set -euo pipefail

RESULT_DIR="${AF_BUILD_RESULT_DIR:-/results}"
RESULT_FILE="$RESULT_DIR/result.json"
mkdir -p "$RESULT_DIR"

DOCKERD_ARGS=(
    --host=unix:///var/run/docker.sock
    --log-level=warn
    --dns=8.8.8.8
    --dns=1.1.1.1
)
if [ -n "${AF_CACHE_ROOT:-}" ]; then
    if mountpoint -q "$AF_CACHE_ROOT"; then
        mkdir -p "$AF_CACHE_ROOT/dockerd"
        DOCKERD_ARGS+=("--data-root=$AF_CACHE_ROOT/dockerd")
        echo "[build-fly] using persistent Docker cache at $AF_CACHE_ROOT"
    else
        echo "[build-fly] cache path is not a mounted volume; using ephemeral state" >&2
    fi
fi

echo "[build-fly] starting embedded Docker daemon"
nohup dockerd "${DOCKERD_ARGS[@]}" >/tmp/dockerd.log 2>&1 &

for i in $(seq 1 60); do
    if docker version >/dev/null 2>&1; then
        echo "[build-fly] Docker daemon ready after ${i}s"
        break
    fi
    if [ "$i" = "60" ]; then
        tail -n 50 /tmp/dockerd.log >&2 || true
        jq -n '{status:"FAILED",errorMessage:"embedded Docker daemon failed to start"}' >"$RESULT_FILE"
        env -u REPO_CLONE_URL AF_BUILD_PHASE=publish AF_BUILD_RESULT_DIR="$RESULT_DIR" /app/build.sh || true
        exit 65
    fi
    sleep 1
done

unset DOCKER_HOST
export AF_BUILD_RESULT_DIR="$RESULT_DIR"

# ---------------------------------------------------------------------------
# Cache-volume housekeeping (2026-10-16 ENOSPC incident, Phase 119).
# ---------------------------------------------------------------------------
# Nothing else ever prunes dockerd's data-root on the persistent cache volume:
# every build leaves its image, buildkit snapshots and cache mounts behind, so
# a 20 GB volume fills within a day of ML builds and the next build dies with
# "no space left on device" halfway through pip install or the image import.
# Before the build, and ONLY before it (the volume is single-attach, this
# machine is its only user and nothing is being built yet), read the free
# space and, under AF_CACHE_MIN_FREE_GB, prune the buildkit cache of the
# docker-container builder down to AF_CACHE_PRUNE_KEEP_GB and drop unused
# images older than AF_CACHE_PRUNE_IMAGE_AGE_HOURS. Before/after free GB are
# exported so the `[builder] telemetry` line in build.sh records them next to
# cache_disk_gb.
#
# Docker 29: `docker builder prune` IS `docker buildx prune`; the old
# keep-storage flag is gone (--reserved-space is its replacement), and it only
# touches the named builder: the buildkit cache lives in the docker-container
# builder's state volume, not in dockerd's own builder.
uint_or_default() {
    case "${1:-}" in
        ''|*[!0-9]*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}
cache_free_bytes() {
    df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' ' || true
}
bytes_to_gb() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1000000000 }'
}

CACHE_PRUNE_FREE_GB_BEFORE="null"
CACHE_PRUNE_FREE_GB_AFTER="null"
if [ -n "${AF_CACHE_ROOT:-}" ] && mountpoint -q "$AF_CACHE_ROOT"; then
    MIN_FREE_GB="$(uint_or_default "${AF_CACHE_MIN_FREE_GB:-}" 8)"
    KEEP_GB="$(uint_or_default "${AF_CACHE_PRUNE_KEEP_GB:-}" 6)"
    IMAGE_AGE_HOURS="$(uint_or_default "${AF_CACHE_PRUNE_IMAGE_AGE_HOURS:-}" 24)"
    BUILDX_BUILDER="${BUILDX_BUILDER:-af-buildkit}"
    min_free_bytes=$((MIN_FREE_GB * 1000000000))
    free_before="$(cache_free_bytes "$AF_CACHE_ROOT")"
    case "$free_before" in
        ''|*[!0-9]*) free_before="" ;;
    esac
    if [ -z "$free_before" ]; then
        echo "[build-fly] could not read free space on $AF_CACHE_ROOT; skipping cache prune" >&2
    elif [ "$free_before" -ge "$min_free_bytes" ]; then
        echo "[build-fly] cache volume has $(bytes_to_gb "$free_before") GB free (minimum ${MIN_FREE_GB} GB); no prune needed"
    else
        free_before_gb="$(bytes_to_gb "$free_before")"
        echo "[build-fly] cache volume low on space: ${free_before_gb} GB free, minimum ${MIN_FREE_GB} GB; pruning build cache down to ${KEEP_GB} GB and unused images older than ${IMAGE_AGE_HOURS}h"
        # The builder container persists on the cache volume across machines
        # but the buildx client state does not (ephemeral rootfs), so re-attach
        # to the existing container before pruning. No container yet means a
        # fresh volume: nothing to prune there.
        if docker container inspect "buildx_buildkit_${BUILDX_BUILDER}0" >/dev/null 2>&1; then
            if ! docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1; then
                docker buildx create --driver docker-container --name "$BUILDX_BUILDER" --bootstrap >/dev/null 2>&1 \
                    || echo "[build-fly] could not attach to buildx builder $BUILDX_BUILDER for pruning" >&2
            fi
            timeout 300s docker buildx prune --builder "$BUILDX_BUILDER" --all --force \
                --reserved-space="${KEEP_GB}GB" 2>&1 | tail -n 3 | sed 's/^/[build-fly] buildx prune: /' \
                || echo "[build-fly] buildx prune failed or timed out (continuing)" >&2
        else
            echo "[build-fly] no buildx builder container on this volume yet; skipping build-cache prune"
        fi
        timeout 120s docker image prune --all --force --filter "until=${IMAGE_AGE_HOURS}h" 2>&1 | tail -n 1 | sed 's/^/[build-fly] image prune: /' \
            || echo "[build-fly] image prune failed or timed out (continuing)" >&2
        free_after="$(cache_free_bytes "$AF_CACHE_ROOT")"
        case "$free_after" in
            ''|*[!0-9]*) free_after="" ;;
        esac
        CACHE_PRUNE_FREE_GB_BEFORE="$free_before_gb"
        if [ -n "$free_after" ]; then
            CACHE_PRUNE_FREE_GB_AFTER="$(bytes_to_gb "$free_after")"
            echo "[build-fly] cache prune done: ${free_before_gb} GB -> ${CACHE_PRUNE_FREE_GB_AFTER} GB free"
            if [ "$free_after" -lt "$min_free_bytes" ]; then
                echo "[build-fly] WARNING: still under the ${MIN_FREE_GB} GB minimum after pruning; this cache volume needs extending or replacing" >&2
            fi
        else
            echo "[build-fly] cache prune done: ${free_before_gb} GB -> (free space unreadable)"
        fi
    fi
fi
export AF_CACHE_PRUNE_FREE_GB_BEFORE="$CACHE_PRUNE_FREE_GB_BEFORE"
export AF_CACHE_PRUNE_FREE_GB_AFTER="$CACHE_PRUNE_FREE_GB_AFTER"

BUILD_TIMEOUT="${AF_BUILD_TIMEOUT_SECONDS:-900}"
KILL_GRACE="${TIMEOUT_KILL_GRACE:-30}"
set +e
timeout --signal=TERM --kill-after="${KILL_GRACE}s" \
    "${BUILD_TIMEOUT}s" /app/build-fly-phases.sh
phase_rc=$?
set -e

if [ "$phase_rc" = "124" ] || [ "$phase_rc" = "137" ]; then
    jq -n --arg cap "$BUILD_TIMEOUT" \
      '{status:"FAILED",errorMessage:("build exceeded " + $cap + "s runtime cap")}' \
      >"$RESULT_FILE.tmp"
    mv "$RESULT_FILE.tmp" "$RESULT_FILE"
fi

# Publish is deliberately outside the build timeout so a timed-out build can
# still report a terminal callback. Clone credentials are removed entirely.
set +e
env -u REPO_CLONE_URL \
    AF_BUILD_PHASE=publish AF_BUILD_RESULT_DIR="$RESULT_DIR" \
    /app/build.sh
publish_rc=$?
set -e

if [ "$phase_rc" -ne 0 ]; then
    exit "$phase_rc"
fi
exit "$publish_rc"
