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
nohup dockerd-entrypoint.sh dockerd \
    --host=unix:///var/run/docker.sock \
    --log-level=warn \
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

# Hand off to the canonical build script. Unset DOCKER_HOST so docker
# defaults to /var/run/docker.sock (build.sh only logs the value,
# nothing else reads it).
unset DOCKER_HOST
exec /app/build.sh
