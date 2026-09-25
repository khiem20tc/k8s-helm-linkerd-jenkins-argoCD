#!/bin/bash

# Deployment Script
# Manually builds and deploys the user service with Helm. Intended for local
# clusters. Environments managed by ArgoCD should be deployed through Git
# (see jenkins/Jenkinsfile); this script refuses to touch them unless --force.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOCKER_REGISTRY=${DOCKER_REGISTRY:-"your-registry.com"}
IMAGE_NAME="user-service"
HELM_CHART_PATH="k8s/helm/user-service"
NAMESPACE_PREFIX="user-service"

# Always run from the repository root
cd "$(dirname "$0")/.."

# SAFETY: this is a test repo. Always use the local kind cluster from on-prem/
# (never the default ~/.kube/config) and refuse to talk to a non-local API server.
export KUBECONFIG="$PWD/on-prem/.kube/config"
guard_local_cluster() {
    [ -f "$KUBECONFIG" ] || { echo -e "${RED}❌ $KUBECONFIG not found. Run 'make -C on-prem up' first.${NC}"; exit 1; }
    local server
    server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    case "$server" in
        https://127.0.0.1:*|https://localhost:*) ;;
        *) echo -e "${RED}❌ Refusing to use non-local cluster: ${server}${NC}"; exit 1 ;;
    esac
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] ENVIRONMENT"
    echo ""
    echo "Environments:"
    echo "  dev       Deploy to development environment"
    echo "  staging   Deploy to staging environment"
    echo "  prod      Deploy to production environment"
    echo ""
    echo "Options:"
    echo "  -v, --version VERSION    Specify image version (default: latest)"
    echo "  -r, --replicas COUNT     Number of replicas (default: from values-<env>.yaml)"
    echo "  -s, --skip-build         Deploy an existing image without building it"
    echo "  -d, --dry-run            Show what would be deployed without applying"
    echo "  -f, --force              Deploy even if the environment is managed by ArgoCD"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dev"
    echo "  $0 prod -v v1.2.3"
    echo "  $0 staging -r 5"
    echo "  $0 dev --dry-run"
}

# Function to check prerequisites
check_prerequisites() {
    local missing_tools=()

    for tool in kubectl helm docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        exit 1
    fi
}

# Function to refuse deploying over an ArgoCD-managed environment
check_argocd_ownership() {
    local environment=$1

    if kubectl get application "${IMAGE_NAME}-${environment}" -n argocd >/dev/null 2>&1; then
        echo -e "${RED}❌ ${IMAGE_NAME}-${environment} is managed by ArgoCD.${NC}"
        echo "   A manual Helm release would be reverted by ArgoCD self-heal."
        echo "   Deploy by updating k8s/helm/user-service/values-${environment}.yaml in Git,"
        echo "   or pass --force to deploy anyway."
        exit 1
    fi
}

# Function to build Docker image
build_image() {
    local image_tag=$1

    echo -e "${BLUE}🐳 Building Docker image: ${image_tag}${NC}"
    docker build -t "${image_tag}" app

    # Push image if registry is configured
    if [ "$DOCKER_REGISTRY" != "your-registry.com" ]; then
        echo "Pushing image to registry..."
        docker push "${image_tag}"
    else
        echo -e "${YELLOW}⚠️  Skipping push - please configure DOCKER_REGISTRY${NC}"
    fi
}

