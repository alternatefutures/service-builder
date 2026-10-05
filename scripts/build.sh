#!/usr/bin/env bash
# af-builder phased entrypoint. Kubernetes runs this image in three isolated
# containers: clone (repository credential only), plan (no credentials),
# rootless BuildKit (no credentials), and publish (registry + callback
# credentials only). No tenant-controlled build step ever shares a process
# namespace, socket, or environment with a credential.
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
#   BUILD_COMMAND_B64    — optional base64-encoded build command override
#   START_COMMAND_B64    — optional base64-encoded start command override
#   DOCKER_HOST          — publisher-only socket for its isolated dind sidecar

set -euo pipefail

PHASE="${AF_BUILD_PHASE:-build}"
RESULT_DIR="${AF_BUILD_RESULT_DIR:-/results}"
LOG_FILE="$RESULT_DIR/build.log"
RESULT_FILE="$RESULT_DIR/result.json"
IMAGE_ARCHIVE="$RESULT_DIR/image.tar"
PLAN_FILE="$RESULT_DIR/plan.json"
PLAN_READY="$RESULT_DIR/plan.ready"

require_env() {
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            echo "[builder:$PHASE] missing required env: $v" >&2
            exit 64
        fi
    done
}

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
        || echo "[builder:publish] WARNING: callback POST failed for status=$status (continuing)"
}

if [ "$PHASE" = "clone" ]; then
    require_env REPO_CLONE_URL REPO_REF REPO_SOURCE_URL
    echo "[builder:clone] fetching immutable source ref"
    mkdir -p /workspace
    git -C /workspace init -q
    git -C /workspace remote add origin "$REPO_CLONE_URL"
    git -C /workspace -c protocol.version=2 fetch --depth=1 origin "$REPO_REF"
    git -C /workspace checkout -q FETCH_HEAD
    # Never persist the authenticated URL into the shared workspace.
    git -C /workspace remote set-url origin "$REPO_SOURCE_URL.git"
    git -C /workspace config --unset-all http.extraheader 2>/dev/null || true
    echo "[builder:clone] checked out $(git -C /workspace rev-parse HEAD)"
    exit 0
fi

