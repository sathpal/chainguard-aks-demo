---
title: "Same app, two base images: 178 CVEs vs 5. A hands-on Chainguard on AKS walkthrough"
published: false
description: "Step by step: build one FastAPI app on python:3.13-slim and on a Chainguard image, scan, verify signatures, ship SBOMs, deploy to AKS behind a Kyverno policy, and let an AI agent skill do the migration."
tags: kubernetes, azure, security, devops
cover_image: https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/09-report.png
---

I watched the *Cloud Native Partner Showcase* episode where Microsoft's David Giard talks to Hannah Hawken and Manfred Moser from Chainguard about secure-by-default container images on Azure Kubernetes Service. Good conversation, but I wanted numbers I produced myself. So I built the smallest possible demo that proves or disproves the pitch, and this post is that demo, step by step, with the actual output.

Everything below runs on a laptop with Docker. The Azure part is optional and takes about ten minutes.

**Repo:** [github.com/sathpal/chainguard-aks-demo](https://github.com/sathpal/chainguard-aks-demo)

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
WORKDIR /home/nonroot
RUN python -m venv venv
ENV PATH="/home/nonroot/venv/bin:$PATH"
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM cgr.dev/chainguard/python:latest
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /home/nonroot/venv /app/venv
COPY --chown=nonroot:nonroot app/main.py .
ENV PATH="/app/venv/bin:$PATH" IMAGE_FLAVOR=chainguard
USER nonroot
ENTRYPOINT ["python", "main.py"]
```

Three things bite people here. There is no shell in the runtime image, so `CMD python main.py` (string form) fails; use the exec form. `pip install` must happen in the builder stage, never in the runtime stage. And the builder stage works inside `/home/nonroot`, a directory that already exists and belongs to the nonroot user. The `-dev` image runs as nonroot, and while BuildKit creates a new `WORKDIR` owned by the current user, the legacy builder that ACR Tasks still uses creates it as root, so `WORKDIR /app` followed by `python -m venv venv` fails with permission denied the moment you build in the cloud instead of on your laptop. I found that one the hard way later in this post.

## Step 3: build

```bash
docker build -f docker/Dockerfile.upstream   -t demo-app:upstream .
docker build -f docker/Dockerfile.chainguard -t demo-app:chainguard .
docker images demo-app
```

![docker images: 248MB vs 140MB](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/02-images.png)

## Step 4: scan

```bash
grype demo-app:upstream   -o table
grype demo-app:chainguard -o table
```

![grype output for both images](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/04-grype.png)

A small script summarises the two JSON reports into one table:

![comparison table: 178 CVEs vs 5](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/01-compare.png)

Same app. 178 known CVEs versus 5. Zero critical on the Chainguard side, and the five that remain are Wolfi packages with a fix already queued (zlib) or with no upstream fix yet (python). Rebuild tomorrow and the count moves. That is the "continuously rebuilt" part of the pitch working as described.

An honest note: my first scan showed 12 on the Chainguard side, not 5. Seven of those were in `starlette`, because I had pinned an old FastAPI in `requirements.txt`. The base image cannot fix your dependency file. Application-level CVEs stay your job.

## Step 5: poke around inside

```bash
docker run --rm -it demo-app:upstream sh -c "id; which apt-get; ls /bin | wc -l"
docker run --rm -it --entrypoint sh demo-app:chainguard
```

![upstream: root with apt-get and 259 binaries; chainguard: no sh at all](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/03-shell.png)

The upstream container runs as root with apt-get and 259 binaries available to anyone who gets code execution. The Chainguard container cannot even start a shell. For debugging you use `kubectl debug` with an ephemeral container, which is a workflow change worth planning for (see cons below).

## Step 6: verify the base image is really from Chainguard

Chainguard signs every image with Sigstore keyless signing from their GitHub release workflow. You can check that without any keys:

```bash
cosign verify cgr.dev/chainguard/python:latest \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
```

![cosign verify output showing issuer and identity](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/05-verify.png)

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

![syft SBOM package counts, 109 vs 47](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/06-sbom.png)

109 packages to account for versus 47. When someone from compliance asks "are we affected by CVE-X", the smaller list answers faster.

## Step 8: run both and look

```bash
docker run -d -p 8081:8080 demo-app:upstream
docker run -d -p 8082:8080 demo-app:chainguard
```

![upstream app page: Debian, uid 0, shell present, 87 packages](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/07-app-upstream.png)

![chainguard app page: Wolfi, uid 65532, no shell, 26 packages](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/08-app-chainguard.png)

And the one-page report the scan script generates, useful for a slide:

![HTML report comparing both images](https://raw.githubusercontent.com/sathpal/chainguard-aks-demo/main/docs/img/09-report.png)

## Step 9: Azure Container Registry and AKS

This part costs money. Two small nodes for an hour is about a dollar, but delete the resource group when done.

```bash
az login --tenant <tenant-id>
az group create -n rg-chainguard-demo -l centralindia
az acr create -n sathpalcgdemo -g rg-chainguard-demo --sku Basic
az aks create -n aks-chainguard-demo -g rg-chainguard-demo --node-count 2 \
  --node-vm-size Standard_D2s_v4 --attach-acr sathpalcgdemo --generate-ssh-keys
az aks get-credentials -n aks-chainguard-demo -g rg-chainguard-demo

az acr login -n sathpalcgdemo
docker buildx build --platform linux/amd64 -f docker/Dockerfile.chainguard \
  -t sathpalcgdemo.azurecr.io/demo-app:chainguard --push .
```

Attaching ACR to AKS means the nodes pull with managed identity, no image pull secrets. Build for `linux/amd64` if you are on Apple Silicon, since the default AKS node pool is x86.

Or skip local Docker entirely and let the registry build it. My laptop's disk filled up halfway through this post and Docker Desktop stopped working, so the Chainguard image in the cluster was actually built by ACR Tasks:

```bash
az acr build -r sathpalcgdemo -f docker/Dockerfile.chainguard -t demo-app:chainguard --platform linux/amd64 .
```

That is also where the `WORKDIR /home/nonroot` gotcha from Step 2 bit me. ACR Tasks uses the legacy builder, and my original `WORKDIR /app` failed with `Permission denied: '/app/venv'` on the first cloud build.

Two `Standard_D2s_v4` nodes came up in about six minutes. If your subscription refuses the VM size, `az vm list-usage -l <region> -o table` shows which families you have quota for; mine had zero for B-series in Central India.

```
$ kubectl get nodes
NAME                                STATUS   ROLES    AGE     VERSION
aks-nodepool1-13038109-vmss000000   Ready    <none>   7m17s   v1.35.7
aks-nodepool1-13038109-vmss000001   Ready    <none>   7m16s   v1.35.7
```

The Chainguard deployment can turn on every hardening knob because the image cooperates:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
```

Try the same block on the upstream image and the pod fails `runAsNonRoot` immediately, because the image runs as uid 0.

The `runAsUser: 65532` line is not decoration. The Chainguard base image declares its user numerically, but my Dockerfile overrides it with `USER nonroot`, a name, and the kubelet refuses to start a `runAsNonRoot` container when it cannot prove the user is non-root from a name alone. Either write `USER 65532` in the Dockerfile or pin the uid in the pod spec; I did the latter so the fix is visible in the manifest. My first rollout sat in `CreateContainerConfigError` with exactly that message:

```
Error: container has runAsNonRoot and image has non-numeric user (nonroot),
cannot verify user is non-root
```

Give it the numeric uid and it starts. Both deployments, each behind its own LoadBalancer:

```
$ kubectl -n chainguard-demo get pods,svc
NAME                              READY   STATUS    RESTARTS   AGE
app-chainguard-6f776d7959-nprs9   1/1     Running   0          89s
app-upstream-574978df4f-4pf9g     1/1     Running   0          5m6s
nginx-signed                      1/1     Running   0          49s
NAME             TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
app-chainguard   LoadBalancer   10.0.67.88     98.70.244.97     80:30308/TCP   5m5s
app-upstream     LoadBalancer   10.0.126.245   20.204.187.119   80:30890/TCP   5m6s
```

And the app reporting on itself from inside the cluster, same code, two answers:

```
$ curl -s http://20.204.187.119/api
{
    "image_flavor": "upstream",
    "hostname": "app-upstream-574978df4f-4pf9g",
    "os": "Debian GNU/Linux 13 (trixie)",
    "python": "3.13.15",
    "uid": 0,
    "running_as_root": true,
    "shell_present": true,
    "package_manager_present": true,
    "os_packages": 87
}

$ curl -s http://98.70.244.97/api
{
    "image_flavor": "chainguard",
    "hostname": "app-chainguard-6f776d7959-nprs9",
    "os": "Wolfi",
    "python": "3.14.7+",
    "uid": 65532,
    "running_as_root": false,
    "shell_present": false,
    "package_manager_present": false,
    "os_packages": 26
}
```

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

The rejection, verbatim from the API server:

```
$ kubectl -n chainguard-demo run bad --image=docker.io/library/nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: 
resource Pod/chainguard-demo/bad was blocked due to the following policies 
restrict-image-registries:
  allowed-registries: 'validation error: Images must come from cgr.dev or *.azurecr.io (trusted, signed sources). rule allowed-registries failed at path /spec/containers/0/image/'
```

The signed image goes straight through, and Kyverno checked the Rekor entry for `cgr.dev/chainguard/nginx` on the way in:

```
$ kubectl apply -f k8s/pod-chainguard-nginx.yaml
pod/nginx-signed created
$ kubectl -n chainguard-demo get pod nginx-signed
NAME           READY   STATUS    RESTARTS   AGE
nginx-signed   1/1     Running   0          8s
```

One more real-world note: the namespace also carries the Pod Security Standards labels (`enforce: baseline`, `warn: restricted`). Every `kubectl apply` for the upstream deployment prints a warning that it would violate `restricted`. The Chainguard deployment is silent. That warning line is the cheapest security audit you will ever run.

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
git clone https://github.com/sathpal/chainguard-aks-demo && cd chainguard-aks-demo
make tools && make demo     # build, scan, verify, sbom, report. No Azure required.
```

If your numbers differ from mine, that is expected. The whole point is that both images change every day, and only one of them changes in your favour.
