#!/usr/bin/env bash
# af-builder entrypoint — clones, runs nixpacks, pushes to GHCR, posts
# status callbacks back to service-cloud-api.
#
# Env contract (all required unless noted):
#   BUILD_JOB_ID         — BuildJob.id we're updating
#   CALLBACK_URL         — full URL on service-cloud-api (e.g. https://api.alternatefutures.ai/internal/build-callback)
#   CALLBACK_TOKEN       — HMAC-signed one-time token; api verifies before mutating BuildJob
#   REPO_CLONE_URL       — https://x-access-token:<token>@github.com/owner/repo.git
#   REPO_REF             — branch name OR full commit sha to check out
#   IMAGE_TAG            — ghcr.io/<org>/<userid>--<repo>:<sha>
#   GHCR_USER            — username for `docker login ghcr.io`
#   GHCR_TOKEN           — PAT or App installation token with packages:write
#   ROOT_DIRECTORY       — optional, monorepo subdir (defaults to ".")
#   BUILD_COMMAND        — optional, nixpacks --build-cmd override
#   START_COMMAND        — optional, nixpacks --start-cmd override
#   DOCKER_HOST          — e.g. tcp://localhost:2375 (set by Job template; talks to dind sidecar)

set -euo pipefail

LOG_FILE=/tmp/build.log
# Pre-create the log file BEFORE redirecting via process substitution.
# `exec > >(tee -a "$LOG_FILE")` doesn't create the file until tee writes
# its first byte, which is asynchronous — so any `tail -c "$LOG_FILE"` that
# runs before tee flushes (e.g. the very first post_callback RUNNING) hits
# ENOENT and, with `set -e` + the ERR trap, kills the whole build.
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

REQUIRED=(BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN REPO_CLONE_URL REPO_REF IMAGE_TAG GHCR_USER GHCR_TOKEN REPO_SOURCE_URL REPO_OWNER REPO_NAME)
for v in "${REQUIRED[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "[builder] missing required env: $v" >&2
        exit 64
    fi
done

ROOT_DIRECTORY="${ROOT_DIRECTORY:-.}"

post_callback() {
    local status="$1"
    local extra="${2:-}"
    # Truncate logs to the last ~16KB for the DB; full logs stay in the pod.
    # `tail` failure (e.g. log file not yet flushed) must NOT abort the build,
    # so swallow its error and fall back to an empty string.
    local logs
    logs="$( { tail -c 16000 "$LOG_FILE" 2>/dev/null || true; } | jq -Rs .)"
    local payload
    payload=$(cat <<EOF
{
  "buildJobId": "$BUILD_JOB_ID",
  "status": "$status",
  "logs": $logs
  $( [ -n "$extra" ] && echo ",$extra" || true )
}
EOF
)
    curl -fsS -X POST "$CALLBACK_URL" \
        -H "Content-Type: application/json" \
        -H "X-AF-Build-Token: $CALLBACK_TOKEN" \
        --max-time 30 \
        -d "$payload" >/dev/null \
        || echo "[builder] WARNING: callback POST failed for status=$status (continuing)"
}

trap 'post_callback FAILED "\"errorMessage\": \"build script crashed (line $LINENO)\""; stop_log_streamer' ERR

echo "[builder] starting build_job=$BUILD_JOB_ID  ref=$REPO_REF  image=$IMAGE_TAG"
post_callback RUNNING

# Background log streamer — re-POSTs the current tail of $LOG_FILE every
# few seconds while the build runs so the UI's expandable logs viewer
# fills in incrementally instead of staying empty until the terminal
# callback. Status stays RUNNING; the buildCallbackEndpoint CAS gate
# rejects any "downgrade" if a terminal callback wins the race, so this
# is safe to leave running until just before the SUCCEEDED/FAILED post.
LOG_STREAM_INTERVAL="${LOG_STREAM_INTERVAL:-5}"
log_streamer() {
    while sleep "$LOG_STREAM_INTERVAL"; do
        post_callback RUNNING || true
    done
}
log_streamer &
LOG_STREAMER_PID=$!
stop_log_streamer() {
    [ -n "${LOG_STREAMER_PID:-}" ] || return 0
    kill "$LOG_STREAMER_PID" 2>/dev/null || true
    wait "$LOG_STREAMER_PID" 2>/dev/null || true
    LOG_STREAMER_PID=""
}

