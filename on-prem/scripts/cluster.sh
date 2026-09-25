#!/bin/bash
# Create (or delete) the local kind cluster and its image registry.
source "$(dirname "$0")/lib.sh"
require_tools kind kubectl docker

create_registry() {
    if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]; then
        log "Starting local registry ${REGISTRY_NAME} on localhost:${REGISTRY_PORT}"
        docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
        docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
            --name "$REGISTRY_NAME" registry:3 >/dev/null
    fi
}

create_cluster() {
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
        log "kind cluster ${CLUSTER_NAME} already exists"
        # Re-export in case the isolated kubeconfig was removed
        kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null
        return
    fi

    log "Creating kind cluster ${CLUSTER_NAME}"
    mkdir -p "$(dirname "$KUBECONFIG")"
    sed -e "s|__HTTP_PORT__|${HTTP_PORT}|" -e "s|__HTTPS_PORT__|${HTTPS_PORT}|" \
        "$ONPREM_DIR/kind-config.yaml" |
        kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
            --kubeconfig "$KUBECONFIG" --wait 120s --config -
}

configure_registry() {
    # Make the registry reachable from the nodes as kind-registry:5000
    if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REGISTRY_NAME")" = "null" ]; then
        docker network connect kind "$REGISTRY_NAME"
    fi

    # Nodes pull "localhost:${REGISTRY_PORT}/..." images from the registry container
    local registry_dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
    for node in $(kind get nodes --name "$CLUSTER_NAME"); do
        docker exec "$node" mkdir -p "$registry_dir"
        printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" | docker exec -i "$node" cp /dev/stdin "$registry_dir/hosts.toml"
    done

    # Document the local registry (KEP-1755)
    k apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    hostFromClusterNetwork: "${REGISTRY_NAME}:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML
}

limit_node_resources() {
    for node in $(kind get nodes --name "$CLUSTER_NAME"); do
        log "Limiting ${node} to ${KIND_NODE_CPUS} CPUs / ${KIND_NODE_MEMORY} memory"
        docker update --cpus "$KIND_NODE_CPUS" --memory "$KIND_NODE_MEMORY" --memory-swap "$KIND_NODE_MEMORY" "$node" >/dev/null
    done
}

case "${1:-create}" in
    create)
        create_registry
        create_cluster
        limit_node_resources
        guard_local_cluster
        configure_registry
        k wait --for=condition=Ready node --all --timeout=180s
        ok "Cluster ${CLUSTER_NAME} is ready (kubeconfig: ${KUBECONFIG})"
        ;;
    stop)
        # Pause the lab without losing state
        for node in $(kind get nodes --name "$CLUSTER_NAME"); do docker stop "$node" >/dev/null; done
        ok "Cluster ${CLUSTER_NAME} stopped (make start to resume)"
        ;;
    start)
        create_registry
        for node in $(kind get nodes --name "$CLUSTER_NAME"); do docker start "$node" >/dev/null; done
        limit_node_resources
        guard_local_cluster
        wait_for "the API server" 180 k get --raw /readyz
        k wait --for=condition=Ready node --all --timeout=180s
        ok "Cluster ${CLUSTER_NAME} started"
        ;;
    delete)
        log "Deleting kind cluster ${CLUSTER_NAME}"
        kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" || true
        rm -f "$KUBECONFIG"
        if [ "${2:-}" = "--registry" ]; then
            log "Removing registry ${REGISTRY_NAME}"
            docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
        fi
        ok "Cluster deleted"
        ;;
    *)
        die "Usage: $0 [create|start|stop|delete [--registry]]"
        ;;
esac
