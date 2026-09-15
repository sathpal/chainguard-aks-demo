#!/usr/bin/env bash
# Creates RG + ACR + AKS (ACR attached, workload identity ready). ~5-8 min.
. "$(dirname "$0")/common.sh"
need az
[ -n "$ACR" ] || { echo "set ACR=<globally-unique-name> (env or .env)"; exit 1; }
bold ">> subscription: $(az account show --query name -o tsv)  tenant: $(az account show --query tenantId -o tsv)"
az group create -n "$RG" -l "$LOCATION" -o none
az acr create -n "$ACR" -g "$RG" --sku Basic -o none
az aks create -n "$AKS" -g "$RG" -l "$LOCATION" \
  --node-count 2 --node-vm-size "$NODE_SIZE" \
  --attach-acr "$ACR" --enable-managed-identity --generate-ssh-keys -o none
az aks get-credentials -n "$AKS" -g "$RG" --overwrite-existing
kubectl get nodes
