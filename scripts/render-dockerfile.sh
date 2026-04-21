#!/usr/bin/env bash
# render-dockerfile.sh — emit a Dockerfile for a detected framework.
#
# Called by build.sh after framework detection. Reads:
#   $1                    — framework label (node, next, fastapi, go, …)
#   $SRC_DIR              — app source dir (for manifest introspection)
#   $BUILD_COMMAND        — optional user override
#   $START_COMMAND        — optional user override
#   $DETECTED_PORT        — optional detected/default port
#
# Writes a single Dockerfile to stdout. Returns 0 if a template matched,
# 1 if the framework isn't handled by any template (caller falls back
# to nixpacks). Keep this deterministic and free of side effects —
# build.sh may call it twice (dry-run then real) in the future.
#
# Design notes:
#   - Prefer official `-slim` / `-alpine` runtime images (~50-100MB)
#     over nixpacks' Ubuntu base (~110MB + a full Nix install).
#   - Multi-stage for compiled langs (go, rust, java). Single-stage
#     for interpreted (node, python, ruby) — the deduplication win
#     is small and it keeps debugging easier.
#   - `--mount=type=cache` on dep installs so buildkit's cross-build
#     cache can populate persistent dep caches across rebuilds. This
#     is the other half of the speedup that makes warm builds 20-40s.
#   - Fallback for BUILD_COMMAND / START_COMMAND: trust scripts in
#     package.json. If they're missing, we emit sensible defaults.
#
# Env pollution on purpose: exported functions only, no global state.

set -euo pipefail

FRAMEWORK="${1:-unknown}"
SRC_DIR="${SRC_DIR:-/workspace}"
BUILD_COMMAND="${BUILD_COMMAND:-}"
START_COMMAND="${START_COMMAND:-}"
DETECTED_PORT="${DETECTED_PORT:-}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Detect node package manager from the lockfile shipped in the repo.
# Order matters — pnpm-lock.yaml beats package-lock.json if both exist
# (happens on half-migrated repos; pnpm is the source of truth there).
detect_node_pm() {
    if   [ -f "$SRC_DIR/pnpm-lock.yaml" ];       then echo "pnpm"
    elif [ -f "$SRC_DIR/bun.lockb" ];            then echo "bun"
    elif [ -f "$SRC_DIR/yarn.lock" ];            then echo "yarn"
    else                                              echo "npm"
    fi
}

# Node install command — frozen-lockfile equivalent per PM. With
# buildkit cache mounts (below), the install is fast on re-runs
# regardless of PM.
node_install_cmd() {
    case "$1" in
        pnpm) echo 'corepack enable && pnpm i --frozen-lockfile' ;;
        yarn) echo 'corepack enable && yarn install --frozen-lockfile' ;;
        bun)  echo 'bun install --frozen-lockfile' ;;
        *)    echo 'npm ci || npm install' ;;
    esac
}

# Where does each PM drop its global package cache? We mount these as
# buildkit cache volumes so re-installs across rebuilds hit the cache.
node_cache_mount() {
    case "$1" in
        pnpm) echo '--mount=type=cache,target=/root/.local/share/pnpm/store' ;;
        yarn) echo '--mount=type=cache,target=/usr/local/share/.cache/yarn' ;;
        bun)  echo '--mount=type=cache,target=/root/.bun/install/cache' ;;
        *)    echo '--mount=type=cache,target=/root/.npm' ;;
    esac
}

# Read a named script out of package.json, defaulting to $2 if absent.
# This is what lets us detect "does the user have a `build` script?"
# so we can conditionally emit a `RUN <pm> run build` line.
node_has_script() {
    [ -f "$SRC_DIR/package.json" ] || return 1
    jq -e --arg name "$1" '.scripts[$name] // empty | length > 0' \
        "$SRC_DIR/package.json" >/dev/null 2>&1
}

# Python package installer — pick based on lockfile.
# Pip's --user install is avoided: everything goes to site-packages so
# the runtime stage can copy it via a standard path.
python_install_block() {
    if   [ -f "$SRC_DIR/poetry.lock" ]; then
        cat <<'EOF'
RUN pip install --no-cache-dir poetry==1.8.3 && \
    poetry config virtualenvs.create false && \
    poetry install --no-interaction --no-ansi --no-root
EOF
    elif [ -f "$SRC_DIR/uv.lock" ]; then
        cat <<'EOF'
RUN pip install --no-cache-dir uv && \
    uv sync --frozen --no-dev
ENV PATH="/app/.venv/bin:$PATH"
EOF
    elif [ -f "$SRC_DIR/requirements.txt" ]; then
        cat <<'EOF'
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt
EOF
    elif [ -f "$SRC_DIR/pyproject.toml" ]; then
        cat <<'EOF'
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir .
EOF
    else
        echo 'RUN echo "[template] no python dependency manifest found"'
    fi
}

