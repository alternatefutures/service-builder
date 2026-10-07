#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/build.sh"
buildx_driver="$root/scripts/buildx-driver.sh"
dockerfile="$root/Dockerfile"
fly_dockerfile="$root/Dockerfile.fly"
fly_entrypoint="$root/scripts/build-fly.sh"
fly_phases="$root/scripts/build-fly-phases.sh"
publish_workflow="$root/.github/workflows/docker-publish.yml"

bash -n "$script" "$buildx_driver" "$root/scripts/render-dockerfile.sh" "$fly_entrypoint" "$fly_phases"

grep -Fq 'require_env REPO_CLONE_URL REPO_REF REPO_SOURCE_URL' "$script"
grep -Fq 'git -C /workspace remote set-url origin "$REPO_SOURCE_URL.git"' "$script"
grep -Fq 'require_env BUILD_JOB_ID REPO_REF IMAGE_TAG REPO_SOURCE_URL REPO_OWNER REPO_NAME' "$script"
grep -Fq 'require_env BUILD_JOB_ID CALLBACK_URL CALLBACK_TOKEN IMAGE_TAG GHCR_USER GHCR_TOKEN' "$script"
grep -Fq -- '--load \' "$buildx_driver"
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
grep -Fq 'export BUILDX_BUILDER=default' "$fly_entrypoint"
grep -Fq 'COPY scripts/buildx-driver.sh /app/buildx-driver.sh' "$dockerfile"
grep -Fq 'COPY scripts/buildx-driver.sh /app/buildx-driver.sh' "$fly_dockerfile"

# Exercise the exact selection and build helpers with a command-recording
# Docker stub. The Fly default builder must never fall back to creating a
# docker-container builder, including when selection fails.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
docker_log="$test_tmp/docker.log"
cat >"$test_tmp/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
if [ "$1" = "buildx" ] && [ "$2" = "use" ] && [ "${MOCK_FAIL_BUILDX_USE:-0}" = "1" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$test_tmp/docker"

: >"$docker_log"
PATH="$test_tmp:$PATH" MOCK_DOCKER_LOG="$docker_log" \
    bash -c 'source "$1"; select_buildx_builder default' bash "$buildx_driver"
grep -Fxq 'buildx use default' "$docker_log"
if grep -Fq 'buildx create' "$docker_log"; then
    echo 'Fly default builder must not create a docker-container fallback' >&2
    exit 1
fi

: >"$docker_log"
set +e
PATH="$test_tmp:$PATH" MOCK_DOCKER_LOG="$docker_log" MOCK_FAIL_BUILDX_USE=1 \
    bash -c 'source "$1"; select_buildx_builder default' bash "$buildx_driver"
default_failure_rc=$?
set -e
test "$default_failure_rc" = 65
grep -Fxq 'buildx use default' "$docker_log"
if grep -Fq 'buildx create' "$docker_log"; then
    echo 'failed Fly default selection must remain creation-free' >&2
    exit 1
fi

: >"$docker_log"
PATH="$test_tmp:$PATH" MOCK_DOCKER_LOG="$docker_log" MOCK_FAIL_BUILDX_USE=1 \
    bash -c 'source "$1"; select_buildx_builder af-buildkit' bash "$buildx_driver"
grep -Fxq 'buildx create --driver docker-container --name af-buildkit --use --bootstrap' "$docker_log"

: >"$docker_log"
PATH="$test_tmp:$PATH" MOCK_DOCKER_LOG="$docker_log" \
    bash -c 'source "$1"; run_buildx_build default /tmp/Dockerfile ghcr.io/example/app:test https://github.com/example/app deadbeef /tmp/context' \
    bash "$buildx_driver"
build_command=$(cat "$docker_log")
case "$build_command" in
  *'buildx build --builder default --file /tmp/Dockerfile --platform linux/amd64 --tag ghcr.io/example/app:test '*'--load /tmp/context') ;;
  *)
    echo "unexpected Fly buildx invocation: $build_command" >&2
    exit 1
    ;;
esac
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
