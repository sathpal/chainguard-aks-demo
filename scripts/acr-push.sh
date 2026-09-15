#!/usr/bin/env bash
# Pushes both images to ACR. Images are built for the AKS node arch (amd64).
. "$(dirname "$0")/common.sh"
need az
[ -n "$ACR" ] || { echo "set ACR=<name>"; exit 1; }
az acr login -n "$ACR"
cd "$ROOT"
for f in "${FLAVORS[@]}"; do
  bold ">> build+push $ACR.azurecr.io/$APP:$f (linux/amd64)"
  docker buildx build --platform linux/amd64 -f "docker/Dockerfile.$f" -t "$ACR.azurecr.io/$APP:$f" --push .
done
az acr repository show-tags -n "$ACR" --repository "$APP" -o table
