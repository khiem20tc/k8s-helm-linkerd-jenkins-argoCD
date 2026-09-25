#!/bin/bash
# Show status, URLs and credentials of the local lab.
source "$(dirname "$0")/lib.sh"
require_tools kubectl
guard_local_cluster

secret() {
    k -n "$1" get secret "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

case "${1:-urls}" in
    status)
        k get nodes -o wide
        echo
        k get applications -n argocd 2>/dev/null || true
        echo
        for env in $ENVIRONMENTS; do
            k get pods,svc,ingress,hpa -n "user-service-${env}" 2>/dev/null || true
        done
        ;;
    urls)
        echo -e "${GREEN}Local lab (${KUBE_CONTEXT})${NC}"
        suffix=""
        [ "$HTTP_PORT" = "80" ] || suffix=":${HTTP_PORT}"
        echo
        if k get ns argocd >/dev/null 2>&1; then
            echo "Argo CD:  http://argocd.${DOMAIN}${suffix}   admin / $(secret argocd argocd-initial-admin-secret password)"
        fi
        if k get ns jenkins >/dev/null 2>&1; then
            echo "Jenkins:  http://jenkins.${DOMAIN}${suffix}  admin / $(secret jenkins jenkins jenkins-admin-password)"
        fi
        if k get ns monitoring >/dev/null 2>&1; then
            echo "Grafana:  http://grafana.${DOMAIN}${suffix}  admin / $(secret monitoring prometheus-grafana admin-password)"
        fi
        if k get ns linkerd-viz >/dev/null 2>&1; then
            echo "Linkerd:  make linkerd-dashboard"
        fi
        for env in $ENVIRONMENTS; do
            echo "App ${env}: http://user-service-${env}.${DOMAIN}${suffix}/health"
        done
        echo
        echo "Registry: localhost:${REGISTRY_PORT} (in cluster: ${REGISTRY_NAME}:5000)"
        echo "kubectl:  export KUBECONFIG=${KUBECONFIG}"
        ;;
    *)
        die "Usage: $0 [status|urls]"
        ;;
esac
