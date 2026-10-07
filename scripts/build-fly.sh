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
# A Fly Machine already runs its own Docker daemon inside a Firecracker VM.
# Reuse that daemon's built-in BuildKit driver instead of launching the
# docker-container driver, whose nested OverlayFS mount is rejected by the
# Fly guest kernel. Kubernetes builds do not use this entrypoint and retain
# their separate rootless BuildKit path.
export BUILDX_BUILDER=default

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
