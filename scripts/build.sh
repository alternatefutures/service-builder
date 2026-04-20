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

REQUIRED=(BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN REPO_CLONE_URL REPO_REF IMAGE_TAG GHCR_USER GHCR_TOKEN)
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

trap 'post_callback FAILED "\"errorMessage\": \"build script crashed (line $LINENO)\""' ERR

echo "[builder] starting build_job=$BUILD_JOB_ID  ref=$REPO_REF  image=$IMAGE_TAG"
post_callback RUNNING

# 1. Wait for dind sidecar to come up.
echo "[builder] waiting for docker daemon at $DOCKER_HOST …"
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

# 3. Detect via nixpacks plan (best-effort; failure is non-fatal — build will surface real errors).
DETECTED_FRAMEWORK="unknown"
DETECTED_PORT=""
if PLAN_JSON=$(nixpacks plan "/workspace/$ROOT_DIRECTORY" --format json 2>/dev/null); then
    DETECTED_FRAMEWORK=$(echo "$PLAN_JSON" | jq -r '.providers[0] // "unknown"')
    # Some providers expose start variables; we don't pretend we always know the port.
    DETECTED_PORT=$(echo "$PLAN_JSON" | jq -r '.variables.PORT // empty')
    echo "[builder] nixpacks detected provider=$DETECTED_FRAMEWORK  port=${DETECTED_PORT:-<unset>}"
else
    echo "[builder] nixpacks plan failed (continuing — build will fail loudly if framework is unsupported)"
fi

# 4. Build.
NIXPACKS_ARGS=("build" "/workspace/$ROOT_DIRECTORY" "--name" "$IMAGE_TAG" "--platform" "linux/amd64")
[ -n "${BUILD_COMMAND:-}" ] && NIXPACKS_ARGS+=("--build-cmd" "$BUILD_COMMAND")
[ -n "${START_COMMAND:-}" ] && NIXPACKS_ARGS+=("--start-cmd" "$START_COMMAND")

echo "[builder] running: nixpacks ${NIXPACKS_ARGS[*]}"
nixpacks "${NIXPACKS_ARGS[@]}"

# 5. Push.
echo "[builder] pushing $IMAGE_TAG to ghcr.io…"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
docker push "$IMAGE_TAG"

# 5b. Make the GHCR package public.
#
# WHY: GHCR creates packages as `private` by default. Akash (and most
# decentralized) providers' k8s pulls the image with no registry creds, so a
# private image manifests as `ImagePullBackOff` → POLL_URLS sees the URLs but
# 0 ready replicas → handleFailure fires → retry loop spawns N more deployments
# all guaranteed to fail the same way. Making the package public is one PATCH
# call and removes the entire failure mode for every current and future provider
# without leaking creds into the SDL.
#
# IMAGE_TAG is always `ghcr.io/<namespace>/<package>:<tag>` (see
# webhookEndpoint.ts → buildSpawner). We parse, then try the org endpoint
# first (production case), falling back to the user endpoint for local /
# self-hosted setups where the namespace is a personal account.
#
# Failure here is a WARNING, not fatal — the image is already pushed; the
# only consequence is the deploy will hit the old failure mode. Operators
# can re-run with a token that has the right scope.
IMAGE_NO_TAG="${IMAGE_TAG%:*}"           # ghcr.io/<ns>/<pkg>
NS_AND_PKG="${IMAGE_NO_TAG#ghcr.io/}"    # <ns>/<pkg>
GHCR_NS="${NS_AND_PKG%%/*}"              # <ns>
GHCR_PKG="${NS_AND_PKG#*/}"              # <pkg>

echo "[builder] setting visibility=public on package ${GHCR_NS}/${GHCR_PKG}"
ORG_CODE=$(curl -sS -o /tmp/vis.out -w "%{http_code}" -X PATCH \
    -H "Authorization: Bearer $GHCR_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --max-time 15 \
    "https://api.github.com/orgs/${GHCR_NS}/packages/container/${GHCR_PKG}/visibility" \
    -d '{"visibility":"public"}' || echo "000")

if [ "$ORG_CODE" = "204" ]; then
    echo "[builder] package is now public (org)"
elif [ "$ORG_CODE" = "404" ]; then
    # Either the package isn't indexed by GitHub yet (race after first push) OR
    # the namespace is a user, not an org. Try the user endpoint.
    USER_CODE=$(curl -sS -o /tmp/vis.out -w "%{http_code}" -X PATCH \
        -H "Authorization: Bearer $GHCR_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --max-time 15 \
        "https://api.github.com/user/packages/container/${GHCR_PKG}/visibility" \
        -d '{"visibility":"public"}' || echo "000")
    if [ "$USER_CODE" = "204" ]; then
        echo "[builder] package is now public (user)"
    else
        echo "[builder] WARNING: visibility PATCH failed (org=$ORG_CODE user=$USER_CODE) — providers may not be able to pull this image"
        head -c 500 /tmp/vis.out 2>/dev/null || true
        echo
    fi
else
    echo "[builder] WARNING: visibility PATCH returned $ORG_CODE — providers may not be able to pull this image"
    head -c 500 /tmp/vis.out 2>/dev/null || true
    echo
fi

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
post_callback SUCCEEDED "$EXTRA"

trap - ERR