# 1. Wait for dind sidecar (or embedded dockerd on Fly) to come up.
# DOCKER_HOST may be unset (Fly entrypoint clears it so docker defaults to
# the local /var/run/docker.sock); use ${VAR:-default} so `set -u` doesn't
# crash on the bare reference. The `docker version` probe below works
# regardless of whether DOCKER_HOST is set or not.
echo "[builder] waiting for docker daemon at ${DOCKER_HOST:-/var/run/docker.sock} …"
for i in {1..60}; do
    if docker version >/dev/null 2>&1; then
        echo "[builder] docker is ready"
        break
    fi
    if [ "$i" = "60" ]; then
        echo "[builder] docker daemon never came up" >&2
        exit 65
    fi
    sleep 1
done

# 2. Clone.
echo "[builder] cloning…"
mkdir -p /workspace
git -C /workspace init -q
git -C /workspace remote add origin "$REPO_CLONE_URL"
git -C /workspace -c protocol.version=2 fetch --depth=1 origin "$REPO_REF"
git -C /workspace checkout -q FETCH_HEAD

ACTUAL_SHA=$(git -C /workspace rev-parse HEAD)
echo "[builder] checked out $ACTUAL_SHA"

# 3. Framework detection — primary source: the manifest the user wrote.
#
# We used to delegate this to `nixpacks plan`, but nixpacks is a builder
# (optimized for "compile & bundle"), not an introspector. It exits non-zero
# on common ambiguities — multiple lockfiles (npm + pnpm), Dockerfile-only
# repos, monorepos — and our prior `2>/dev/null` swallowed that error,
# leaving framework="unknown" forever. Reading the project manifest
# directly is deterministic, takes <100ms, and works for every repo whose
# author declared their dependencies (i.e. all of them).
#
# Order matters: pick the most specific framework before falling back to
# the runtime label. e.g. `next` beats `node` even though both are present.
SRC_DIR="/workspace/$ROOT_DIRECTORY"
DETECTED_FRAMEWORK="unknown"
DETECTED_PORT=""

# Helper — true iff the named npm package is in dependencies or devDependencies.
has_npm_dep() {
    local pkg="$1"
    [ -f "$SRC_DIR/package.json" ] || return 1
    jq -e --arg p "$pkg" \
        '((.dependencies // {}) + (.devDependencies // {})) | has($p)' \
        "$SRC_DIR/package.json" >/dev/null 2>&1
}

if [ -f "$SRC_DIR/package.json" ]; then
    if   has_npm_dep "next";              then DETECTED_FRAMEWORK="next"
    elif has_npm_dep "nuxt";              then DETECTED_FRAMEWORK="nuxt"
    elif has_npm_dep "@remix-run/dev"     \
      || has_npm_dep "@remix-run/serve";  then DETECTED_FRAMEWORK="remix"
    elif has_npm_dep "astro";             then DETECTED_FRAMEWORK="astro"
    elif has_npm_dep "@sveltejs/kit";     then DETECTED_FRAMEWORK="sveltekit"
    elif has_npm_dep "svelte";            then DETECTED_FRAMEWORK="svelte"
    elif has_npm_dep "vite";              then DETECTED_FRAMEWORK="vite"
    elif has_npm_dep "@nestjs/core";      then DETECTED_FRAMEWORK="nestjs"
    elif has_npm_dep "express"            \
      || has_npm_dep "fastify"            \
      || has_npm_dep "koa"                \
      || has_npm_dep "hono";              then DETECTED_FRAMEWORK="node"
    else                                       DETECTED_FRAMEWORK="node"
    fi
elif [ -f "$SRC_DIR/Cargo.toml" ];        then DETECTED_FRAMEWORK="rust"
elif [ -f "$SRC_DIR/go.mod" ];            then DETECTED_FRAMEWORK="go"
elif [ -f "$SRC_DIR/pyproject.toml" ] || [ -f "$SRC_DIR/requirements.txt" ]; then
    if   grep -qiE '^django'   "$SRC_DIR/requirements.txt" 2>/dev/null \
      || grep -qiE 'django'    "$SRC_DIR/pyproject.toml"   2>/dev/null; then DETECTED_FRAMEWORK="django"
    elif grep -qiE '^fastapi'  "$SRC_DIR/requirements.txt" 2>/dev/null \
      || grep -qiE 'fastapi'   "$SRC_DIR/pyproject.toml"   2>/dev/null; then DETECTED_FRAMEWORK="fastapi"
    elif grep -qiE '^flask'    "$SRC_DIR/requirements.txt" 2>/dev/null \
      || grep -qiE 'flask'     "$SRC_DIR/pyproject.toml"   2>/dev/null; then DETECTED_FRAMEWORK="flask"
    else                                                                    DETECTED_FRAMEWORK="python"
    fi
