# af-builder

Single-purpose container image that:

1. Clones a connected git repo using a short-lived GitHub App installation token,
2. Runs **Nixpacks** to autodetect the framework (Next.js, Astro, Bun, Go, Rust, …)
   and produce a production image,
3. Pushes the image to `ghcr.io` under our org namespace,
4. POSTs status callbacks (`RUNNING`, `SUCCEEDED`, `FAILED`) back to
   `service-cloud-api` so it can update the `BuildJob` row and dispatch
   the user-chosen compute provider's deploy pipeline on success
   (Akash, Phala, …).

## How it runs

The K8s Job template in `infra/k8s/builder/job.template.yaml` schedules a pod
with **two containers**:

- `dind`  — `docker:24-dind`, privileged. Runs the docker daemon on `tcp://localhost:2375`.
- `builder` — this image. Talks to dind via `DOCKER_HOST=tcp://localhost:2375`.

Privileged is acceptable here: the cluster is single-tenant, the pod is
short-lived (TTL 1h), and the script never executes user-supplied commands
outside Nixpacks.

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

## Env contract (set per-job by service-cloud-api)

| Var | What |
|---|---|
| `BUILD_JOB_ID` | `BuildJob.id` to update |
| `CALLBACK_URL` | `https://api.alternatefutures.ai/internal/build-callback` |
| `CALLBACK_TOKEN` | HMAC-signed one-time token verified by api before mutating BuildJob |
| `REPO_CLONE_URL` | `https://x-access-token:<installation-token>@github.com/<owner>/<repo>.git` |
| `REPO_REF` | full commit SHA (preferred) or branch name |
| `IMAGE_TAG` | `ghcr.io/alternatefutures/<userid>--<repo>:<sha>` |
| `GHCR_USER` | username for `docker login ghcr.io` (typically the bot identity) |
| `GHCR_TOKEN` | PAT with `write:packages` |
| `ROOT_DIRECTORY` | optional, monorepo subdir (default `.`) |
| `BUILD_COMMAND` | optional Nixpacks `--build-cmd` override |
| `START_COMMAND` | optional Nixpacks `--start-cmd` override |
| `DOCKER_HOST` | set by Job template to `tcp://localhost:2375` |
