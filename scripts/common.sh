# shellcheck shell=bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"; mkdir -p "$OUT"
APP="${APP:-demo-app}"
FLAVORS=(upstream chainguard)
# Public Chainguard signing identity (keyless, Sigstore) for cgr.dev/chainguard/*
CG_ISSUER="https://token.actions.githubusercontent.com"
CG_IDENTITY="https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main"
# Optional Azure settings (override via env or .env)
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a
RG="${RG:-rg-chainguard-demo}"
LOCATION="${LOCATION:-centralindia}"
ACR="${ACR:-}"            # e.g. cgdemoacr (must be globally unique, lowercase)
AKS="${AKS:-aks-chainguard-demo}"
NODE_SIZE="${NODE_SIZE:-Standard_D2s_v4}"   # pick a family with vCPU quota: az vm list-usage -l $LOCATION -o table
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1 (run: make tools)" >&2; exit 1; }; }