if [ "$PHASE" = "publish" ]; then
    require_env BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN IMAGE_TAG GHCR_USER GHCR_TOKEN
    mkdir -p "$RESULT_DIR"
    touch "$LOG_FILE"
    echo "[builder:publish] waiting for docker daemon"
    for i in {1..60}; do
        docker version >/dev/null 2>&1 && break
        [ "$i" = "60" ] && { post_callback FAILED '"errorMessage":"docker daemon unavailable"'; exit 65; }
        sleep 1
    done
    post_callback RUNNING
    for i in {1..1800}; do
        [ -s "$RESULT_FILE" ] && break
        [ "$i" = "1800" ] && { post_callback FAILED '"errorMessage":"credential-free build phase timed out"'; exit 124; }
        sleep 1
    done
    status=$(jq -r '.status' "$RESULT_FILE")
    if [ "$status" != "SUCCEEDED" ]; then
        error=$(jq -r '.errorMessage // "credential-free build phase failed"' "$RESULT_FILE" | jq -Rs .)
        post_callback FAILED "\"errorMessage\":$error"
        exit 1
    fi
    if [ ! -s "$IMAGE_ARCHIVE" ]; then
        post_callback FAILED '"errorMessage":"credential-free build produced no image archive"'
        exit 66
    fi
    if ! docker load --input "$IMAGE_ARCHIVE" >>"$LOG_FILE" 2>&1; then
        post_callback FAILED '"errorMessage":"trusted publisher could not load the built image archive"'
        exit 1
    fi
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
    if ! docker push "$IMAGE_TAG" >>"$LOG_FILE" 2>&1; then
        post_callback FAILED '"errorMessage":"trusted registry publish failed"'
        exit 1
    fi
    extra=$(jq -r '
      {imageTag:env.IMAGE_TAG,commitSha:.commitSha,detectedFramework:.detectedFramework}
      + (if .detectedPort == null then {} else {detectedPort:.detectedPort} end)
      | to_entries | map("\"\(.key)\": \(.value | @json)") | join(",")
    ' "$RESULT_FILE")
    post_callback SUCCEEDED "$extra"
    exit 0
fi

require_env BUILD_JOB_ID REPO_REF IMAGE_TAG REPO_SOURCE_URL REPO_OWNER REPO_NAME
mkdir -p "$RESULT_DIR"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
ROOT_DIRECTORY="${ROOT_DIRECTORY:-.}"

decode_optional_command() {
    local encoded="$1"
    local legacy="$2"
    if [ -z "$encoded" ]; then
        printf '%s' "$legacy"
        return
    fi
    if ! printf '%s' "$encoded" | base64 -d; then
        echo "[builder:build] invalid base64 command override" >&2
        return 64
    fi
}

BUILD_COMMAND="$(decode_optional_command "${BUILD_COMMAND_B64:-}" "${BUILD_COMMAND:-}")"
START_COMMAND="$(decode_optional_command "${START_COMMAND_B64:-}" "${START_COMMAND:-}")"

write_failure() {
    local line="${1:-unknown}"
    jq -n --arg error "credential-free build phase crashed (line $line)" \
      '{status:"FAILED",errorMessage:$error}' >"$RESULT_FILE.tmp"
    mv "$RESULT_FILE.tmp" "$RESULT_FILE"
}
trap 'write_failure "$LINENO"' ERR

echo "[builder:$PHASE] starting build_job=$BUILD_JOB_ID ref=$REPO_REF image=$IMAGE_TAG"

ACTUAL_SHA=$(git -C /workspace rev-parse HEAD)
echo "[builder:build] using checked-out source $ACTUAL_SHA"

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
# for the detected framework — official runtime images (node:22-bookworm-slim,
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
#     (committed Dockerfiles deliberately fall through to nixpacks, which
#     builds them without rewriting user intent)
USE_TEMPLATE=1
TEMPLATE_PATH="$SRC_DIR/.af/Dockerfile"
mkdir -p "$SRC_DIR/.af"
if [ -f "$SRC_DIR/Dockerfile" ]; then
    USE_TEMPLATE=0
    cp "$SRC_DIR/Dockerfile" "$TEMPLATE_PATH.tmp"
    mv "$TEMPLATE_PATH.tmp" "$TEMPLATE_PATH"
    echo "[builder] using repository Dockerfile"
    DOCKERFILE_PATH="$TEMPLATE_PATH"
elif SRC_DIR="$SRC_DIR" BUILD_COMMAND="${BUILD_COMMAND:-}" START_COMMAND="${START_COMMAND:-}" \
        DETECTED_PORT="${DETECTED_PORT:-}" \
        /app/render-dockerfile.sh "$DETECTED_FRAMEWORK" >"$TEMPLATE_PATH.tmp" 2>>"$LOG_FILE"; then
    mv "$TEMPLATE_PATH.tmp" "$TEMPLATE_PATH"
    echo "[builder] using template Dockerfile (framework=$DETECTED_FRAMEWORK)"
    DOCKERFILE_PATH="$TEMPLATE_PATH"
else
    rm -f "$TEMPLATE_PATH.tmp"
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
    cp "$SRC_DIR/.nixpacks/Dockerfile" "$TEMPLATE_PATH.tmp"
    mv "$TEMPLATE_PATH.tmp" "$TEMPLATE_PATH"
    DOCKERFILE_PATH="$TEMPLATE_PATH"
fi

# The Kubernetes planner stops here. It never executes the generated
# Dockerfile and never receives a container-runtime socket. Rootless BuildKit
# consumes the immutable workspace and this ready marker in a separate,
# credential-free container.
jq -n \
    --arg sha "$ACTUAL_SHA" \
    --arg fw "$DETECTED_FRAMEWORK" \
    --arg port "${DETECTED_PORT:-}" \
    '{status:"SUCCEEDED",commitSha:$sha,detectedFramework:$fw} +
     (if $port == "" then {} else {detectedPort: ($port|tonumber? // null)} end)' \
    >"$PLAN_FILE.tmp"
mv "$PLAN_FILE.tmp" "$PLAN_FILE"
if [ "$PHASE" = "plan" ]; then
    : >"$PLAN_READY.tmp"
    mv "$PLAN_READY.tmp" "$PLAN_READY"
    trap - ERR
    echo "[builder:plan] build plan ready for rootless BuildKit"
    exit 0
fi

# Legacy/local build phase only. Kubernetes production uses the separate
# rootless BuildKit container and therefore never exposes this phase to dind.
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

# Legacy/local build driver. Production Kubernetes stops in `plan` and uses
# the pinned rootless BuildKit container rendered by service-cloud-api. This
# path remains runnable for developer smoke tests without affecting the
# production credential boundary.
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

# Print the local builder configuration so daemon/driver failures are visible.
docker buildx inspect "$BUILDX_BUILDER" --bootstrap | sed 's/^/[builder] buildx: /' || true

echo "[builder] running credential-free docker buildx build --load"
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
    --load \
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

echo "[builder:build] success; handing image to isolated publisher"
docker save --output "$IMAGE_ARCHIVE.tmp" "$IMAGE_TAG"
mv "$IMAGE_ARCHIVE.tmp" "$IMAGE_ARCHIVE"
jq -n \
    --arg sha "$ACTUAL_SHA" \
    --arg fw "$DETECTED_FRAMEWORK" \
    --arg port "${DETECTED_PORT:-}" \
    '{status:"SUCCEEDED",commitSha:$sha,detectedFramework:$fw}
     + (if $port == "" then {} else {detectedPort: ($port|tonumber? // null)} end)' \
    >"$RESULT_FILE.tmp"
mv "$RESULT_FILE.tmp" "$RESULT_FILE"
trap - ERR
