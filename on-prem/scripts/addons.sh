#!/bin/bash
# Install platform components into the local kind cluster.
# Usage: addons.sh <ingress|metrics-server|linkerd|linkerd-viz|argocd|jenkins|monitoring|apps|all>
source "$(dirname "$0")/lib.sh"
require_tools kubectl helm
guard_local_cluster

render() {
    sed -e "s|__DOMAIN__|${DOMAIN}|g" "$1"
}

helm_repos() {
    h repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
    h repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update >/dev/null
    h repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
    h repo add jenkins https://charts.jenkins.io --force-update >/dev/null
    h repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
    h repo update >/dev/null
}

install_ingress() {
    log "Installing ingress-nginx ${INGRESS_NGINX_CHART_VERSION}"
    h upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --version "$INGRESS_NGINX_CHART_VERSION" \
        --namespace ingress-nginx --create-namespace \
        --values "$ONPREM_DIR/values/ingress-nginx.yaml" \
        --wait --timeout 5m
    ok "ingress-nginx ready on http://*.${DOMAIN}:${HTTP_PORT}"
}

install_metrics_server() {
    log "Installing metrics-server ${METRICS_SERVER_CHART_VERSION}"
    h upgrade --install metrics-server metrics-server/metrics-server \
        --version "$METRICS_SERVER_CHART_VERSION" \
        --namespace kube-system \
        --values "$ONPREM_DIR/values/metrics-server.yaml" \
        --wait --timeout 5m
    ok "metrics-server ready"
}

install_linkerd() {
    require_tools linkerd

    log "Installing Gateway API CRDs ${GATEWAY_API_VERSION} (required by Linkerd)"
    k apply --server-side -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    log "Installing Linkerd ${LINKERD_VERSION}"
    l check --pre
    l install --crds | k apply --server-side -f -
    l install | k apply --server-side -f -
    l check --wait 5m
    ok "Linkerd ready"
}

install_linkerd_viz() {
    require_tools linkerd
    log "Installing Linkerd viz extension"
    l viz install | k apply --server-side -f -
    l viz check --wait 5m
    ok "Linkerd viz ready (make linkerd-dashboard)"
}

install_argocd() {
    log "Installing Argo CD (chart ${ARGOCD_CHART_VERSION})"
    render "$ONPREM_DIR/values/argocd.yaml" |
        h upgrade --install argocd argo/argo-cd \
            --version "$ARGOCD_CHART_VERSION" \
            --namespace argocd --create-namespace \
            --values - \
            --wait --timeout 10m
    ok "Argo CD ready on http://argocd.${DOMAIN}:${HTTP_PORT}"
}

