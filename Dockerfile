# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# af-builder — clones a connected git repo, runs Nixpacks to detect the
# framework + build a container, and pushes the resulting image to GHCR.
# Kubernetes uses this image for clone, planning, and trusted publishing.
# Only the publisher receives a socket to its private digest-pinned dind;
# tenant Dockerfiles execute in a separate non-privileged rootless BuildKit.

FROM curlimages/curl:8.16.0@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6 AS ca-certificates

FROM docker:27.5.1-cli@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c AS docker-cli

FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

ARG NIXPACKS_VERSION=1.41.0
ARG NIXPACKS_SHA256=194bcad8c379f78a309eee1a88b2e6b2abc59f354efe7ecd7b4bbaf21de99a06

# System dependencies plus pinned Docker CLI/buildx binaries copied from the
# official digest-pinned image. The trusted publisher talks to its private dind.
COPY --from=ca-certificates --chown=0:0 --chmod=0644 \
    /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN chmod 0755 /etc/ssl /etc/ssl/certs \
    && sed -i \
      -e 's|^URIs: http://deb.debian.org/debian-security$|URIs: https://snapshot.debian.org/archive/debian-security/20260825T000000Z|' \
      -e 's|^URIs: http://deb.debian.org/debian$|URIs: https://snapshot.debian.org/archive/debian/20260825T000000Z|' \
      /etc/apt/sources.list.d/debian.sources \
    && test "$(grep -Fxc 'URIs: https://snapshot.debian.org/archive/debian/20260825T000000Z' /etc/apt/sources.list.d/debian.sources)" = 1 \
    && test "$(grep -Fxc 'URIs: https://snapshot.debian.org/archive/debian-security/20260825T000000Z' /etc/apt/sources.list.d/debian.sources)" = 1 \
    && ! grep -Fq '20260825T000000Z-security' /etc/apt/sources.list.d/debian.sources \
    && ! grep -Eq '^URIs: http://deb\.debian\.org/' /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/50snapshot \
    && printf '%s\n' 'Acquire::https::CAInfo "/etc/ssl/certs/ca-certificates.crt";' > /etc/apt/apt.conf.d/50ca-seed \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates=20250419~deb12u1 \
        curl=7.88.1-10+deb12u15 \
        git=1:2.39.5-0+deb12u3 \
        jq=1.6-2.1+deb12u2 \
        openssh-client=1:9.2p1-2+deb12u10 \
        xz-utils=5.4.1-1+deb12u1 \
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
