#!/usr/bin/env bash
# Deploys both flavors side by side to the current kube context.
. "$(dirname "$0")/common.sh"
need kubectl
REG="${ACR:+$ACR.azurecr.io/}"
kubectl apply -f "$ROOT/k8s/namespace.yaml"
for f in "${FLAVORS[@]}"; do
  sed "s#IMAGE_REF#${REG}$APP:$f#" "$ROOT/k8s/deploy-$f.yaml" | kubectl apply -f -
done
kubectl -n chainguard-demo rollout status deploy --timeout=180s
kubectl -n chainguard-demo get pods,svc -o wide