# Generate an API token for the "jenkins" Argo CD account through the Argo CD REST API.
argocd_jenkins_token() {
    local password local_port=18089 pf_pid token session

    password=$(k -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

    k -n argocd port-forward svc/argocd-server "${local_port}:80" >/dev/null 2>&1 &
    pf_pid=$!
    # shellcheck disable=SC2064
    trap "kill $pf_pid 2>/dev/null || true" RETURN
    wait_for "Argo CD API port-forward" 60 curl -sf "http://127.0.0.1:${local_port}/healthz"

    session=$(curl -sf "http://127.0.0.1:${local_port}/api/v1/session" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"${password}\"}" |
        sed -E 's/.*"token":"([^"]+)".*/\1/')
    [ -n "$session" ] || die "Could not log in to Argo CD"

    token=$(curl -sf -X POST "http://127.0.0.1:${local_port}/api/v1/account/jenkins/token" \
        -H "Authorization: Bearer ${session}" \
        -H 'Content-Type: application/json' \
        -d '{"name":"jenkins"}' |
        sed -E 's/.*"token":"([^"]+)".*/\1/')
    [ -n "$token" ] || die "Could not create the Argo CD token for account 'jenkins'"

    echo "$token"
}

install_jenkins() {
    log "Preparing Jenkins secrets and settings"
    k create namespace jenkins --dry-run=client -o yaml | k apply -f -

    local argocd_token=""
    if k get namespace argocd >/dev/null 2>&1; then
        argocd_token=$(argocd_jenkins_token)
    else
        warn "Argo CD is not installed; the pipeline's 'Wait for ArgoCD Sync' stage will fail"
    fi
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        warn "GITHUB_USERNAME/GITHUB_TOKEN not set in on-prem/.env; the pipeline cannot push GitOps commits"
    fi

    k -n jenkins create secret generic jenkins-local-credentials \
        --from-literal=github-username="${GITHUB_USERNAME:-}" \
        --from-literal=github-token="${GITHUB_TOKEN:-}" \
        --from-literal=argocd-token="${argocd_token}" \
        --dry-run=client -o yaml | k apply -f -

    k -n jenkins create configmap jenkins-local-settings \
        --from-literal=git-repo-url="$GIT_REPO_URL" \
        --from-literal=git-revision="$GIT_REVISION" \
        --dry-run=client -o yaml | k apply -f -

    # kaniko mounts this secret; the local registry needs no credentials
    k -n jenkins create secret docker-registry registry-credentials \
        --docker-server="${REGISTRY_NAME}:5000" --docker-username=unused --docker-password=unused \
        --dry-run=client -o yaml | k apply -f -

    log "Installing Jenkins (chart ${JENKINS_CHART_VERSION})"
    render "$ONPREM_DIR/values/jenkins.yaml" |
        h upgrade --install jenkins jenkins/jenkins \
            --version "$JENKINS_CHART_VERSION" \
            --namespace jenkins \
            --values "$REPO_ROOT/jenkins/values.yaml" \
            --values - \
            --timeout 15m
    k -n jenkins rollout status statefulset/jenkins --timeout=15m
    ok "Jenkins ready on http://jenkins.${DOMAIN}:${HTTP_PORT}"
}

install_monitoring() {
    log "Installing kube-prometheus-stack ${KUBE_PROMETHEUS_CHART_VERSION}"
    h upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --version "$KUBE_PROMETHEUS_CHART_VERSION" \
        --namespace monitoring --create-namespace \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set alertmanager.enabled=false \
        --set grafana.ingress.enabled=true \
        --set grafana.ingress.ingressClassName=nginx \
        --set "grafana.ingress.hosts[0]=grafana.${DOMAIN}" \
        --wait --timeout 10m
    ok "Monitoring ready on http://grafana.${DOMAIN}:${HTTP_PORT}"
}

install_apps() {
    k get crd applications.argoproj.io >/dev/null 2>&1 || die "Argo CD is not installed. Run 'make argocd' first."

    for env in $ENVIRONMENTS; do
        log "Applying Argo CD application user-service-${env} (${GIT_REPO_URL}@${GIT_REVISION})"
        sed -e "s|__ENV__|${env}|g" \
            -e "s|__GIT_REPO_URL__|${GIT_REPO_URL}|g" \
            -e "s|__GIT_REVISION__|${GIT_REVISION}|g" \
            -e "s|__REGISTRY_PORT__|${REGISTRY_PORT}|g" \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            "$ONPREM_DIR/argocd/application.yaml.tpl" | k apply -f -
    done
    ok "Applications created. Watch them with: make status"
}

component=${1:-all}
case "$component" in
    repos)          helm_repos ;;
    ingress)        helm_repos; install_ingress ;;
    metrics-server) helm_repos; install_metrics_server ;;
    linkerd)        install_linkerd ;;
    linkerd-viz)    install_linkerd_viz ;;
    argocd)         helm_repos; install_argocd ;;
    jenkins)        helm_repos; install_jenkins ;;
    monitoring)     helm_repos; install_monitoring ;;
    apps)           install_apps ;;
    all)
        helm_repos
        install_ingress
        install_metrics_server
        install_linkerd
        if enabled "$ENABLE_LINKERD_VIZ"; then install_linkerd_viz; fi
        install_argocd
        if enabled "$ENABLE_JENKINS"; then install_jenkins; fi
        if enabled "$ENABLE_MONITORING"; then install_monitoring; fi
        install_apps
        ;;
    *)
        die "Unknown component: $component"
        ;;
esac
