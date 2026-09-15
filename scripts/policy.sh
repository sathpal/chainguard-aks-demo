#!/usr/bin/env bash
# Installs Kyverno and applies the supply-chain policies (registry allow-list +
# signature verification for cgr.dev images). Then demonstrates a rejected pod.
. "$(dirname "$0")/common.sh"
need helm; need kubectl
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
kubectl apply -f "$ROOT/k8s/policies/"
bold ">> negative test: an unsigned image from Docker Hub must be rejected"
kubectl -n chainguard-demo run bad --image=docker.io/library/nginx:latest --restart=Never 2>&1 | head -5 || true
