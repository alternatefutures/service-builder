#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/build.sh"
dockerfile="$root/Dockerfile"
fly_dockerfile="$root/Dockerfile.fly"
fly_entrypoint="$root/scripts/build-fly.sh"
fly_phases="$root/scripts/build-fly-phases.sh"
buildkitd_config="$root/scripts/buildkitd.toml"
publish_workflow="$root/.github/workflows/docker-publish.yml"

bash -n "$script" "$root/scripts/render-dockerfile.sh" "$fly_entrypoint" "$fly_phases"

grep -Fq 'require_env REPO_CLONE_URL REPO_REF REPO_SOURCE_URL' "$script"
grep -Fq 'git -C /workspace remote set-url origin "$REPO_SOURCE_URL.git"' "$script"
grep -Fq 'require_env BUILD_JOB_ID REPO_REF IMAGE_TAG REPO_SOURCE_URL REPO_OWNER REPO_NAME' "$script"
grep -Fq 'require_env BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN IMAGE_TAG GHCR_USER GHCR_TOKEN' "$script"
# Image artifact contract (2026-10-17, Phase 119 addendum): the build phase
# exports an OCI image layout, the publisher pushes it with crane, and no
# phase ever loads, saves or pushes through a Docker daemon. Every image
# loaded into dockerd stayed on the persistent cache volume and filled it.
grep -Fq -- '--output "type=oci,dest=$IMAGE_LAYOUT.tmp,tar=false" \' "$script"
grep -Fq -- '--provenance=false \' "$script"
grep -Fq 'mv "$IMAGE_LAYOUT.tmp" "$IMAGE_LAYOUT"' "$script"
grep -Fq 'crane auth login "$REGISTRY_HOST" -u "$GHCR_USER" --password-stdin' "$script"
grep -Fq 'crane push "$ARTIFACT" "$IMAGE_TAG"' "$script"
grep -Fq 'rm -rf "$DOCKER_CONFIG" "$IMAGE_LAYOUT" "$IMAGE_ARCHIVE"' "$script"
if grep -Ev '^[[:space:]]*#' "$script" | grep -Eq 'docker (load|save|push|login|image rm)|--load'; then
  echo 'the builder must not load, save or push images through a Docker daemon' >&2
  exit 1
fi
# Pinned BuildKit + bounded layer cache: build.sh hands the digest-pinned image
# and the GC-policy config to `buildx create`; build-fly.sh owns the pin and
# recreates the builder container when either changes.
grep -Fq -- '--driver-opt "image=$BUILDKIT_IMAGE"' "$script"
grep -Fq -- '--buildkitd-config "$BUILDKITD_CONFIG"' "$script"
grep -Eq '^export BUILDKIT_IMAGE="\$\{BUILDKIT_IMAGE:-moby/buildkit:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}\}"$' "$fly_entrypoint"
grep -Fq 'export BUILDKITD_CONFIG="${BUILDKITD_CONFIG:-/app/buildkitd.toml}"' "$fly_entrypoint"
grep -Fq 'fingerprint_file="$AF_CACHE_ROOT/buildkit.fingerprint"' "$fly_entrypoint"
grep -Fq 'docker volume rm -f "buildx_buildkit_${BUILDX_BUILDER}0_state"' "$fly_entrypoint"
grep -Eq '^\[worker\.oci\]$' "$buildkitd_config"
grep -Eq '^[[:space:]]*gc = true$' "$buildkitd_config"
grep -Eq '^[[:space:]]*reservedSpace = "[0-9]+(GB|%)"$' "$buildkitd_config"
grep -Eq '^[[:space:]]*maxUsedSpace = "[0-9]+(GB|%)"$' "$buildkitd_config"
grep -Eq '^[[:space:]]*minFreeSpace = "[0-9]+(GB|%)"$' "$buildkitd_config"
grep -Fq 'COPY --chmod=0444 scripts/buildkitd.toml /app/buildkitd.toml' "$fly_dockerfile"
for df in "$dockerfile" "$fly_dockerfile"; do
  grep -Eq '^ARG CRANE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df"
  grep -Eq '^ARG CRANE_SHA256=[a-f0-9]{64}$' "$df"
  grep -Fq 'go-containerregistry_Linux_x86_64.tar.gz' "$df"
  grep -Fq '&& crane version' "$df"
done
grep -Fq 'BUILD_COMMAND="$(decode_optional_command "${BUILD_COMMAND_B64:-}"' "$script"
grep -Fq 'if [ "$PHASE" = "plan" ]' "$script"
grep -Fq 'build plan ready for rootless BuildKit' "$script"
grep -Fq 'cp "$SRC_DIR/Dockerfile" "$TEMPLATE_PATH.tmp"' "$script"
grep -Fq 'cp "$SRC_DIR/.nixpacks/Dockerfile" "$TEMPLATE_PATH.tmp"' "$script"
# A failed nixpacks plan names the likely cause in the build log (2026-10-17:
# an app in a subfolder with the service root directory left at ".").
grep -Fq 'if ! nixpacks "${NIXPACKS_ARGS[@]}"; then' "$script"
grep -Fq 'No app detected at the repo root. If your app lives in a subfolder, set Root directory on the service to that folder.' "$script"
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
# Pre-build cache prune (Phase 119): runs before the build, never during it,
# with the Docker 29 flag set (--keep-storage is gone; --reserved-space is
# its replacement) against the docker-container builder that holds the cache.
grep -Fq 'AF_CACHE_MIN_FREE_GB' "$fly_entrypoint"
grep -Fq 'docker buildx prune --builder "$BUILDX_BUILDER" --all --force' "$fly_entrypoint"
grep -Fq -- '--reserved-space="${KEEP_GB}GB"' "$fly_entrypoint"
grep -Fq 'docker image prune --all --force --filter "until=${IMAGE_AGE_HOURS}h"' "$fly_entrypoint"
grep -Fq 'uint_or_default "${AF_CACHE_PRUNE_IMAGE_AGE_HOURS:-}" 1)' "$fly_entrypoint"
grep -Fq 'export AF_CACHE_PRUNE_FREE_GB_BEFORE=' "$fly_entrypoint"
grep -Fq 'export AF_CACHE_PRUNE_FREE_GB_AFTER=' "$fly_entrypoint"
grep -Fq '"cache_prune_free_gb_before":%s,"cache_prune_free_gb_after":%s' "$script"
if grep -Fq -- '--keep-storage' "$fly_entrypoint" "$script"; then
  echo 'docker 29 removed --keep-storage from builder prune; use --reserved-space' >&2
  exit 1
fi
prune_line=$(grep -n 'docker buildx prune' "$fly_entrypoint" | head -n1 | cut -d: -f1)
build_line=$(grep -n '/app/build-fly-phases.sh' "$fly_entrypoint" | tail -n1 | cut -d: -f1)
if [ -z "$prune_line" ] || [ -z "$build_line" ] || [ "$prune_line" -ge "$build_line" ]; then
  echo 'cache prune must run before the build phases, never alongside them' >&2
  exit 1
fi
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
