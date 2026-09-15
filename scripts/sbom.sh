#!/usr/bin/env bash
# Generates SBOMs for the built images (syft) and pulls the *signed* SBOM
# attestation Chainguard publishes for the base image (cosign).
. "$(dirname "$0")/common.sh"
need syft; need cosign
for f in "${FLAVORS[@]}"; do
  bold ">> syft SBOM (SPDX) for $APP:$f"
  syft "$APP:$f" -o spdx-json -q > "$OUT/$f.sbom.spdx.json"
  echo "   packages: $(jq '.packages | length' "$OUT/$f.sbom.spdx.json")  -> $OUT/$f.sbom.spdx.json"
done
bold ">> Chainguard-published SBOM attestation for cgr.dev/chainguard/python:latest"
cosign verify-attestation cgr.dev/chainguard/python:latest \
  --type https://spdx.dev/Document \
  --certificate-oidc-issuer "$CG_ISSUER" \
  --certificate-identity "$CG_IDENTITY" 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq '.predicate.packages | length' \
  | sed 's/^/   packages in index-level attested SBOM (per-arch SBOMs hang off each manifest): /'
