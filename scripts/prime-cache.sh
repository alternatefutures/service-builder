#!/usr/bin/env bash
# prime-cache.sh — one-shot warmup for a Fly Volume's dockerd data-root.
#
# Called as the Fly Machine entrypoint instead of `build-fly.sh` (see
# admin/cloud/scripts/prime-fly-cache.sh). Same expectations as
# build-fly.sh:
#   - The cache volume is already mounted at $AF_CACHE_ROOT.
#   - We boot dockerd with --data-root on that volume.
#   - Every image we pull and every buildkit layer we materialize here
#     sticks on the volume, so the NEXT real build on a fresh machine
#     attaches the volume and starts warm.
#
# What we prime (tuned to render-dockerfile.sh):
#   1. Base images referenced by every auto-generated Dockerfile.
#   2. Deterministic "upper layers" of each framework's template: the
#      `FROM … + apt-get install + corepack enable` prefix. We build a
#      throwaway image per framework using the EXACT lines from
#      render-dockerfile.sh, so the BuildKit layer digests line up
#      with real builds and get reused byte-for-byte on cache-hit.
#   3. docker/dockerfile:1.7 (the buildkit frontend referenced by our
#      `# syntax=` header — pulled once per build otherwise).
#
# What we deliberately DON'T prime:
#   - Per-repo package manifests (package.json, requirements.txt, …).
#     Those are repo-specific; the right place to warm them is the
#     registry :buildcache, not the volume.
#   - PM cache stores at the buildkit level (pnpm store, pip cache,
#     cargo registry). Those live inside buildkit's sibling container,
#     which we don't create here — build.sh creates it lazily on first
#     real use. Running a trivial `npm install react` here would seed
#     npm's on-disk cache but NOT buildkit's `--mount=type=cache` dir,
#     which is the one build.sh actually hits.
#
# Idempotent: running this twice is fine. `docker pull` no-ops on an
# up-to-date tag; buildkit layer cache dedupes by content digest.

set -euo pipefail

echo "[prime-cache] starting cache priming run"

if [ -z "${AF_CACHE_ROOT:-}" ]; then
    echo "[prime-cache] ERROR: AF_CACHE_ROOT is not set" >&2
    exit 1
fi
if ! findmnt -T "$AF_CACHE_ROOT" >/dev/null 2>&1; then
    echo "[prime-cache] ERROR: $AF_CACHE_ROOT is not a mount — refusing to write priming state to rootfs" >&2
    exit 1
fi

DOCKER_DATA_ROOT="$AF_CACHE_ROOT/dockerd"
mkdir -p "$DOCKER_DATA_ROOT"

echo "[prime-cache] volume state BEFORE:"
df -h "$AF_CACHE_ROOT" | tail -n 1 | awk '{printf "  size=%s used=%s avail=%s use=%s\n", $2,$3,$4,$5}'

echo "[prime-cache] booting dockerd with data-root=$DOCKER_DATA_ROOT"
nohup dockerd-entrypoint.sh dockerd \
    --host=unix:///var/run/docker.sock \
    --data-root="$DOCKER_DATA_ROOT" \
    --log-level=warn \
    --dns=8.8.8.8 \
    --dns=1.1.1.1 \
    >/tmp/dockerd.log 2>&1 &
DOCKERD_PID=$!

for i in $(seq 1 60); do
    if docker version >/dev/null 2>&1; then
        echo "[prime-cache] dockerd ready (after ${i}s)"
        break
    fi
    if [ "$i" = "60" ]; then
        echo "[prime-cache] dockerd never came up — last 50 log lines:" >&2
        tail -n 50 /tmp/dockerd.log >&2 || true
        exit 65
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Step 1: pull base images.
# ---------------------------------------------------------------------------
# Mirrors every `FROM` line in render-dockerfile.sh. Keep this list
# in lockstep with that file — if render-dockerfile.sh bumps node to
# :22-slim or python to :3.13-slim, update this list OR prime-cache
# runs will silently warm the wrong tags.
BASE_IMAGES=(
    "node:20-slim"
    "python:3.12-slim"
    "golang:1.23-alpine"
    "alpine:3.20"
    "rust:1.82-slim"
    "debian:bookworm-slim"
    "ruby:3.3-slim"
    "docker/dockerfile:1.7"
)

