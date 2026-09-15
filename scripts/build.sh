#!/usr/bin/env bash
. "$(dirname "$0")/common.sh"
cd "$ROOT"
for f in "${FLAVORS[@]}"; do
  bold ">> building $APP:$f"
  docker build -f "docker/Dockerfile.$f" -t "$APP:$f" .
done
docker images "$APP" --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
