---
title: "Same app, two base images: 178 CVEs vs 5. A hands-on Chainguard on AKS walkthrough"
published: false
description: "Step by step: build one FastAPI app on python:3.13-slim and on a Chainguard image, scan, verify signatures, ship SBOMs, deploy to AKS behind a Kyverno policy, and let an AI agent skill do the migration."
tags: kubernetes, azure, security, devops
cover_image: (upload docs/img/09-report.png and paste the URL here)
---

I watched the *Cloud Native Partner Showcase* episode where Microsoft's David Giard talks to Hannah Hawken and Manfred Moser from Chainguard about secure-by-default container images on Azure Kubernetes Service. Good conversation, but I wanted numbers I produced myself. So I built the smallest possible demo that proves or disproves the pitch, and this post is that demo, step by step, with the actual output.

Everything below runs on a laptop with Docker. The Azure part is optional and takes about ten minutes.

**Repo:** `github.com/<you>/chainguard-aks-demo` (replace with your fork)

## What we are testing

The claim from the episode: Chainguard images are minimal, rebuilt continuously from source, signed, and ship with an SBOM, so most CVEs never reach your cluster in the first place.

The test: one 40-line FastAPI app, built two ways.

| | upstream | chainguard |
|---|---|---|
| base image | `python:3.13-slim` | `cgr.dev/chainguard/python` |
| user | root | nonroot (65532) |
| shell / package manager | yes | no |

Then scan both, inspect both, deploy both, and see what the difference actually is.

## Prerequisites

```bash
brew install trivy grype syft cosign crane      # scanners, SBOM, signing
# also: docker, kubectl, helm, azure-cli
```

## Step 1: the app

The app deliberately reports what it is running on: OS, uid, whether a shell exists, how many OS packages are installed. Same code in both images.

```python
def facts() -> dict:
    return {
        "image_flavor": os.getenv("IMAGE_FLAVOR"),
        "os": os_release(),                     # /etc/os-release PRETTY_NAME
        "uid": os.getuid(),
        "shell_present": any(Path(p).exists() for p in ("/bin/sh", "/bin/bash")),
        "package_manager_present": any(Path(p).exists() for p in ("/usr/bin/apt", "/sbin/apk", "/usr/bin/pip")),
        "os_packages": package_count(),         # dpkg or apk database
    }
```

## Step 2: two Dockerfiles

