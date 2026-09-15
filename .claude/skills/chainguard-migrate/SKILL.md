---
name: chainguard-migrate
description: Migrate a Dockerfile to a Chainguard (cgr.dev) base image, rebuild, rescan, and report the before/after CVE delta. Use when asked to "harden", "chainguard-ify", "reduce CVEs", or "migrate the base image" of a container.
---

# Chainguard migration skill

You are migrating a container to a secure-by-default Chainguard image. Work in this order and show the user each step.

## 1. Baseline
- Build the current Dockerfile as `<name>:before`.
- Run `grype <name>:before -o table` and `docker image inspect --format '{{.Config.User}} {{.Size}}'`.
- Record: total CVEs by severity, size, user (root?), presence of shell / package manager.

## 2. Pick the Chainguard base
Use `base-image-map.md` in this skill folder. Rules:
- Runtime stage uses the minimal tag (`cgr.dev/chainguard/<img>:latest`): no shell, no package manager, user `nonroot` (uid 65532).
- Build stage uses `<img>:latest-dev` (has `apk`, `sh`, `pip`/`npm`, etc.).
- If the app needs a shell at runtime, say so explicitly and keep `-dev` only as a documented exception.
- Language runtimes: copy a venv / `node_modules` / a static binary out of the builder; never `pip install` in the runtime stage.
- Prefer `cgr.dev/chainguard/static` for Go/Rust binaries built with `CGO_ENABLED=0`.

## 3. Rewrite the Dockerfile
- Multi-stage. `COPY --from=builder --chown=nonroot:nonroot`.
- Exec-form `ENTRYPOINT` (no shell to interpret a string form).
- `USER nonroot`, listen on a port > 1024.
- Remove `apt-get`, `curl | sh`, and any `RUN` that assumes a shell in the runtime stage.

## 4. Prove it
- Build as `<name>:after`; rescan with grype; re-inspect.
- Verify the base image signature:
  `cosign verify cgr.dev/chainguard/<img>:latest --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main`
- Smoke test the container (`docker run` + health endpoint).

## 5. Report
Print one table: image | size | total | critical | high | user | shell | pkg manager, before vs after.
Then list anything that still needs a human decision (remaining app-level CVEs in pip/npm packages, features that needed a shell, Kubernetes securityContext now possible: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: [ALL]`).

Never claim zero CVEs without a fresh scan output in the transcript.