for img in "${BASE_IMAGES[@]}"; do
    echo "[prime-cache] pulling $img"
    # --platform linux/amd64 to match DOCKER_DEFAULT_PLATFORM in
    # Dockerfile.fly and the --platform flag in build.sh. Otherwise
    # buildkit would cache-miss on linux/amd64 builds because it
    # pulled an arm64 variant here and the digests wouldn't match.
    docker pull --platform linux/amd64 "$img" >/dev/null
done

# ---------------------------------------------------------------------------
# Step 2: materialize framework upper layers via throwaway builds.
# ---------------------------------------------------------------------------
# Important: use the SAME buildx builder name that build.sh uses so
# the materialized layers land in the builder we'll be reusing. If we
# built with the default driver here and build.sh reads from
# docker-container, the cache wouldn't transfer.
BUILDX_BUILDER="af-buildkit"
if ! docker buildx use "$BUILDX_BUILDER" >/dev/null 2>&1; then
    echo "[prime-cache] creating buildx builder: $BUILDX_BUILDER"
    docker buildx create \
        --driver docker-container \
        --name "$BUILDX_BUILDER" \
        --use \
        --bootstrap >/dev/null
else
    echo "[prime-cache] reusing existing buildx builder: $BUILDX_BUILDER"
fi

PRIME_DIR=$(mktemp -d)
trap 'rm -rf "$PRIME_DIR"' EXIT

# -- Node (covers next/nuxt/remix/astro/svelte/sveltekit/vite/nestjs --)
cat > "$PRIME_DIR/Dockerfile.node" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM node:20-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare --activate 2>/dev/null || true
EOF

# -- Python (fastapi/flask/django/generic) --
cat > "$PRIME_DIR/Dockerfile.python" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl libpq-dev \
    && rm -rf /var/lib/apt/lists/*
EOF

# -- Ruby/Rails --
cat > "$PRIME_DIR/Dockerfile.ruby" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM ruby:3.3-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl libpq-dev libyaml-dev nodejs \
    && rm -rf /var/lib/apt/lists/*
EOF

# -- Rust --
cat > "$PRIME_DIR/Dockerfile.rust" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM rust:1.82-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*
EOF

# -- Go (builder + runtime; both layers cached) --
cat > "$PRIME_DIR/Dockerfile.go" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM golang:1.23-alpine AS builder
WORKDIR /app
ENV CGO_ENABLED=0 GOFLAGS=-trimpath

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
EOF

# We tag the primed images so `docker images` is readable after the
# run, but we don't push them — these are purely for populating the
# buildkit layer cache in the sibling container.
for fw in node python ruby rust go; do
    echo "[prime-cache] priming upper layers for framework=$fw"
    docker buildx build \
        --builder "$BUILDX_BUILDER" \
        --file "$PRIME_DIR/Dockerfile.$fw" \
        --platform linux/amd64 \
        --tag "af-prime/$fw:latest" \
        --load \
        "$PRIME_DIR"
done

# ---------------------------------------------------------------------------
# Step 3: report state.
# ---------------------------------------------------------------------------
echo "[prime-cache] volume state AFTER:"
df -h "$AF_CACHE_ROOT" | tail -n 1 | awk '{printf "  size=%s used=%s avail=%s use=%s\n", $2,$3,$4,$5}'

echo "[prime-cache] pulled images:"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | sed 's/^/  /'

# BuildKit cache inspection — useful for verifying that mode=max cache
# entries are in place. `buildx du` reports per-mount sizes.
echo "[prime-cache] buildkit cache sizes:"
docker buildx du --builder "$BUILDX_BUILDER" 2>/dev/null | sed 's/^/  /' || true

echo "[prime-cache] done"