The upstream one is what most tutorials show you:

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/main.py .
ENV IMAGE_FLAVOR=upstream
CMD ["python", "main.py"]
```

The Chainguard one is multi-stage. The `-dev` tag has pip and a shell so you can build; the plain tag has neither, so you only copy the result in:

```dockerfile
FROM cgr.dev/chainguard/python:latest-dev AS builder
WORKDIR /app
RUN python -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM cgr.dev/chainguard/python:latest
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /app/venv /app/venv
COPY --chown=nonroot:nonroot app/main.py .
ENV PATH="/app/venv/bin:$PATH" IMAGE_FLAVOR=chainguard
USER nonroot
ENTRYPOINT ["python", "main.py"]
```

Two things bite people here. There is no shell in the runtime image, so `CMD python main.py` (string form) fails; use the exec form. And `pip install` must happen in the builder stage, never in the runtime stage.

## Step 3: build

```bash
docker build -f docker/Dockerfile.upstream   -t demo-app:upstream .
docker build -f docker/Dockerfile.chainguard -t demo-app:chainguard .
docker images demo-app
```

![docker images: 248MB vs 140MB](img/02-images.png)

## Step 4: scan

```bash
grype demo-app:upstream   -o table
grype demo-app:chainguard -o table
```

![grype output for both images](img/04-grype.png)

A small script summarises the two JSON reports into one table:

![comparison table: 178 CVEs vs 5](img/01-compare.png)

Same app. 178 known CVEs versus 5. Zero critical on the Chainguard side, and the five that remain are Wolfi packages with a fix already queued (zlib) or with no upstream fix yet (python). Rebuild tomorrow and the count moves. That is the "continuously rebuilt" part of the pitch working as described.

An honest note: my first scan showed 12 on the Chainguard side, not 5. Seven of those were in `starlette`, because I had pinned an old FastAPI in `requirements.txt`. The base image cannot fix your dependency file. Application-level CVEs stay your job.

## Step 5: poke around inside

```bash
docker run --rm -it demo-app:upstream sh -c "id; which apt-get; ls /bin | wc -l"
docker run --rm -it --entrypoint sh demo-app:chainguard
```

![upstream: root with apt-get and 259 binaries; chainguard: no sh at all](img/03-shell.png)

The upstream container runs as root with apt-get and 259 binaries available to anyone who gets code execution. The Chainguard container cannot even start a shell. For debugging you use `kubectl debug` with an ephemeral container, which is a workflow change worth planning for (see cons below).

## Step 6: verify the base image is really from Chainguard

Chainguard signs every image with Sigstore keyless signing from their GitHub release workflow. You can check that without any keys:

```bash
cosign verify cgr.dev/chainguard/python:latest \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
```

![cosign verify output showing issuer and identity](img/05-verify.png)

The signature is in the public Rekor transparency log. This is the difference between "we pulled an image called python" and "we pulled the image Chainguard's release pipeline built".

## Step 7: SBOMs, yours and theirs

```bash
syft demo-app:upstream   -o spdx-json > out/upstream.sbom.spdx.json
syft demo-app:chainguard -o spdx-json > out/chainguard.sbom.spdx.json

# the SBOM Chainguard already attested for the base image
cosign verify-attestation cgr.dev/chainguard/python:latest --type https://spdx.dev/Document \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
```

![syft SBOM package counts, 109 vs 47](img/06-sbom.png)

109 packages to account for versus 47. When someone from compliance asks "are we affected by CVE-X", the smaller list answers faster.

## Step 8: run both and look

```bash
docker run -d -p 8081:8080 demo-app:upstream
docker run -d -p 8082:8080 demo-app:chainguard
```

![upstream app page: Debian, uid 0, shell present, 87 packages](img/07-app-upstream.png)

![chainguard app page: Wolfi, uid 65532, no shell, 26 packages](img/08-app-chainguard.png)

And the one-page report the scan script generates, useful for a slide:

![HTML report comparing both images](img/09-report.png)

## Step 9: Azure Container Registry and AKS

This part costs money. Two B-series nodes for an hour is well under a dollar, but delete the resource group when done.

```bash
az login --tenant <tenant-id>
az group create -n rg-chainguard-demo -l centralindia
az acr create -n <uniqueacrname> -g rg-chainguard-demo --sku Basic
az aks create -n aks-chainguard-demo -g rg-chainguard-demo --node-count 2 \
  --node-vm-size Standard_B2s_v2 --attach-acr <uniqueacrname> --generate-ssh-keys
az aks get-credentials -n aks-chainguard-demo -g rg-chainguard-demo

az acr login -n <uniqueacrname>
docker buildx build --platform linux/amd64 -f docker/Dockerfile.chainguard \
  -t <uniqueacrname>.azurecr.io/demo-app:chainguard --push .
```

Attaching ACR to AKS means the nodes pull with managed identity, no image pull secrets. Build for `linux/amd64` if you are on Apple Silicon, since the default AKS node pool is x86.

The Chainguard deployment can turn on every hardening knob because the image cooperates:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
```

Try the same block on the upstream image and the pod fails `runAsNonRoot` immediately, because the image runs as uid 0.

## Step 10: enforce it with Kyverno

Scanning tells you. Admission control stops you. Two Kyverno policies:

```yaml
# only trusted registries in this namespace
validate:
  message: "Images must come from cgr.dev or *.azurecr.io"
  pattern:
    spec:
      containers:
        - image: "cgr.dev/* | *.azurecr.io/*"
```