elif [ -f "$SRC_DIR/Gemfile" ]; then
    if grep -qE '^[^#]*gem .rails.' "$SRC_DIR/Gemfile" 2>/dev/null; then DETECTED_FRAMEWORK="rails"
    else                                                                 DETECTED_FRAMEWORK="ruby"
    fi
elif [ -f "$SRC_DIR/composer.json" ]; then
    if jq -e '((.["require"] // {}) + (.["require-dev"] // {})) | has("laravel/framework")' \
        "$SRC_DIR/composer.json" >/dev/null 2>&1; then DETECTED_FRAMEWORK="laravel"
    else                                               DETECTED_FRAMEWORK="php"
    fi
elif [ -f "$SRC_DIR/pom.xml" ] || [ -f "$SRC_DIR/build.gradle" ] || [ -f "$SRC_DIR/build.gradle.kts" ]; then
    if   grep -qiE 'spring-boot' "$SRC_DIR/pom.xml" 2>/dev/null \
      || grep -qiE 'spring-boot' "$SRC_DIR/build.gradle" 2>/dev/null \
      || grep -qiE 'spring-boot' "$SRC_DIR/build.gradle.kts" 2>/dev/null; then DETECTED_FRAMEWORK="spring"
    else                                                                       DETECTED_FRAMEWORK="java"
    fi
elif [ -f "$SRC_DIR/deno.json" ] || [ -f "$SRC_DIR/deno.jsonc" ]; then DETECTED_FRAMEWORK="deno"
elif [ -f "$SRC_DIR/Dockerfile" ];                                     then DETECTED_FRAMEWORK="docker"
fi
echo "[builder] manifest-based detection: framework=$DETECTED_FRAMEWORK"

# Optional enrichment — ask nixpacks for the port hint, but NEVER let it
# overwrite the framework label we just determined from the manifest.
# Nixpacks's stderr is too useful for debugging silent failures to keep
# swallowing it; route it into the build log so it's visible in the UI.
if PLAN_JSON=$(nixpacks plan "$SRC_DIR" --format json 2>>"$LOG_FILE"); then
    PLAN_PORT=$(echo "$PLAN_JSON" | jq -r '.variables.PORT // empty')
    PLAN_PROVIDER=$(echo "$PLAN_JSON" | jq -r '.providers[0] // "unknown"')
    [ -n "$PLAN_PORT" ] && DETECTED_PORT="$PLAN_PORT"
    echo "[builder] nixpacks plan: provider=$PLAN_PROVIDER port=${PLAN_PORT:-<unset>} (used as enrichment only)"
else
    echo "[builder] nixpacks plan failed (non-fatal; manifest-based framework already set; see log above for stderr)"
fi

# Framework-default port fallback. nixpacks reports `variables.PORT` for ~10%
# of providers (the ones with explicit `--start-cmd ... --port $PORT`-style
# scaffolding). Most provider plans omit it because the convention is
# `process.env.PORT` at runtime — leaving DETECTED_PORT empty here would
# propagate as `Service.containerPort=null`, which the SDL generator then
# falls back to in its own way (see akash/orchestrator.ts). We pre-empt that
# with a per-framework default so the public URL serves HTML instead of 404
# on first deploy. Users can always override via Config → Container port.
# Keep this table in lockstep with:
#   service-cloud-api/src/services/akash/orchestrator.ts   (SDL fallback)
#   web-app.alternatefutures.ai/.../GithubSourceSection.tsx (UI hint)
if [ -z "$DETECTED_PORT" ] && [ "$DETECTED_FRAMEWORK" != "unknown" ]; then
    case "$DETECTED_FRAMEWORK" in
        node|next|nextjs|nuxt|remix|astro|svelte|sveltekit|nestjs|bun|rails|ruby) DETECTED_PORT=3000 ;;
        vite)                                                                     DETECTED_PORT=5173 ;;
        deno|python|django|fastapi|flask|php|laravel)                             DETECTED_PORT=8000 ;;
        rust|go|java|spring)                                                      DETECTED_PORT=8080 ;;
        docker)                                                                   DETECTED_PORT=80   ;;
    esac
    if [ -n "$DETECTED_PORT" ]; then
        echo "[builder] no port from nixpacks; defaulting to $DETECTED_PORT for framework=$DETECTED_FRAMEWORK"
    fi