# Function to deploy with Helm
deploy_with_helm() {
    local environment=$1
    local version=$2
    local replicas=$3
    local dry_run=$4

    local namespace="${NAMESPACE_PREFIX}-${environment}"
    local release_name="${IMAGE_NAME}-${environment}"

    echo -e "${BLUE}🚀 Deploying to ${environment} environment${NC}"
    echo "Namespace: ${namespace}"
    echo "Release: ${release_name}"
    echo "Version: ${version}"
    echo "Replicas: ${replicas:-default}"

    local helm_args=(
        upgrade --install "${release_name}" "${HELM_CHART_PATH}"
        --namespace "${namespace}"
        --values "${HELM_CHART_PATH}/values.yaml"
        --values "${HELM_CHART_PATH}/values-${environment}.yaml"
        --set "image.repository=${DOCKER_REGISTRY}/${IMAGE_NAME}"
        --set-string "image.tag=${version}"
    )

    if [ -n "$replicas" ]; then
        # A fixed replica count only makes sense without the HPA
        helm_args+=(--set "replicaCount=${replicas}" --set "autoscaling.enabled=false")
    fi

    if [ "$dry_run" = "true" ]; then
        helm_args+=(--dry-run --debug)
        echo -e "${YELLOW}🔍 Dry run mode - showing what would be deployed${NC}"
    else
        # Create namespace with Linkerd injection enabled
        kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
        kubectl label namespace "${namespace}" linkerd.io/inject=enabled --overwrite
        helm_args+=(--wait --timeout=300s)
    fi

    echo "Running: helm ${helm_args[*]}"
    helm "${helm_args[@]}"

    if [ "$dry_run" != "true" ]; then
        echo -e "${GREEN}✅ Deployment completed successfully${NC}"

        # Show deployment status
        echo -e "${BLUE}📊 Deployment Status:${NC}"
        kubectl get pods -n "${namespace}" -l "app.kubernetes.io/instance=${release_name}"
        kubectl get svc -n "${namespace}" -l "app.kubernetes.io/instance=${release_name}"

        # Show access information
        echo -e "${BLUE}🌐 Access Information:${NC}"
        local service_url="http://user-service-${environment}.local"
        echo "Service URL: ${service_url}"
        echo "Health Check: ${service_url}/health"
        echo "Metrics: ${service_url}/metrics"

        # Port forward for local testing
        echo -e "${BLUE}🔗 Port Forward (for local testing):${NC}"
        echo "kubectl port-forward svc/${release_name} 8080:80 -n ${namespace}"
        echo "Then access: http://localhost:8080/health"
    fi
}

# Function to run health checks
run_health_checks() {
    local environment=$1
    local namespace="${NAMESPACE_PREFIX}-${environment}"
    local release_name="${IMAGE_NAME}-${environment}"

    echo -e "${BLUE}🏥 Running health checks...${NC}"

    # Wait for pods to be ready
    echo "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l "app.kubernetes.io/instance=${release_name}" -n "${namespace}" --timeout=300s

    echo "Testing health endpoint..."
    if kubectl run "smoke-test-$(date +%s)" -n "${namespace}" --image=curlimages/curl --rm -i --restart=Never \
        --annotations="linkerd.io/inject=disabled" -- \
        curl -fsS --retry 5 --retry-delay 2 "http://${release_name}/health"; then
        echo
        echo -e "${GREEN}✅ Health checks passed${NC}"
    else
        echo -e "${RED}❌ Health check failed${NC}"
        return 1
    fi
}

# Main function
main() {
    local environment=""
    local version="latest"
    local replicas=""
    local dry_run="false"
    local skip_build="false"
    local force="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                version="$2"
                shift 2
                ;;
            -r|--replicas)
                replicas="$2"
                shift 2
                ;;
            -s|--skip-build)
                skip_build="true"
                shift
                ;;
            -d|--dry-run)
                dry_run="true"
                shift
                ;;
            -f|--force)
                force="true"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            dev|staging|prod)
                environment="$1"
                shift
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate environment
    if [ -z "$environment" ]; then
        echo -e "${RED}❌ Environment is required${NC}"
        show_usage
        exit 1
    fi

    # Check prerequisites
    check_prerequisites
    guard_local_cluster

    if [ "$force" != "true" ]; then
        check_argocd_ownership "$environment"
    fi

    # Build image
    if [ "$skip_build" != "true" ] && [ "$dry_run" != "true" ]; then
        build_image "${DOCKER_REGISTRY}/${IMAGE_NAME}:${version}"
    fi

    # Deploy with Helm
    deploy_with_helm "$environment" "$version" "$replicas" "$dry_run"

    # Run health checks (skip for dry run)
    if [ "$dry_run" != "true" ]; then
        run_health_checks "$environment"
    fi

    echo -e "${GREEN}🎉 Deployment completed successfully!${NC}"
}

# Run main function
main "$@"
