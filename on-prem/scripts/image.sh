#!/bin/bash
# Build the user-service image and push it to the local registry.
# Usage: image.sh [TAG]   (default: latest, which is what values-<env>.yaml start with)
source "$(dirname "$0")/lib.sh"
require_tools docker

tag=${1:-latest}
image="localhost:${REGISTRY_PORT}/user-service:${tag}"

log "Building ${image}"
docker build -t "$image" "$REPO_ROOT/app"

log "Pushing ${image}"
docker push "$image"
ok "Pushed ${image}"
