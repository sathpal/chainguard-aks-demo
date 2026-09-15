#!/usr/bin/env bash
. "$(dirname "$0")/common.sh"
az group delete -n "$RG" --yes --no-wait && echo "deleting $RG in background"
