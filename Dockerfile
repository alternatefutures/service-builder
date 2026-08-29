# af-builder — clones a connected git repo, runs Nixpacks to detect the
# framework + build a container, and pushes the resulting image to GHCR.
# Kubernetes uses this image for clone, planning, and trusted publishing.
# Only the publisher receives a socket to its private digest-pinned dind;
# tenant Dockerfiles execute in a separate non-privileged rootless BuildKit.

FROM docker:27.5.1-cli@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c AS docker-cli

FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

ARG NIXPACKS_VERSION=1.41.0
ARG NIXPACKS_SHA256=194bcad8c379f78a309eee1a88b2e6b2abc59f354efe7ecd7b4bbaf21de99a06

# System dependencies plus pinned Docker CLI/buildx binaries copied from the
# official digest-pinned image. The trusted publisher talks to its private dind.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -fsSL \
        -o /tmp/nixpacks.tar.gz \
        "https://github.com/railwayapp/nixpacks/releases/download/v${NIXPACKS_VERSION}/nixpacks-v${NIXPACKS_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && echo "${NIXPACKS_SHA256}  /tmp/nixpacks.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/nixpacks.tar.gz -C /usr/local/bin nixpacks \
    && chmod 0755 /usr/local/bin/nixpacks \
    && rm -f /tmp/nixpacks.tar.gz \
    && nixpacks --version

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

WORKDIR /app
COPY scripts/build.sh /app/build.sh
COPY scripts/render-dockerfile.sh /app/render-dockerfile.sh
RUN chmod +x /app/build.sh /app/render-dockerfile.sh

# Force amd64 builds inside the sidecar. Most compute providers we deploy
# to (Akash, Phala, …) run amd64; building amd64 here means the same image
# is portable across every provider in the registry.
ENV DOCKER_DEFAULT_PLATFORM=linux/amd64

ENTRYPOINT ["/app/build.sh"]
