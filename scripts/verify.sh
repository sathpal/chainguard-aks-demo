#!/usr/bin/env bash
# Proves the base image is what Chainguard built: Sigstore keyless signature check.
. "$(dirname "$0")/common.sh"
need cosign
IMG="${1:-cgr.dev/chainguard/python:latest}"
bold ">> cosign verify $IMG (keyless, Rekor transparency log)"
cosign verify "$IMG" \
  --certificate-oidc-issuer "$CG_ISSUER" \
  --certificate-identity "$CG_IDENTITY" \
  | jq '.[0] | {subject: .critical.identity["docker-reference"], digest: .critical.image["docker-manifest-digest"], issuer: .optional.Issuer, identity: .optional.Subject}'
