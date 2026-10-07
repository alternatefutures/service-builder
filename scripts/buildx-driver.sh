#!/usr/bin/env bash

# Shared Buildx driver helpers. Fly explicitly selects the daemon-integrated
# `default` builder; if that builder is unavailable, it must fail closed rather
# than recreate the nested docker-container builder rejected by the Fly kernel.

select_buildx_builder() {
    local builder="$1"

    if docker buildx use "$builder" >/dev/null 2>&1; then
        echo "[builder] reusing existing buildx builder: $builder"
        return 0
    fi

    if [ "$builder" = "default" ]; then
        echo "[builder] built-in default buildx builder unavailable; refusing docker-container fallback" >&2
        return 65
    fi

    echo "[builder] creating docker-container buildx builder: $builder"
    docker buildx create \
        --driver docker-container \
        --name "$builder" \
        --use \
        --bootstrap >/dev/null
}

run_buildx_build() {
    local builder="$1"
    local dockerfile_path="$2"
    local image_tag="$3"
    local repo_source_url="$4"
    local repo_ref="$5"
    local source_dir="$6"

    docker buildx build \
        --builder "$builder" \
        --file "$dockerfile_path" \
        --platform linux/amd64 \
        --tag "$image_tag" \
        --label "org.opencontainers.image.source=$repo_source_url" \
        --label "org.opencontainers.image.revision=$repo_ref" \
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --load \
        "$source_dir"
}