fi

# 4. Produce the Dockerfile for this build.
#
# Path A (fast, default): render-dockerfile.sh emits a template tuned
# for the detected framework — official runtime images (node:20-slim,
# python:3.12-slim, golang:1.23-alpine, …), buildkit cache mounts for
# the package manager dep cache, and single- or multi-stage builds
# appropriate to the language. Cold builds finish in 60-120s instead
# of the 6-10min nixpacks takes for the same app, mostly by NOT
# compiling a fresh Nix environment on every Fly machine.
#
# Path B (fallback, rare): if the framework detector came back with
# `unknown` OR we have no template for this language yet, we defer
# to nixpacks the way we always did. `nixpacks build --out $SRC_DIR`
# drops `.nixpacks/Dockerfile` in place and we continue from there.
# Zero regression risk for exotic repos.
#
# Escape hatches in either path:
#   - $BUILD_COMMAND / $START_COMMAND env vars override the defaults
#   - A committed $SRC_DIR/Dockerfile is picked up by framework=docker
#     (the template for that just re-emits `FROM $IMAGE` style — not
#     yet implemented; today `docker` falls through to nixpacks which
#     handles it gracefully)
USE_TEMPLATE=1
TEMPLATE_PATH="$SRC_DIR/.af/Dockerfile"
mkdir -p "$SRC_DIR/.af"
if SRC_DIR="$SRC_DIR" BUILD_COMMAND="${BUILD_COMMAND:-}" START_COMMAND="${START_COMMAND:-}" \
        DETECTED_PORT="${DETECTED_PORT:-}" \
        /app/render-dockerfile.sh "$DETECTED_FRAMEWORK" >"$TEMPLATE_PATH" 2>>"$LOG_FILE"; then
    echo "[builder] using template Dockerfile (framework=$DETECTED_FRAMEWORK)"
    DOCKERFILE_PATH="$TEMPLATE_PATH"
else
    USE_TEMPLATE=0
    echo "[builder] no template for framework=$DETECTED_FRAMEWORK — falling back to nixpacks"
    NIXPACKS_ARGS=("build" "$SRC_DIR" "--name" "$IMAGE_TAG" "--platform" "linux/amd64" "--out" "$SRC_DIR")
    [ -n "${BUILD_COMMAND:-}" ] && NIXPACKS_ARGS+=("--build-cmd" "$BUILD_COMMAND")
    [ -n "${START_COMMAND:-}" ] && NIXPACKS_ARGS+=("--start-cmd" "$START_COMMAND")

    echo "[builder] planning with: nixpacks ${NIXPACKS_ARGS[*]}"
    nixpacks "${NIXPACKS_ARGS[@]}"

    if [ ! -f "$SRC_DIR/.nixpacks/Dockerfile" ]; then
        echo "[builder] ERROR: nixpacks produced no Dockerfile at $SRC_DIR/.nixpacks/Dockerfile" >&2
        exit 66
    fi
    DOCKERFILE_PATH="$SRC_DIR/.nixpacks/Dockerfile"
fi

# Log in to GHCR up front so both the cache import and the image push
# below can talk to `ghcr.io/<namespace>/*` without extra auth steps.
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null

