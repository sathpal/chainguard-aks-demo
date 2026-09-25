#!/usr/bin/env bash
# Part 3: the rest of what Chainguard ships with an image, using only free tooling and no account.
#   attestations (SBOM, SLSA provenance, apko config), daily rebuild evidence, the Wolfi
#   advisory feed, dfc automatic Dockerfile conversion, and apko custom assembly.
. "$(dirname "$0")/common.sh"
need cosign; need crane; need jq
IMG=cgr.dev/chainguard/python:latest
ISS=https://token.actions.githubusercontent.com
ID=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main

bold ">> 1. what is attached to $IMG (cosign tree)"
cosign tree "$IMG" 2>/dev/null | head -8

bold ">> 2. attestations, each verified against Chainguard's release identity"
for T in https://spdx.dev/Document https://slsa.dev/provenance/v1 https://apko.dev/image-configuration; do
  cosign verify-attestation "$IMG" --type "$T" --certificate-oidc-issuer "$ISS" --certificate-identity "$ID" >/dev/null 2>&1 \
    && echo "   verified  $T" || echo "   MISSING   $T"
done
bold "   SLSA provenance: who built it, from what"
cosign verify-attestation "$IMG" --type https://slsa.dev/provenance/v1 --certificate-oidc-issuer "$ISS" --certificate-identity "$ID" 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq -c '{builder: .predicate.runDetails.builder.id, buildType: .predicate.buildDefinition.buildType, inputs: (.predicate.buildDefinition.externalParameters | keys)}'
bold "   apko configuration: the exact package list the image was assembled from"
cosign verify-attestation "$IMG" --type https://apko.dev/image-configuration --certificate-oidc-issuer "$ISS" --certificate-identity "$ID" 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq -c '.predicate.contents.packages' | cut -c1-200

bold ">> 3. daily rebuilds: digest and build time of today's :latest (run again tomorrow and compare)"
echo "   digest : $(crane digest "$IMG")"
echo "   created: $(crane config "$IMG" | jq -r .created)"
echo "   tags without an account: $(crane ls cgr.dev/chainguard/python | grep -v '^sha256-' | tr '\n' ' ')  (version tags need the paid catalog)"

bold ">> 4. the Wolfi security feed: why the remaining CVEs remain"
for P in zlib python-3.14; do
  curl -s https://packages.wolfi.dev/os/security.json | jq -r --arg p "$P" '.packages[] | select(.pkg.name==$p) | "   \(.pkg.name): latest fixed release \(.pkg.secfixes|keys|last), \(.pkg.secfixes|[.[]]|add|length) CVEs fixed in total"'
done

if command -v dfc >/dev/null; then
  bold ">> 5. dfc: Chainguard's automatic Dockerfile converter on docker/Dockerfile.upstream"
  dfc "$ROOT/docker/Dockerfile.upstream" | grep -v '^#' | grep -v '^$'
  echo "   (ORG is your Chainguard org; version tags like :3.13-dev are catalog features. Compare with docker/Dockerfile.chainguard, which is multi-stage.)"
else echo "   dfc not installed: https://github.com/chainguard-dev/dfc/releases"; fi

if command -v apko >/dev/null; then
  bold ">> 6. apko: custom assembly. Build an image from Wolfi packages, no Dockerfile, SBOM included"
  ( cd "$OUT" && apko build "$ROOT/apko/python-custom.yaml" python-custom:apko python-custom.tar --sbom-path . 2>&1 | grep -c "installing" | sed 's/^/   packages installed: /' )
  docker load < "$OUT/python-custom.tar" >/dev/null && IMG2=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^python-custom' | head -1)
  echo "   image: $IMG2  size: $(docker images "$IMG2" --format '{{.Size}}')  sbom: $OUT/sbom-*.spdx.json"
  docker run --rm "$IMG2" -c "import os,sys; print('   python', sys.version.split()[0], 'uid', os.getuid())"
  echo "   extra package requested in the yaml: $(docker run --rm --entrypoint /usr/bin/curl "$IMG2" --version | head -1 | cut -d' ' -f1-2)"
  command -v grype >/dev/null && echo "   grype: $(grype "$IMG2" -q -o json 2>/dev/null | jq '.matches|length') known CVEs"
else echo "   apko not installed: https://github.com/chainguard-dev/apko/releases"; fi
echo
