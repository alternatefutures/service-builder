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
a shared Docker control socket.

`Dockerfile.fly` is the compatibility executor used while the production API
still dispatches ephemeral Fly Machines. It runs the same clone, build, and
publish phases in sequence, strips clone, registry, and callback credentials
from the build phase's child environment, and enforces a hard runtime cap. It
publishes under an immutable `-fly` tag in the public platform-builder package;
customer source repositories and resulting application images remain private.
The Kubernetes executor above remains the preferred stronger isolation model.

Both production and staging run `BUILD_EXECUTOR=fly` today
(`infra/k8s/api/configmap*.yaml`); `alternate-clouds-api/src/services/github/flyioBuilder.ts`
spawns one Fly Machine per build from the digest-pinned
`VERIFIED_FLY_BUILDER_IMAGE`, built from `Dockerfile.fly` at commit `abb3d4d`
(Docker 29.8.2 + the `docker-container` buildx driver). Two newer commits on
`fix/fly-docker-buildx-driver` (`cced983`, `fbce461`, adding
`scripts/buildx-driver.sh`) are not in any published image yet.

Fly builders need a persistent cache volume (`FLY_BUILDER_CACHE_VOLUME`):
dockerd's data-root must live on the ext4 volume, because the Firecracker
rootfs is refused as an overlayfs upperdir and buildkit dies at boot. A volume
Fly no longer knows fails the spawn (`FlyBuilderConfigError`) instead of
falling back to an ephemeral data-root (2026-10-15 incident, Phase 111 in
`admin/cloud/docs/AF_DEVELOPMENT_PROCESS.md`).

### Cache-volume housekeeping (2026-10-17, Phase 119)

Nothing pruned the data-root until now, so a 20 GB pool volume filled within a
day of ML builds and three hackathon builds died with `no space left on device`
(2026-10-16). `build-fly.sh` now checks the volume's free space after dockerd
is up and BEFORE the build (never during one: the volume is single-attach and
this machine is its only user) and, under the minimum, prunes:

| Var | Default | What |
|---|---|---|
| `AF_CACHE_MIN_FREE_GB` | `8` | Prune when the volume has less than this free |
| `AF_CACHE_PRUNE_KEEP_GB` | `6` | `docker buildx prune --builder af-buildkit --all --force --reserved-space=<N>GB` (Docker 29 has no `--keep-storage`; the cache lives in the docker-container builder's state volume, so the builder is named explicitly) |
| `AF_CACHE_PRUNE_IMAGE_AGE_HOURS` | `24` | `docker image prune --all --force --filter until=<N>h` |

Before/after free GB are printed as `[build-fly] cache prune done: 3.1 GB ->
12.4 GB free` and recorded in the `[builder] telemetry` line
(`cache_prune_free_gb_before` / `cache_prune_free_gb_after`, `null` when no
prune ran). The API forwards `FLY_BUILDER_CACHE_MIN_FREE_GB`,
`FLY_BUILDER_CACHE_PRUNE_KEEP_GB` and `FLY_BUILDER_CACHE_PRUNE_IMAGE_AGE_HOURS`
from its configmap into these machine env vars when set. The pinned
`VERIFIED_FLY_BUILDER_IMAGE` predates this step: it takes effect only once the
Fly image is rebuilt from this commit and re-pinned in `flyioBuilder.ts` and
both API configmaps.

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
| `AF_CACHE_ROOT` | Fly only; mount path of the attached cache volume (dockerd data-root lives in `<root>/dockerd`) |
| `AF_BUILD_TIMEOUT_SECONDS` | Fly only; runtime cap enforced by `build-fly.sh` (default 900) |
| `AF_CACHE_MIN_FREE_GB` / `AF_CACHE_PRUNE_KEEP_GB` / `AF_CACHE_PRUNE_IMAGE_AGE_HOURS` | Fly only; pre-build prune thresholds (see "Cache-volume housekeeping") |
