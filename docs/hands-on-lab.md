# Chainguard hands-on lab: every command, what it prints, what it proves

This is the demo with the Makefile taken away. Each step is one or two commands you
type yourself, the output you should see, and the sentence that explains it. Run it
top to bottom once and you will be able to tell the whole story from memory.

Numbers here are from a run on 25 September 2026. Yours will differ, because both
images are rebuilt all the time. The gap between them is what stays the same.

Work from the repo root:

```bash
git clone https://github.com/sathpal/chainguard-aks-demo && cd chainguard-aks-demo
mkdir -p out
```

---

## 0. Tools

```bash
brew install trivy grype syft cosign crane jq
docker info >/dev/null && echo "docker ok"
```

Three Chainguard-specific tools for the later chapters. Homebrew has them
(`brew install chainguard-dev/tap/chainctl chainguard-dev/tap/dfc apko`); if brew
complains about your command line tools, download the release binaries instead:

```bash
curl -sSfL -o /opt/homebrew/bin/chainctl https://dl.enforce.dev/chainctl/latest/chainctl_darwin_arm64 && chmod +x /opt/homebrew/bin/chainctl
# dfc and apko: pick the darwin_arm64 tarball from the releases page, untar, copy the binary to /opt/homebrew/bin
open https://github.com/chainguard-dev/dfc/releases   https://github.com/chainguard-dev/apko/releases
```

Check:

```bash
grype version | head -1; syft version | head -1; cosign version 2>&1 | grep -i gitversion; crane version; dfc version | head -1; apko version | grep GitVersion; chainctl version | grep GitVersion
```

---

## 1. Two Dockerfiles, same app

```bash
cat app/main.py | head -30
cat docker/Dockerfile.upstream
cat docker/Dockerfile.chainguard
```

