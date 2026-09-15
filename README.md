# Chainguard on AKS: secure-by-default images, end to end

Demo companion for the *Cloud Native Partner Showcase* episode with Chainguard.
Same 40-line FastAPI app, built two ways, deployed side by side on Azure Kubernetes
Service, with the supply-chain proof points a platform team actually needs:
CVE delta, SBOMs, Sigstore signatures, admission policy, and an AI "agent skill"
that migrates Dockerfiles for you.

```
                 docker/Dockerfile.upstream          docker/Dockerfile.chainguard
                 python:3.13-slim  (root, shell)     cgr.dev/chainguard/python (nonroot, no shell)
                          │                                    │
   make scan ──► grype/trivy ──► out/*.grype.json ──► compare table + out/report.html
   make verify ─► cosign verify (keyless)  ──► Chainguard release identity + Rekor
   make sbom ───► syft SBOM + Chainguard's signed SBOM attestation
   make acr-push ─► Azure Container Registry (linux/amd64)
   make deploy ──► AKS: app-upstream + app-chainguard (LoadBalancer each)
   make policy ──► Kyverno: registry allow-list + signature verification
```

## Results on this machine (2026-09-15)

| image      | size  | CVEs | crit | high | user    | shell | pkg mgr |
|------------|-------|------|------|------|---------|-------|---------|
| upstream   | 248MB | 178  | 7    | 61   | root    | yes   | yes     |
| chainguard | 140MB | 5    | 0    | 1    | nonroot | no    | no      |

The 5 left on Chainguard are Wolfi packages with fixes already queued (zlib) or
no upstream fix (python). Rebuild tomorrow and the number moves; that is the point.

## Results on AKS (2026-09-15, piquantbs subscription, Central India)

Two `Standard_D2s_v4` nodes, both flavours behind LoadBalancer services, Kyverno enforcing
a registry allow-list and keyless signature verification for `cgr.dev/chainguard/*`.

| endpoint | os | uid | shell | pkg mgr | os packages |
|---|---|---|---|---|---|
| `/api` on upstream   | Debian GNU/Linux 13 (trixie) | 0     | yes | yes | 87 |
| `/api` on chainguard | Wolfi                        | 65532 | no  | no  | 26 |

`docker.io/library/nginx:latest` is rejected by the `restrict-image-registries` policy;
`cgr.dev/chainguard/nginx:latest` is admitted after Kyverno verifies its Sigstore signature.

Two gotchas found on the way, both fixed in this repo:
- ACR Tasks uses the legacy builder, which creates `WORKDIR` as root; the builder stage now works in `/home/nonroot`.
- `USER nonroot` (a name) plus `runAsNonRoot: true` gives `CreateContainerConfigError`; the deployment pins `runAsUser: 65532`.

## Quick start (local, no Azure)

```bash
make tools      # brew: trivy grype syft cosign crane
make demo       # build -> scan -> verify -> sbom -> report (opens out/report.html)
make run        # http://localhost:8081 (upstream)  http://localhost:8082 (chainguard)
make stop
```

## Azure path

```bash
cp .env.example .env    # set ACR (globally unique), region, names
az login --tenant <tenant-id>; az account set -s <subscription>
make aks-up             # RG + ACR + 2-node AKS, ACR attached          (~6 min)
                        # NODE_SIZE defaults to Standard_D2s_v4; pick one your subscription has quota for
make acr-push           # buildx linux/amd64 both flavours -> ACR (or: az acr build, no local Docker needed)
make deploy             # both deployments + LoadBalancer services
make policy             # Kyverno + policies, then tries an unsigned Docker Hub image (rejected)
kubectl apply -f k8s/pod-chainguard-nginx.yaml   # signed cgr.dev image (admitted)
make aks-down
```

## Demo runbook (15 min talk track)

1. **The problem** (2 min). `docker run -it demo-app:upstream sh` -> a shell, apt, root.
   "This is what most teams ship. 178 CVEs and none of them are in our code."
2. **Same app, different base** (3 min). Show the two Dockerfiles side by side.
   Multi-stage: build on `latest-dev`, run on `latest`. `make scan` -> the table.
   Try `docker run -it demo-app:chainguard sh` -> fails, no shell to exec into.
3. **Trust, not vibes** (3 min). `make verify`: keyless Sigstore signature from
   Chainguard's GitHub release workflow, recorded in Rekor. `make sbom`: our SBOM
   plus the SBOM attestation Chainguard already published. Compliance answer ready.
4. **On AKS** (4 min). Open both LoadBalancer IPs: red page vs green page,
   uid 0 vs 65532, 87 vs 26 OS packages. Show `k8s/deploy-chainguard.yaml`:
   `readOnlyRootFilesystem`, `drop: [ALL]` are only possible because the image cooperates.
   `make policy`: Kyverno rejects an unsigned Docker Hub image, admits `cgr.dev/chainguard/nginx`.
5. **Agent skills** (3 min). In Claude Code, in this repo: *"use the chainguard-migrate
   skill on docker/Dockerfile.upstream"*. The skill (`.claude/skills/chainguard-migrate/`)
   baselines, rewrites to a Chainguard multi-stage image, rescans, and reports the delta.
   Reference CI in `.github/workflows/supply-chain.yml`: SBOM -> scan gate -> keyless sign -> ACR.

## Where Azure fits

- **Azure Container Registry**: private home for the rebuilt images; AKS pulls via managed identity (`--attach-acr`).
- **Azure Marketplace**: Chainguard is listed for procurement through Azure commitments.
- **Azure Artifacts**: Chainguard Libraries (Python/Java) can be fronted as an upstream feed so `pip`/`maven` resolve rebuilt-from-source packages. Needs a Chainguard account; not wired here.
- **Pinned tags** (`python:3.13` rather than `latest`) and the full catalog need a Chainguard account (`chainctl`). This demo only uses the free `latest` / `latest-dev` images.

## Layout

```
app/                 FastAPI app that reports the runtime it is on (/ , /api, /healthz)
docker/              Dockerfile.upstream, Dockerfile.chainguard
scripts/             build, scan, compare, sbom, verify, report, aks-up, acr-push, deploy, policy
k8s/                 namespace (PSS labels), two deployments, Kyverno policies, signed-nginx test pod
.claude/skills/      chainguard-migrate agent skill + base image map
.github/workflows/   reference supply-chain pipeline
out/                 scan JSON, SBOMs, report.html (gitignored)
```
