#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/build.sh"
dockerfile="$root/Dockerfile"

bash -n "$script" "$root/scripts/render-dockerfile.sh"

grep -Fq 'require_env REPO_CLONE_URL REPO_REF REPO_SOURCE_URL' "$script"
grep -Fq 'git -C /workspace remote set-url origin "$REPO_SOURCE_URL.git"' "$script"
grep -Fq 'require_env BUILD_JOB_ID REPO_REF IMAGE_TAG REPO_SOURCE_URL REPO_OWNER REPO_NAME' "$script"
grep -Fq 'require_env BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN IMAGE_TAG GHCR_USER GHCR_TOKEN' "$script"
grep -Fq -- '--load \' "$script"
grep -Fq 'docker save --output "$IMAGE_ARCHIVE.tmp" "$IMAGE_TAG"' "$script"
grep -Fq 'docker load --input "$IMAGE_ARCHIVE"' "$script"
grep -Fq 'BUILD_COMMAND="$(decode_optional_command "${BUILD_COMMAND_B64:-}"' "$script"
grep -Fq 'if [ "$PHASE" = "plan" ]' "$script"
grep -Fq 'build plan ready for rootless BuildKit' "$script"
grep -Fq 'cp "$SRC_DIR/Dockerfile" "$TEMPLATE_PATH.tmp"' "$script"
grep -Fq 'cp "$SRC_DIR/.nixpacks/Dockerfile" "$TEMPLATE_PATH.tmp"' "$script"
grep -Eq '^FROM node:20-bookworm-slim@sha256:[a-f0-9]{64}$' "$dockerfile"
grep -Eq '^FROM docker:27\.5\.1-cli@sha256:[a-f0-9]{64} AS docker-cli$' "$dockerfile"
grep -Eq '^ARG NIXPACKS_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$dockerfile"
grep -Eq '^ARG NIXPACKS_SHA256=[a-f0-9]{64}$' "$dockerfile"
grep -Fq 'sha256sum -c -' "$dockerfile"
if grep -E '^[[:space:]]*FROM [^[:space:]]+(:[^@[:space:]]+)?([[:space:]]+AS[[:space:]]|$)' \
    "$root/scripts/render-dockerfile.sh" "$dockerfile" | grep -Ev '@sha256:[a-f0-9]{64}([[:space:]]+AS[[:space:]]|$)'; then
  echo 'mutable generated Dockerfile base image is forbidden' >&2
  exit 1
fi
if grep -E '^[[:space:]]*# syntax=' "$root/scripts/render-dockerfile.sh" | \
    grep -Ev '@sha256:[a-f0-9]{64}$'; then
  echo 'mutable generated Dockerfile frontend is forbidden' >&2
  exit 1
fi
if grep -Fq 'nixpacks.com/install.sh' "$dockerfile"; then
  echo 'mutable Nixpacks installer is forbidden' >&2
  exit 1
fi

build_require=$(grep -F 'require_env BUILD_JOB_ID REPO_REF IMAGE_TAG REPO_SOURCE_URL REPO_OWNER REPO_NAME' "$script")
case "$build_require" in
  *TOKEN*|*CALLBACK*|*CLONE_URL*)
    echo 'credential leaked into untrusted build phase contract' >&2
    exit 1
    ;;
esac

echo 'phased builder contract: ok'