```yaml
# every cgr.dev image must carry Chainguard's keyless signature
verifyImages:
  - imageReferences: ["cgr.dev/chainguard/*"]
    attestors:
      - entries:
          - keyless:
              subject: "https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main"
              issuer: "https://token.actions.githubusercontent.com"
              rekor: { url: https://rekor.sigstore.dev }
```

```bash
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl apply -f k8s/policies/
kubectl -n chainguard-demo run bad --image=docker.io/library/nginx:latest   # rejected
kubectl apply -f k8s/pod-chainguard-nginx.yaml                              # admitted
```

## Step 11: the "agent skill" part

The episode ends on AI-assisted workflows. I turned the migration steps above into a Claude Code skill (`.claude/skills/chainguard-migrate/SKILL.md`) plus a base-image mapping table. In the repo you say:

> use the chainguard-migrate skill on docker/Dockerfile.upstream

and the agent baselines the image with grype, rewrites the Dockerfile to the multi-stage Chainguard pattern, rebuilds, rescans, verifies the base image signature and prints the before/after table. The skill's last rule is the important one: *never claim zero CVEs without a fresh scan in the transcript.* Agents that write security claims need receipts.

## Pros

- **The CVE delta is real, not marketing.** 178 to 5 on the same app, with the remaining 5 traceable to two packages.
- **Smaller attack surface by construction.** No shell, no package manager, nonroot by default. A large class of post-exploitation tricks simply has nothing to run.
- **Signatures and SBOMs are already there.** You verify with public tooling, no vendor account needed for the free images.
- **Kubernetes hardening becomes possible.** `readOnlyRootFilesystem`, `drop: ALL`, PSS restricted profile. These fail on most upstream images.
- **Less scanner noise.** Fewer findings means the ones left get read. Security teams stop being the department of 178 tickets.
- **Fits Azure without glue.** Push to ACR, attach to AKS, listed on Azure Marketplace for procurement.

## Cons

- **Debugging changes.** No shell means `kubectl exec` is gone. You need `kubectl debug` with ephemeral containers, and your on-call runbooks need updating.
- **Free tier is `latest` only.** Version-pinned tags (`python:3.12`) and the full catalog need a paid Chainguard account. For reproducible enterprise builds that is a budget conversation.
- **Wolfi is not Debian.** Different package names, `apk` not `apt`, paths differ. Every `RUN apt-get install` in your Dockerfiles needs rethinking.
- **Multi-stage is mandatory.** Single-stage Dockerfiles with build tools in the runtime image will not work. Good discipline, but it is work.
- **Your dependencies are still yours.** My first scan had 12 findings and 7 were my outdated FastAPI pin. The base image does not fix `requirements.txt`, `package.json` or `pom.xml`.
- **Vendor concentration.** You are trusting one company's rebuild pipeline. The signatures let you verify that trust, but it is a new dependency in your supply chain.

## Who benefits

- **Platform teams on AKS** who own the golden-image catalog and are tired of re-patching Debian bases every week.
- **Regulated teams** (finance, health, public sector) who need SBOMs, provenance and a credible answer to "how do you know what is in production".
- **Small teams with no security engineer.** Swapping the base image is the highest-leverage security change per hour of effort I know of.
- **Anyone adopting Pod Security Standards restricted.** You cannot pass it with root images; this is the shortcut.
- **Teams introducing AI coding agents.** A skill like the one above turns "harden this container" into a repeatable, auditable action instead of a vibe.

Who should wait: teams whose apps genuinely need a shell or system packages at runtime, and teams that need pinned versions but have no budget for the paid catalog yet.

## Try it

```bash
git clone https://github.com/<you>/chainguard-aks-demo && cd chainguard-aks-demo
make tools && make demo     # build, scan, verify, sbom, report. No Azure required.
```

If your numbers differ from mine, that is expected. The whole point is that both images change every day, and only one of them changes in your favour.
