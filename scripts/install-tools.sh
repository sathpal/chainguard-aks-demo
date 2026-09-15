#!/usr/bin/env bash
# Installs the supply-chain toolchain used by the demo (macOS / Homebrew).
set -euo pipefail
brew install trivy grype syft cosign crane
command -v kubectl >/dev/null || brew install kubectl
command -v helm    >/dev/null || brew install helm
command -v az      >/dev/null || brew install azure-cli
echo "optional: brew install chainguard-dev/tap/chainctl   # Chainguard CLI (needs a Chainguard account)"