# ---------------------------------------------------------------------------
# Build driver choice + cache strategy (Phase 2: registry cache-to)
# ---------------------------------------------------------------------------
# We use a `docker-container` buildx driver with a deterministic builder
# name (`af-buildkit`) so we can push a full registry cache on every
# build (`type=registry,mode=max`). The default `docker` driver doesn't
# support `mode=max` cache-to — only `type=inline`, which collapses
# multi-stage builders (Go, Rust, Nixpacks) into a single cached stage
# and silently under-caches those builds.
#
# Why this still persists across machine reaps:
#   - `docker buildx create --driver docker-container` spawns a sibling
#     container named `buildx_buildkit_<builder>0`. That container's
#     metadata + overlay2 layer live under dockerd's data-root.
#   - build-fly.sh points `dockerd --data-root` at the mounted Fly
#     Volume, so the buildkit sibling container + its snapshotter
#     state + its `--mount=type=cache` dirs are all on the volume.
#   - When a new machine attaches the same volume, `docker buildx
#     inspect af-buildkit` finds the existing container and reuses it
#     verbatim. Same warm pnpm store, same Python wheels, same
#     node_modules layers.
#
# Cross-machine warmup for brand-new volumes (or a freshly-reaped
# machine where the buildkit container got GC'd):
#   - `--cache-to type=registry,ref=$CACHE_REF,mode=max` pushes every
#     intermediate stage's cache to `ghcr.io/.../:buildcache`.
#   - `--cache-from type=registry,ref=$CACHE_REF` pulls it back on
#     first-ever builds. Even a completely cold volume warms up on
#     the first build after priming.
#
# Net behavior:
#   - First-ever build on empty volume (pre-prime): ~3-4 min (base
#     image pull + dep install).
#   - First-ever build on primed volume: ~60-90s (skips apt + base
#     pulls because prime-cache.sh wrote them to the volume).
#   - Second build of same service, same deps, SAME machine: ~15-30s.
#   - First build after a machine reap / zone migration: ~60-90s
#     (hydrates from :buildcache even if the volume was lost).
CACHE_REF="${IMAGE_TAG%:*}:buildcache"
BUILDX_BUILDER="${BUILDX_BUILDER:-af-buildkit}"

# Idempotent builder creation. `inspect` returns non-zero when the
# builder doesn't exist OR when it exists but has no backing container
# (GC'd); `create` is a no-op if the named builder already exists, so
# we try `use` first and only `create` on a clean miss. This keeps
# fresh-volume bootstrap working without a separate init step.
if ! docker buildx use "$BUILDX_BUILDER" >/dev/null 2>&1; then
    echo "[builder] creating docker-container buildx builder: $BUILDX_BUILDER"
    docker buildx create \
        --driver docker-container \
        --name "$BUILDX_BUILDER" \
        --use \
        --bootstrap >/dev/null
else
    echo "[builder] reusing existing buildx builder: $BUILDX_BUILDER"
fi

# BuildKit inside the sibling container needs DNS for registry pulls
# during `--cache-from`. We already pass --dns to dockerd in
# build-fly.sh, but the buildx container inherits its own resolv.conf
# at create time — on older buildx this can be empty. Print the current
# builder config to the log so DNS misconfigs show up immediately
# instead of manifesting as "no cache available".
docker buildx inspect "$BUILDX_BUILDER" --bootstrap | sed 's/^/[builder] buildx: /' || true

echo "[builder] running: docker buildx build (cache-from+to=$CACHE_REF, driver=docker-container, volume=${AF_CACHE_ROOT:-<ephemeral>})"
# `--push` publishes the image in the same step (the docker-container
# driver doesn't populate dockerd's local image store, so we must
# --push or --load explicitly; --push is what we want anyway).
#
# --cache-to mode=max: exports ALL intermediate stages' caches to the
# registry, not just the final stage. Essential for multi-stage Rust/Go
# templates and for the Nixpacks fallback (nixpacks Dockerfiles tend to
# stack 5-10 deps/build/prod stages and only the final stage would
# round-trip on `mode=min`).
#
# ignore-error=true on cache-to: if the registry is temporarily
# unreachable or GHCR returns 5xx on the PUT, don't fail the build
# itself. Cache-to is an optimization, not a correctness requirement.
#
# --label org.opencontainers.image.source: stamped so GHCR auto-links
# this container package to the source GitHub repo on push. Label
# value is the clean https URL (no auth token), safe to embed.
#
# image.revision / image.created are included because `docker inspect`
# on a deployed service should tell you exactly which commit built it
# without cross-referencing BuildJob rows.
BUILD_START_MS=$(date +%s%3N)
docker buildx build \
    --builder "$BUILDX_BUILDER" \
    --file "$DOCKERFILE_PATH" \
    --platform linux/amd64 \
    --tag "$IMAGE_TAG" \
    --label "org.opencontainers.image.source=$REPO_SOURCE_URL" \
    --label "org.opencontainers.image.revision=$REPO_REF" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --cache-from "type=registry,ref=$CACHE_REF" \
    --cache-to "type=registry,ref=$CACHE_REF,mode=max,ignore-error=true" \
    --push \
    "$SRC_DIR"
