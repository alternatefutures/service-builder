# af-builder

Single-purpose phased container image that:

1. Clones a connected git repo using a short-lived GitHub App installation token,
2. Runs **Nixpacks** to autodetect the framework (Next.js, Astro, Bun, Go, Rust, …)
   and produce a production image,
3. Pushes the image to `ghcr.io` under our org namespace,
4. POSTs status callbacks (`RUNNING`, `SUCCEEDED`, `FAILED`) back to
   `service-cloud-api` so it can update the `BuildJob` row and dispatch
   the user-chosen compute provider's deploy pipeline on success
   (Akash, Phala, …).

## How it runs securely

The K8s Job template schedules a pod with one init container and four isolated
containers:

- `clone` — init phase with a repository-scoped, read-only GitHub token. It
  fetches the immutable commit, replaces the authenticated remote URL with a
  clean URL, and exits before tenant code runs.
- `planner` — non-root, credential-free phase that detects the framework and
  emits a Dockerfile plus build metadata. It has no container-runtime socket.
- `rootless-buildkit` — pinned, non-privileged BuildKit that executes the
  tenant Dockerfile and exports an image archive. Its security context drops
  all capabilities and it has neither the publisher socket nor credentials.
- `dind` — a separate privileged, digest-pinned daemon used only by the trusted
  publisher. It is a Kubernetes native sidecar init container
  (`restartPolicy: Always`), so kubelet stops it when the regular containers
  finish and the Job terminates normally. It never receives application
  credentials. The deployment requires Kubernetes 1.29 or newer, where native
  sidecars are enabled by default.
- `publisher` — isolated trusted phase with the GHCR and callback credentials.
  It loads the completed archive into its own dind, pushes the exact image tag,
  and posts the terminal callback.

The pod does not share process namespaces and does not mount a service-account
token. Tenant-controlled Dockerfiles and build commands cannot read the clone,
registry, or callback credentials through environment, process inspection, or
a shared Docker control socket. The Fly single-machine executor is rejected by
the API because it cannot provide this isolation boundary.

## Build + push the image

```bash
# from monorepo root
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/alternatefutures/af-builder:latest \
  -f service-builder/Dockerfile \
  service-builder
docker push ghcr.io/alternatefutures/af-builder:latest
```

CI workflow lives at `service-builder/.github/workflows/docker-build.yml`
(builds on push to `main` for any change under `service-builder/`).

## Phase-scoped environment contract

| Var | What |
|---|---|
| `BUILD_JOB_ID` | `BuildJob.id` to update |
| `AF_BUILD_PHASE` | `clone`, `plan`, legacy-local `build`, or `publish` |
| `CALLBACK_URL` | Publisher only; `https://api.alternatefutures.ai/internal/build-callback` |
| `CALLBACK_TOKEN` | Publisher only; HMAC token bound to one BuildJob |
| `REPO_CLONE_URL` | Clone only; repository-scoped read-only installation token |
| `REPO_REF` | full commit SHA (preferred) or branch name |
| `IMAGE_TAG` | `ghcr.io/alternatefutures/<userid>--<repo>:<sha>` |
| `GHCR_USER` | Publisher only; registry username |
| `GHCR_TOKEN` | Publisher only; registry push credential |
| `ROOT_DIRECTORY` | optional, monorepo subdir (default `.`) |
| `BUILD_COMMAND_B64` | optional base64-encoded build-command override |
| `START_COMMAND_B64` | optional base64-encoded start-command override |
| `DOCKER_HOST` | Publisher only; `unix:///var/run/af-docker/docker.sock` |
