# af-builder — clones a connected git repo, runs Nixpacks to detect the
# framework + build a container, and pushes the resulting image to GHCR.
# The pod always pairs this container with a privileged `docker:24-dind`
# sidecar; this image does not run docker itself, it just talks to the
# sidecar via /var/run/docker.sock.

FROM node:20-bookworm-slim

# System deps. We pull docker-cli (talks to the dind sidecar) and the
# Nixpacks single-binary installer.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssh-client \
        xz-utils \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://nixpacks.com/install.sh | bash

# Pin nixpacks via the install script's default for now; we can pin via
# `NIXPACKS_VERSION=...` env in CI when we want determinism.

WORKDIR /app
COPY scripts/build.sh /app/build.sh
RUN chmod +x /app/build.sh

# Force amd64 builds inside the sidecar. Most compute providers we deploy
# to (Akash, Phala, …) run amd64; building amd64 here means the same image
# is portable across every provider in the registry.
ENV DOCKER_DEFAULT_PLATFORM=linux/amd64

ENTRYPOINT ["/app/build.sh"]