# -----------------------------------------------------------------------------
# Template: Node (base for next/nuxt/remix/astro/sveltekit/vite/nestjs/generic)
#
# One unified Node template instead of per-framework variants. Why:
#   1. The "scaffold" of a Node web app is identical across Next, Nuxt,
#      Remix, Astro, SvelteKit, Vite: install deps → build → start.
#   2. Per-framework start commands are already declared in the user's
#      package.json `scripts.start` (`next start`, `nuxt start`, etc.).
#      We call `<pm> start` and it Just Works.
#   3. Per-framework OPTIMIZED outputs (Next's standalone mode, etc.)
#      are something the user opts into in their own config — not our
#      business to know about. Respecting user scripts is the contract.
#
# The one concession to framework-specificity: default ports
# (handled by caller via DETECTED_PORT).
# -----------------------------------------------------------------------------
render_node() {
    local pm
    pm=$(detect_node_pm)
    local install_cmd
    install_cmd=$(node_install_cmd "$pm")
    local cache_mount
    cache_mount=$(node_cache_mount "$pm")
    local has_build="false"
    local has_start="false"
    node_has_script build && has_build="true"
    node_has_script start && has_start="true"

    # Build command precedence: explicit override > package.json `build`
    # script > no-op (framework doesn't need a build step, e.g. Express).
    local build_line="# (no build step)"
    if   [ -n "$BUILD_COMMAND" ];       then build_line="RUN ${BUILD_COMMAND}"
    elif [ "$has_build" = "true" ];     then build_line="RUN ${pm} run build"
    fi

    # Start command precedence: explicit override > package.json `start`
    # script > node server.js guess (works for most express-style apps).
    local start_line
    if   [ -n "$START_COMMAND" ];       then start_line="CMD [\"sh\", \"-c\", \"${START_COMMAND}\"]"
    elif [ "$has_start" = "true" ];     then start_line="CMD [\"${pm}\", \"start\"]"
    else                                     start_line="CMD [\"node\", \"server.js\"]"
    fi

    local port="${DETECTED_PORT:-3000}"

    cat <<EOF
# Auto-generated by render-dockerfile.sh (framework=${FRAMEWORK}, pm=${pm})
# syntax=docker/dockerfile:1.7
FROM node:20-slim
WORKDIR /app

# Minimal set of runtime shared libs. We deliberately don't install
# build-essential — if a dep needs native compilation (better-sqlite3,
# sharp, bcrypt, …) it'll fail loudly and the user can either switch
# to the prebuilt variant of their dep OR drop their own Dockerfile.
RUN apt-get update && apt-get install -y --no-install-recommends \\
        ca-certificates openssl \\
    && rm -rf /var/lib/apt/lists/*

# Enable pnpm/yarn via corepack (idempotent; safe if pm=npm).
RUN corepack enable && corepack prepare --activate 2>/dev/null || true

# Copy manifest files first so the dep-install layer caches when
# source code changes without touching deps. Standard buildkit pattern.
COPY package.json ./
COPY package-lock.json* pnpm-lock.yaml* yarn.lock* bun.lockb* ./

RUN ${cache_mount} \\
    ${install_cmd}

COPY . .
${build_line}

ENV PORT=${port} NODE_ENV=production
EXPOSE ${port}
${start_line}
EOF
}

# -----------------------------------------------------------------------------
# Template: Python (fastapi / flask / django / generic)
#
# Same philosophy as Node — one template, framework-specific defaults
# only for the start command.
# -----------------------------------------------------------------------------
render_python() {
    local install_block
    install_block=$(python_install_block)

    local port="${DETECTED_PORT:-8000}"

    # Default start command per framework. User can override via
    # START_COMMAND. These match what nixpacks / Heroku / Render
    # expect out of the box.
    local start_line
    if [ -n "$START_COMMAND" ]; then
        start_line="CMD [\"sh\", \"-c\", \"${START_COMMAND}\"]"
    else
        case "$FRAMEWORK" in
            fastapi) start_line="CMD [\"sh\", \"-c\", \"uvicorn main:app --host 0.0.0.0 --port \${PORT:-${port}}\"]" ;;
            flask)   start_line="CMD [\"sh\", \"-c\", \"gunicorn -b 0.0.0.0:\${PORT:-${port}} app:app\"]" ;;
            django)  start_line="CMD [\"sh\", \"-c\", \"python manage.py migrate --noinput && gunicorn -b 0.0.0.0:\${PORT:-${port}} \${DJANGO_WSGI:-config.wsgi}:application\"]" ;;
            *)       start_line="CMD [\"sh\", \"-c\", \"python main.py\"]" ;;
        esac
    fi

    local build_line="# (python: no build step)"
    [ -n "$BUILD_COMMAND" ] && build_line="RUN ${BUILD_COMMAND}"

    # django/flask need gunicorn; fastapi needs uvicorn. Ship them as
    # implicit runtime deps so the default CMD works even if the user's
    # requirements.txt forgot to pin them. Idempotent if already present.
    local wsgi_deps="gunicorn==22.0.0 uvicorn[standard]==0.30.6"

    cat <<EOF
# Auto-generated by render-dockerfile.sh (framework=${FRAMEWORK})
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim
WORKDIR /app

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# Minimal system deps. libpq for psycopg2, build-essential for anything
# that falls through to compiling C extensions (cryptography, numpy on
# niche archs, …). Kept thin; users with exotic needs drop their own
# Dockerfile.
RUN apt-get update && apt-get install -y --no-install-recommends \\
        build-essential ca-certificates curl libpq-dev \\
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt* pyproject.toml* poetry.lock* uv.lock* setup.py* ./
${install_block}

# Belt-and-suspenders: ensure a WSGI/ASGI server is available regardless
# of what the user pinned. Idempotent if already installed.
RUN --mount=type=cache,target=/root/.cache/pip \\
    pip install --no-cache-dir ${wsgi_deps}

COPY . .
${build_line}

ENV PORT=${port}
EXPOSE ${port}
${start_line}
EOF
}

# -----------------------------------------------------------------------------
# Template: Go
# -----------------------------------------------------------------------------
render_go() {
    local port="${DETECTED_PORT:-8080}"
    local build_cmd="${BUILD_COMMAND:-go build -o /out/app ./...}"

    cat <<EOF
# Auto-generated by render-dockerfile.sh (framework=go)
# syntax=docker/dockerfile:1.7
FROM golang:1.23-alpine AS builder
WORKDIR /app

ENV CGO_ENABLED=0 GOFLAGS=-trimpath

COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \\
    --mount=type=cache,target=/root/.cache/go-build \\
    mkdir -p /out && ${build_cmd}

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/app /app/app

ENV PORT=${port}
EXPOSE ${port}
CMD ["/app/app"]
EOF
}

# -----------------------------------------------------------------------------
# Template: Rust
# -----------------------------------------------------------------------------
render_rust() {
    local port="${DETECTED_PORT:-8080}"
    local build_cmd="${BUILD_COMMAND:-cargo build --release --locked}"

    cat <<EOF
# Auto-generated by render-dockerfile.sh (framework=rust)
# syntax=docker/dockerfile:1.7
FROM rust:1.82-slim AS builder
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \\
        build-essential pkg-config libssl-dev \\
    && rm -rf /var/lib/apt/lists/*

COPY . .

RUN --mount=type=cache,target=/usr/local/cargo/registry \\
    --mount=type=cache,target=/app/target \\
    ${build_cmd} && \\
    mkdir -p /out && \\
    # cargo drops the final binary at target/release/<crate-name>. Grab
    # the first non-dotted file in target/release that's executable —
    # works for single-binary crates (the common case). Workspaces with
    # multiple bins need a user Dockerfile or BUILD_COMMAND override.
    BIN=\$(find target/release -maxdepth 1 -type f -executable ! -name '*.*' | head -n1) && \\
    cp "\$BIN" /out/app

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \\
        ca-certificates openssl \\
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /out/app /app/app

ENV PORT=${port}
EXPOSE ${port}
CMD ["/app/app"]
EOF
}

# -----------------------------------------------------------------------------
# Template: Ruby/Rails (single-stage, bundler)
# -----------------------------------------------------------------------------
render_ruby() {
    local port="${DETECTED_PORT:-3000}"
    local start_line
    if [ -n "$START_COMMAND" ]; then
        start_line="CMD [\"sh\", \"-c\", \"${START_COMMAND}\"]"
    elif [ "$FRAMEWORK" = "rails" ]; then
        start_line="CMD [\"sh\", \"-c\", \"bundle exec rails db:migrate 2>/dev/null || true; bundle exec rails server -b 0.0.0.0 -p \${PORT:-${port}}\"]"
    else
        start_line="CMD [\"sh\", \"-c\", \"bundle exec ruby app.rb\"]"
    fi
    local build_line="# (ruby: assets:precompile happens via $START_COMMAND for Rails)"
    [ -n "$BUILD_COMMAND" ] && build_line="RUN ${BUILD_COMMAND}"

    cat <<EOF
# Auto-generated by render-dockerfile.sh (framework=${FRAMEWORK})
# syntax=docker/dockerfile:1.7
FROM ruby:3.3-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \\
        build-essential ca-certificates curl libpq-dev libyaml-dev nodejs \\
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN --mount=type=cache,target=/usr/local/bundle \\
    bundle config set --local deployment true && \\
    bundle config set --local without 'development test' && \\
    bundle install

COPY . .
${build_line}

ENV PORT=${port} RAILS_ENV=production RACK_ENV=production
EXPOSE ${port}
${start_line}
EOF
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$FRAMEWORK" in
    node|next|nuxt|remix|astro|svelte|sveltekit|vite|nestjs)
        render_node ;;
    python|fastapi|flask|django)
        render_python ;;
    go)
        render_go ;;
    rust)
        render_rust ;;
    ruby|rails)
        render_ruby ;;
    *)
        # No template for this framework — caller (build.sh) falls back
        # to nixpacks. Exit 1 so the caller can branch on $?.
        echo "[render-dockerfile] no template for framework='$FRAMEWORK'; defer to nixpacks" >&2
        exit 1 ;;
esac
