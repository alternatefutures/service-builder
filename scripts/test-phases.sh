#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/build.sh"
dockerfile="$root/Dockerfile"
fly_dockerfile="$root/Dockerfile.fly"
fly_entrypoint="$root/scripts/build-fly.sh"
fly_phases="$root/scripts/build-fly-phases.sh"
publish_workflow="$root/.github/workflows/docker-publish.yml"

bash -n "$script" "$root/scripts/render-dockerfile.sh" "$fly_entrypoint" "$fly_phases"

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
grep -Eq '^FROM node:22-trixie-slim@sha256:[a-f0-9]{64}$' "$dockerfile"
grep -Eq '^FROM docker:29\.8\.2-cli@sha256:[a-f0-9]{64} AS docker-cli$' "$dockerfile"
grep -Eq '^# syntax=docker/dockerfile:1\.7@sha256:[a-f0-9]{64}$' "$dockerfile"
grep -Eq '^FROM curlimages/curl:[^@]+@sha256:[a-f0-9]{64} AS ca-certificates$' "$dockerfile"
test "$(grep -Fc 'archive/debian/20260918T000000Z' "$dockerfile")" = 2
test "$(grep -Fc 'archive/debian-security/20260918T000000Z' "$dockerfile")" = 2
grep -Fq "! grep -Fq '20260918T000000Z-security'" "$dockerfile"
grep -Fq 'ca-certificates=20250419' "$dockerfile"
grep -Fq 'curl=8.14.1-2+deb13u5' "$dockerfile"
grep -Fq 'git=1:2.47.3-0+deb13u1' "$dockerfile"
grep -Fq 'jq=1.7.1-6+deb13u3' "$dockerfile"
grep -Fq 'xz-utils=5.8.1-1+deb13u1' "$dockerfile"
if grep -Fq 'openssh-client=' "$dockerfile"; then
  echo 'HTTPS-only builder must not include an SSH client' >&2
  exit 1
fi
grep -Eq '^ARG NIXPACKS_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$dockerfile"
grep -Eq '^ARG NIXPACKS_SHA256=[a-f0-9]{64}$' "$dockerfile"
grep -Fq 'sha256sum -c -' "$dockerfile"
grep -Eq '^FROM docker:29\.8\.2-dind@sha256:[a-f0-9]{64} AS docker-engine$' "$fly_dockerfile"
grep -Eq '^FROM node:22-trixie-slim@sha256:[a-f0-9]{64}$' "$fly_dockerfile"
grep -Fq 'ENTRYPOINT ["/app/build-fly.sh"]' "$fly_dockerfile"
grep -Fq 'AF_BUILD_PHASE=clone' "$fly_phases"
grep -Fq 'AF_BUILD_PHASE=build' "$fly_phases"
grep -Fq 'AF_BUILD_PHASE=publish' "$fly_entrypoint"
grep -Fq -- '-u GHCR_TOKEN' "$fly_phases"
grep -Fq -- '-u CALLBACK_TOKEN' "$fly_phases"
grep -Fq -- '-u REPO_CLONE_URL' "$fly_phases"
grep -Fq 'AF_BUILD_TIMEOUT_SECONDS' "$fly_entrypoint"
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

grep -Fq 'provenance: mode=max' "$publish_workflow"
grep -Fq 'sbom: true' "$publish_workflow"
grep -Fq 'cosign verify-attestation' "$publish_workflow"
grep -Fq 'trivy image --timeout 15m --scanners vuln --severity CRITICAL' "$publish_workflow"
if grep -Fq -- '--ignore-unfixed' "$publish_workflow"; then
  echo 'production publication must reject every critical vulnerability' >&2
  exit 1
fi
if grep -Eq 'workflow_dispatch|af-builder:latest' "$publish_workflow"; then
  echo 'manual or mutable-tag production publication is forbidden' >&2
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
