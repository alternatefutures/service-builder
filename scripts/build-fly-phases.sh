#!/usr/bin/env bash
# Run the existing phased builder contract inside one ephemeral Fly machine.
# Each phase receives only the credentials it needs. Tenant-controlled build
# commands execute through BuildKit without clone, registry, or callback
# credentials in their process environment.

set -u

RESULT_DIR="${AF_BUILD_RESULT_DIR:-/results}"
RESULT_FILE="$RESULT_DIR/result.json"
mkdir -p "$RESULT_DIR"

write_failure() {
    local message="$1"
    jq -n --arg error "$message" \
      '{status:"FAILED",errorMessage:$error}' >"$RESULT_FILE.tmp"
    mv "$RESULT_FILE.tmp" "$RESULT_FILE"
}

if ! env \
    -u GHCR_USER -u GHCR_TOKEN \
    -u CALLBACK_URL -u CALLBACK_TOKEN \
    AF_BUILD_PHASE=clone AF_BUILD_RESULT_DIR="$RESULT_DIR" \
    /app/build.sh; then
    write_failure "source clone phase failed"
    exit 1
fi

if ! env \
    -u REPO_CLONE_URL \
    -u GHCR_USER -u GHCR_TOKEN \
    -u CALLBACK_URL -u CALLBACK_TOKEN \
    AF_BUILD_PHASE=build AF_BUILD_RESULT_DIR="$RESULT_DIR" \
    /app/build.sh; then
    if [ ! -s "$RESULT_FILE" ]; then
        write_failure "credential-free build phase failed"
    fi
    exit 1
fi