BUILD_END_MS=$(date +%s%3N)
BUILD_DURATION_MS=$((BUILD_END_MS - BUILD_START_MS))

# ---------------------------------------------------------------------------
# Per-build telemetry JSON line.
# ---------------------------------------------------------------------------
# One-line JSON blob printed to stdout (and captured in $LOG_FILE so it
# makes it back to the callback POST). Phase 5 will tee this into
# Datadog/Prometheus, but even today it gives us grep-able
# "was this build warm or cold?" data without a dashboard.
#
# Fields:
#   phase          — "template" (render-dockerfile.sh path) or "nixpacks"
#   framework      — detected framework label
#   duration_ms    — total build+push time (excludes clone, excludes
#                    dockerd boot). Apples-to-apples across builds.
#   cache_root     — "/var/lib/af-cache" when a Fly Volume is mounted,
#                    "ephemeral" otherwise. Ties a slow result directly
#                    to missing persistence so we don't go hunting.
#   cache_disk_gb  — available GB on the volume (or NaN if ephemeral);
#                    early warning for full-volume cliffs.
#   image_size_mb  — pushed manifest size (rough; we grab the first
#                    layer's digest for a size estimate).
CACHE_DISK_GB="null"
CACHE_ROOT_LABEL="ephemeral"
if [ -n "${AF_CACHE_ROOT:-}" ] && findmnt -T "$AF_CACHE_ROOT" >/dev/null 2>&1; then
    CACHE_ROOT_LABEL="$AF_CACHE_ROOT"
    CACHE_DISK_GB=$(df -BG --output=avail "$AF_CACHE_ROOT" 2>/dev/null | tail -n1 | tr -d 'G ' || echo null)
fi

if [ "$USE_TEMPLATE" = "1" ]; then
    BUILD_PHASE="template"
else
    BUILD_PHASE="nixpacks"
fi

printf '[builder] telemetry: {"phase":"%s","framework":"%s","duration_ms":%d,"cache_root":"%s","cache_disk_gb":%s}\n' \
    "$BUILD_PHASE" \
    "$DETECTED_FRAMEWORK" \
    "$BUILD_DURATION_MS" \
    "$CACHE_ROOT_LABEL" \
    "$CACHE_DISK_GB"

# 5b. (Previously: PATCH GHCR visibility=public.)
#
# REMOVED: GitHub's REST API silently refuses to flip container package
# visibility for team-plan orgs even with a correctly-scoped token and
# admin role on both the org and the package — the endpoint returns 404
# with no diagnostic info. Instead of fighting that, we now ship a
# read-only GHCR pull token into the Akash SDL `credentials:` block (see
# service-cloud-api/src/services/akash/orchestrator.ts:
# buildGhcrCredentialsBlock). Providers use it as an imagePullSecret and
# pull the private image natively — no GitHub visibility change needed.
#
# The image stays `private` at GHCR. That is intentional and fine.
echo "[builder] package stays private — pull creds are injected into the Akash SDL by service-cloud-api"

# 6. Success callback (with detected metadata).
echo "[builder] success"
# `-r` (raw output) is REQUIRED here. The jq expression evaluates to a STRING
# of pre-formatted JSON key/value pairs that we splice into the heredoc with
# a leading comma. With the default `-c` (compact JSON), jq would re-encode
# that string with surrounding quotes and escaped inner quotes, producing
# `,"\"imageTag\": ..."` — a JSON syntax error the API rejects with HTTP 400.
EXTRA=$(jq -nr \
    --arg image "$IMAGE_TAG" \
    --arg sha "$ACTUAL_SHA" \
    --arg fw "$DETECTED_FRAMEWORK" \
    --arg port "${DETECTED_PORT:-}" \
    '{imageTag:$image, commitSha:$sha, detectedFramework:$fw} + (if $port == "" then {} else {detectedPort: ($port|tonumber? // null)} end) | to_entries | map("\"\(.key)\": \(.value | @json)") | join(",")')
# Stop the streamer BEFORE the terminal callback so a late RUNNING tick
# never races a SUCCEEDED. The CAS gate would reject a downgrade anyway,
# but draining cleanly avoids a 200-with-ignored noise log on the API.
stop_log_streamer
post_callback SUCCEEDED "$EXTRA"

trap - ERR