**What to notice.** The upstream file is what every tutorial shows: one stage,
`python:3.13-slim`, `pip install` in the image that ships. The Chainguard file has two
stages: dependencies are installed in `cgr.dev/chainguard/python:latest-dev`, which has
pip and a shell, then copied into `cgr.dev/chainguard/python:latest`, which has neither.
Two details that only matter in the cloud: the build stage works in `/home/nonroot`
(ACR's legacy builder creates other directories as root), and the final `USER 65532` is
numeric (Kubernetes cannot verify `runAsNonRoot` against a name).

**Say:** "Same forty lines of Python. The only thing that changes is the base image and
the shape of the Dockerfile."

---

## 2. Build both

```bash
docker build -f docker/Dockerfile.upstream   -t demo-app:upstream .
docker build -f docker/Dockerfile.chainguard -t demo-app:chainguard .
docker images demo-app --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
```

Expected:

```
REPOSITORY:TAG         SIZE
demo-app:chainguard    140MB
demo-app:upstream      248MB
```

**Say:** "Smaller is a side effect. The point is what is not inside."

---

## 3. Look inside

```bash
# upstream: root, apt, a full userland
docker run --rm demo-app:upstream sh -c 'id; which apt-get; ls /bin | wc -l; dpkg -l | grep -c "^ii"'
```

Expected:

```
uid=0(root) gid=0(root) groups=0(root)
/usr/bin/apt-get
259
87
```

```bash
# chainguard: try to get a shell
docker run --rm --entrypoint sh demo-app:chainguard -c id
```

Expected (this failure is the feature):

```
docker: Error response from daemon: ... exec: "sh": executable file not found in $PATH
```

```bash
# chainguard: ask python instead, since python is the only thing there
docker run --rm demo-app:chainguard -c 'import os; print("uid", os.getuid()); print("sh:", os.path.exists("/bin/sh")); print("apk:", os.path.exists("/sbin/apk"))'
```

Expected:

```
uid 65532
sh: False
apk: False
```

**Say:** "If an attacker gets code execution in the upstream container they are root
with a package manager and 259 binaries. In the Chainguard container they have Python
and nothing else. There is no shell to run."

---

## 4. Scan

```bash
grype demo-app:upstream   -o table -q > out/upstream.grype.txt;   tail -5 out/upstream.grype.txt
grype demo-app:chainguard -o table -q > out/chainguard.grype.txt; cat out/chainguard.grype.txt
```

Expected, Chainguard side, the whole table:

```
NAME         INSTALLED              FIXED IN  TYPE  VULNERABILITY        SEVERITY  EPSS         RISK
zlib         1.3.2-r7               1.3.3-r0  apk   CVE-2026-85091       High      0.4% (37th)  0.3
python-3.14  3.14.7_git20260914-r3            apk   CVE-2026-19672       Medium    0.4% (34th)  0.2
python-3.14  3.14.7_git20260914-r3            apk   CVE-2025-15367       Medium    0.3% (26th)  0.2
python-3.14  3.14.7_git20260914-r3            apk   CVE-2026-15310       Low       0.3% (26th)  < 0.1
zlib         1.3.2-r7               1.3.3-r0  apk   GHSA-g5fp-32jq-cfw2  Unknown   N/A          N/A
```

Now the counts by severity, both images:

```bash
for f in upstream chainguard; do
  grype demo-app:$f -o json -q > out/$f.grype.json
  echo "$f: $(jq '.matches|length' out/$f.grype.json) total, $(jq '[.matches[]|select(.vulnerability.severity=="Critical")]|length' out/$f.grype.json) critical, $(jq '[.matches[]|select(.vulnerability.severity=="High")]|length' out/$f.grype.json) high"
done
```

Expected:

```
upstream: 178 total, 7 critical, 61 high
chainguard: 5 total, 0 critical, 1 high
```

Where do the upstream ones come from?

```bash
jq -r '.matches[].artifact.type' out/upstream.grype.json | sort | uniq -c
jq -r '.matches[].artifact.name' out/upstream.grype.json | sort | uniq -c | sort -rn | head -8
```

Expected: nearly all of type `deb`, concentrated in glibc, openssl, perl, systemd
libraries. None in `app/main.py`.

**Say:** "178 versus 5. Not one of the 178 is in code we wrote. They are all in the
Debian layer we did not choose and cannot patch faster than Debian does. Zero critical on
the other side."

---

## 5. Why five remain, and how you know they will go

The `FIXED IN` column says zlib has a fix at 1.3.3-r0. The Wolfi security feed is the
data grype used to say so:

```bash
curl -s https://packages.wolfi.dev/os/security.json | jq -r '.packages[] | select(.pkg.name=="zlib") | "zlib: latest fixed release \(.pkg.secfixes|keys|last), \(.pkg.secfixes|[.[]]|add|length) CVEs fixed so far"'
curl -s https://packages.wolfi.dev/os/security.json | jq -r '.packages[] | select(.pkg.name=="python-3.14") | "python-3.14: latest fixed release \(.pkg.secfixes|keys|last), \(.pkg.secfixes|[.[]]|add|length) CVEs fixed so far"'
```

Expected:

```
zlib: latest fixed release 1.3.2.1_rc20260601-r0, 12 CVEs fixed so far
python-3.14: latest fixed release 3.14.7_git20260912-r0, 76 CVEs fixed so far
```

**Say:** "The remaining five are two packages, one with a fix already queued and one
waiting on upstream Python. Rebuild tomorrow and the number moves. That is what
'rebuilt daily from source' means in practice."

---

## 6. The base image cannot fix your requirements.txt

Optional, five minutes, and the most honest part of the story. Pin an old framework
and watch the Chainguard count go up:

```bash
cp app/requirements.txt /tmp/req.bak
printf 'fastapi==0.110.0\nuvicorn>=0.38\n' > app/requirements.txt
docker build -q -f docker/Dockerfile.chainguard -t demo-app:oldpin . && grype demo-app:oldpin -o table -q | grep -c python-pkg
cp /tmp/req.bak app/requirements.txt
```

Expected: several extra findings of type `python-pkg`, mostly in `starlette`, on top of
the OS ones. My first ever scan showed 12, and 7 of them were this.

**Say:** "Seven of my first twelve findings were my own outdated FastAPI pin. A secure
base does not fix application dependencies. That is what Chainguard Libraries is for."

---

## 7. Prove the base image is really Chainguard's

```bash
cosign verify cgr.dev/chainguard/python:latest \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main \
  | jq '.[0] | {subject: .critical.identity["docker-reference"], digest: .critical.image["docker-manifest-digest"], issuer: .optional.Issuer, identity: .optional.Subject}'
```

Expected:

```json
{
  "subject": "cgr.dev/chainguard/python",
  "digest": "sha256:992f13b3...",
  "issuer": "https://token.actions.githubusercontent.com",
  "identity": "https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main"
}
```

Now prove the check is real by making it fail. Wrong identity:

```bash
cosign verify cgr.dev/chainguard/python:latest \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/someone-else/images/.github/workflows/release.yaml@refs/heads/main 2>&1 | head -1
```

Expected:

```
Error: no matching signatures: none of the expected identities matched what was in the certificate, got subjects [https://github.com/chainguard-images/images/...]
```

And the upstream image, which has no signature at all:

```bash
cosign verify docker.io/library/python:3.13-slim --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp '.*' 2>&1 | head -1
```

Expected:

```
Error: no signatures found
```

**Say:** "Keyless signing. No key to manage, no vendor account. The signature is in the
public Rekor transparency log and it names the exact GitHub workflow that built the
image. This is the difference between 'we pulled something called python' and 'we
pulled what Chainguard's release pipeline built'."

---

## 8. What else is attached to the image

```bash
cosign tree cgr.dev/chainguard/python:latest
```

Expected: one signature and three attestations. Verify each by type:

```bash
ISS=https://token.actions.githubusercontent.com
ID=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
for T in https://spdx.dev/Document https://slsa.dev/provenance/v1 https://apko.dev/image-configuration; do
  cosign verify-attestation cgr.dev/chainguard/python:latest --type $T --certificate-oidc-issuer $ISS --certificate-identity $ID >/dev/null 2>&1 && echo "verified $T" || echo "MISSING  $T"
done
```

Expected:

```
verified https://spdx.dev/Document
verified https://slsa.dev/provenance/v1
verified https://apko.dev/image-configuration
```

Read two of them:

```bash
# who built it and how
cosign verify-attestation cgr.dev/chainguard/python:latest --type https://slsa.dev/provenance/v1 --certificate-oidc-issuer $ISS --certificate-identity $ID 2>/dev/null \
  | jq -r .payload | base64 -d | jq '{builder: .predicate.runDetails.builder.id, buildType: .predicate.buildDefinition.buildType}'

# the exact package list the image was assembled from
cosign verify-attestation cgr.dev/chainguard/python:latest --type https://apko.dev/image-configuration --certificate-oidc-issuer $ISS --certificate-identity $ID 2>/dev/null \
  | jq -r .payload | base64 -d | jq -r '.predicate.contents.packages[]' | head -12
```

Expected:

```
{ "builder": "https://github.com/chainguard-dev/terraform-provider-apko", "buildType": "https://apko.dev/slsa-build-type@v1" }
ca-certificates-bundle=20260909-r1
gdbm=1.26-r6
glibc-2.44=2.44-r6
...
```

**Say:** "Signature, SBOM, SLSA provenance and the build recipe, all signed by the same
identity. When compliance asks how we know what is in production, this is the answer,
and it came free with the pull."

---

## 9. SBOMs, yours and theirs

```bash
syft demo-app:upstream   -o spdx-json -q > out/upstream.sbom.spdx.json
syft demo-app:chainguard -o spdx-json -q > out/chainguard.sbom.spdx.json
for f in upstream chainguard; do echo "$f: $(jq '.packages|length' out/$f.sbom.spdx.json) packages"; done
```

Expected:

```
upstream: 109 packages
chainguard: 47 packages
```

The SBOM Chainguard already published for the base image, verified:

```bash
cosign verify-attestation cgr.dev/chainguard/python:latest --type https://spdx.dev/Document --certificate-oidc-issuer $ISS --certificate-identity $ID 2>/dev/null \
  | jq -r .payload | base64 -d | jq '.predicate.packages | length'
```

**Say:** "When the next big CVE lands, 47 packages to check instead of 109, and the base
image's own list is already signed and published."

---

## 10. Daily rebuilds, with evidence

```bash
crane digest cgr.dev/chainguard/python:latest
crane config cgr.dev/chainguard/python:latest | jq -r .created
crane ls cgr.dev/chainguard/python | grep -v '^sha256-'
```

Expected today:

```
sha256:f23c2b7c...
2026-09-24T03:05:08Z
latest
latest-dev
```

Run the first two lines again tomorrow. Both change. Only `latest` and `latest-dev`
exist without an account; version tags like `python:3.13` are a catalog feature.

**Say:** "The image you pulled this morning was built last night. Version pinning is
where the paid catalog starts, and that is a fair conversation to have with a customer."

---

## 11. Wolfi, the OS underneath

```bash
docker run --rm cgr.dev/chainguard/wolfi-base cat /etc/os-release | head -3
docker run --rm cgr.dev/chainguard/wolfi-base sh -c 'apk list --installed 2>/dev/null | wc -l; id'
docker run --rm --entrypoint sh cgr.dev/chainguard/python:latest-dev -c 'id; which apk pip sh; apk list --installed 2>/dev/null | wc -l'
```

Expected:

```
NAME="Wolfi"
...
21
uid=0(root) ...                           # wolfi-base is a build base, it is root and has apk
uid=65532(nonroot) ...
/usr/bin/apk
/usr/bin/pip
/usr/bin/sh
78                                        # the -dev tag: nonroot, but with the tools to build
```

**Say:** "Wolfi is Chainguard's own package set, glibc based, so Debian-built Python
wheels work. The `-dev` tag has apk, pip and a shell for building; the plain tag has
none of them for running. `wolfi-base` is what you start from if you need to build
something yourself."

---

## 12. dfc: Chainguard's own Dockerfile converter

```bash
dfc docker/Dockerfile.upstream
```

Expected:

```dockerfile
FROM cgr.dev/ORG/python:3.13-dev
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/main.py .
...
```

**Say:** "dfc gets you to a Chainguard base in one command. Notice it produced a
single-stage `-dev` image with a version tag under your org, which is the catalog
path. My hand-written version is multi-stage on the free tag. Both are valid; they are
different starting points."

---

## 13. apko: build an image from packages, no Dockerfile

```bash
cat apko/python-custom.yaml
apko build apko/python-custom.yaml python-custom:apko out/python-custom.tar --sbom-path out/
docker load < out/python-custom.tar
docker run --rm python-custom:apko-arm64 -c 'import os,sys; print("python", sys.version.split()[0], "uid", os.getuid())'
docker run --rm --entrypoint /usr/bin/curl python-custom:apko-arm64 --version | head -1
grype python-custom:apko-arm64 -o table -q | tail -4
ls out/sbom-*.spdx.json
```

Expected:

```
... INFO installing python-3.13 (3.13.15_...)   # about 48 packages, under ten seconds
Loaded image: python-custom:apko-arm64
python 3.13.15 uid 65532
curl 8.22.0-DEV ...
<a handful of findings, no critical>
out/sbom-aarch64.spdx.json  out/sbom-index.spdx.json
```

**Say:** "This is the tool Chainguard builds its own images with. A YAML list of
packages becomes an OCI image with an SBOM beside it, in seconds, reproducibly. Custom
assembly in the paid catalog is this, done for you, with the CVE SLA attached."

---

## 14. chainctl and the account model

```bash
chainctl auth login                       # browser, once
chainctl auth status | head -6
chainctl iam organizations list -o table
chainctl images repos list --parent chainguard
```

Expected on a free account:

```
Valid | True ... Audience | console-api.enforce.dev, cgr.dev, apk.cgr.dev, libraries.cgr.dev, ...
<your organization>   ready
Error: No folder found for "chainguard"
```

**Say:** "I went as far as the free tier goes. The account model is per-organization
entitlement: `chainctl images history` and `images diff` work on images assigned to your
org at `cgr.dev/<org>`. For the public free images, the evidence lives in the
attestations, which is what the earlier chapters used. The token audiences also show
the product surface: images, apk packages, Libraries."

---

## 15. Run both, side by side

```bash
docker run -d --rm --name demo-upstream   -p 8081:8080 demo-app:upstream
docker run -d --rm --name demo-chainguard -p 8082:8080 demo-app:chainguard
curl -s localhost:8081/api | jq
curl -s localhost:8082/api | jq
```

Expected, the two answers:

```
"os": "Debian GNU/Linux 13 (trixie)", "uid": 0,     "running_as_root": true,  "shell_present": true,  "package_manager_present": true,  "os_packages": 87
"os": "Wolfi",                        "uid": 65532, "running_as_root": false, "shell_present": false, "package_manager_present": false, "os_packages": 26
```

Open http://localhost:8081 and http://localhost:8082 for the page version. Then:

```bash
docker rm -f demo-upstream demo-chainguard
```

---

## 16. AKS

This part costs about a dollar an hour. Names first:

```bash
export RG=rg-chainguard-demo LOCATION=centralindia AKS=aks-chainguard-demo ACR=<globally-unique-lowercase-name> NODE_SIZE=Standard_D2s_v4
az login
az account show --query '{subscription:name,id:id}' -o table         # confirm before creating anything
az vm list-usage -l $LOCATION -o table | grep -i "standardDSv4\|standardDv4"   # quota for the node size
```

Create:

```bash
az group create -n $RG -l $LOCATION -o none
az acr create -n $ACR -g $RG --sku Basic -o none
az aks create -n $AKS -g $RG -l $LOCATION --node-count 2 --node-vm-size $NODE_SIZE --attach-acr $ACR --enable-managed-identity --generate-ssh-keys -o none
az aks get-credentials -n $AKS -g $RG --overwrite-existing
kubectl get nodes
```

Expected: two nodes Ready in about six minutes.

Build in the cloud (no local cross-compile; this is where the WORKDIR lesson came from):

```bash
az acr build -r $ACR -f docker/Dockerfile.upstream   -t demo-app:upstream   --platform linux/amd64 .
az acr build -r $ACR -f docker/Dockerfile.chainguard -t demo-app:chainguard --platform linux/amd64 .
az acr repository show-tags -n $ACR --repository demo-app -o table
```

Deploy:

```bash
kubectl apply -f k8s/namespace.yaml
sed "s#IMAGE_REF#$ACR.azurecr.io/demo-app:upstream#"   k8s/deploy-upstream.yaml   | kubectl apply -f -
sed "s#IMAGE_REF#$ACR.azurecr.io/demo-app:chainguard#" k8s/deploy-chainguard.yaml | kubectl apply -f -
kubectl -n chainguard-demo rollout status deploy --timeout=180s
kubectl -n chainguard-demo get pods,svc -o wide
```

**Watch for** the warning printed when the upstream deployment is applied:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ... runAsNonRoot != true ...
```

The namespace enforces the `baseline` Pod Security Standard and warns on `restricted`.
The upstream image trips the warning. The Chainguard one is silent.

Call both through their public IPs:

```bash
UP=$(kubectl -n chainguard-demo get svc app-upstream   -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
CG=$(kubectl -n chainguard-demo get svc app-chainguard -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://$UP/api | jq -c '{os,uid,shell_present,os_packages}'
curl -s http://$CG/api | jq -c '{os,uid,shell_present,os_packages}'
```

The hardening block the Chainguard deployment carries, which the upstream one cannot:

```bash
grep -A8 "securityContext:" k8s/deploy-chainguard.yaml
```

**Say:** "runAsNonRoot, read-only root filesystem, drop all capabilities, seccomp
RuntimeDefault. Try the same block on the upstream image and the pod never starts,
because the image is root. And the numeric runAsUser is there because my first rollout
sat in CreateContainerConfigError: the kubelet cannot verify non-root from a user name."

Debugging without a shell:

```bash
kubectl -n chainguard-demo exec deploy/app-chainguard -- sh         # fails: no sh
kubectl -n chainguard-demo debug -it deploy/app-chainguard --image=cgr.dev/chainguard/wolfi-base --target=app -- sh
```

**Say:** "kubectl exec is gone. kubectl debug with an ephemeral container is the new
runbook. That is a real operational change and worth saying out loud to a customer."

---

## 17. Kyverno: from scanning to enforcing

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
cat k8s/policies/restrict-registries.yaml
cat k8s/policies/verify-chainguard-signatures.yaml
kubectl apply -f k8s/policies/
kubectl get clusterpolicy
```

Reject an unsigned image from Docker Hub:

```bash
kubectl -n chainguard-demo run bad --image=docker.io/library/nginx:latest --restart=Never
```

Expected:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource Pod/chainguard-demo/bad was blocked due to the following policies
restrict-image-registries:
  allowed-registries: 'validation error: Images must come from cgr.dev or *.azurecr.io (trusted, signed sources). ...'
```

Admit a signed Chainguard image, with Kyverno checking the Rekor entry on the way in:

```bash
kubectl apply -f k8s/pod-chainguard-nginx.yaml
kubectl -n chainguard-demo wait pod/nginx-signed --for=condition=Ready --timeout=120s
kubectl -n chainguard-demo get pod nginx-signed
```

Expected: `nginx-signed   1/1   Running`.

**Say:** "Scanning tells you. Admission control stops you. Two policies: only trusted
registries, and every cgr.dev image must carry Chainguard's keyless signature. The
rejection happened at the API server, before a pod ever existed."

---

## 18. Tear down

```bash
az group delete -n $RG --yes --no-wait
kubectl config delete-context $AKS
```

---

## The story in ten lines

1. Same app, two base images.
2. 178 known CVEs versus 5, zero critical on the Chainguard side, none of them in our code.
3. Upstream: root, apt, 259 binaries. Chainguard: uid 65532, no shell, no package manager.
4. The five that remain are two packages with fixes on the way; the image is rebuilt daily and the number moves.
5. Seven of my first twelve findings were my own FastAPI pin. The base image does not fix requirements.txt. Libraries exists for that.
6. Every image is keyless-signed and carries an SBOM, SLSA provenance and its build recipe. Wrong identity fails, Docker Hub has no signature at all.
7. dfc converts a Dockerfile in one command; apko builds an image from a package list in ten seconds. Custom assembly is apko with an SLA.
8. On AKS the Chainguard pod passes the restricted Pod Security profile; the upstream pod cannot. Two Azure-only gotchas, both documented.
9. Kyverno rejected an unsigned Docker Hub image at the API server and admitted a signed Chainguard one.
10. No shell means kubectl debug, not kubectl exec. Say it before the customer finds out.
