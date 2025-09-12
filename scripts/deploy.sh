#!/bin/bash

# Deployment Script
# This script handles deployment of the user service to different environments

set -e

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
    echo "  -r, --replicas COUNT     Number of replicas (default: environment specific)"
    echo "  -d, --dry-run           Show what would be deployed without applying"
    echo "  -h, --help              Show this help message"
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
    
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v helm >/dev/null 2>&1; then
        missing_tools+=("helm")
    fi
    
    if ! command -v docker >/dev/null 2>&1; then
        missing_tools+=("docker")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        exit 1
    fi
}

# Function to build Docker image
build_image() {
    local version=$1
    local image_tag="${DOCKER_REGISTRY}/${IMAGE_NAME}:${version}"
    
    echo -e "${BLUE}🐳 Building Docker image: ${image_tag}${NC}"
    
    cd app
    
    # Generate protobuf files
    if command -v protoc >/dev/null 2>&1; then
        echo "Generating protobuf files..."
        protoc --go_out=. --go_opt=paths=source_relative \
            --go-grpc_out=. --go-grpc_opt=paths=source_relative \
            proto/user.proto
    else
        echo -e "${YELLOW}⚠️  protoc not found, skipping protobuf generation${NC}"
    fi
    
    # Build image
    docker build -t "${image_tag}" .
    
    # Push image if registry is configured
    if [ "$DOCKER_REGISTRY" != "your-registry.com" ]; then
        echo "Pushing image to registry..."
        docker push "${image_tag}"
    else
        echo -e "${YELLOW}⚠️  Skipping push - please configure DOCKER_REGISTRY${NC}"
    fi
    
    cd ..
    
    echo "${image_tag}"
}

# Function to get environment-specific values
get_env_values() {
    local environment=$1
    local version=$2
    local replicas=$3
    
    case $environment in
        "dev")
            echo "replicaCount: ${replicas:-1}"
            echo "image.tag: \"${version}\""
            echo "ingress.hosts[0].host: \"user-service-dev.local\""
            echo "autoscaling.enabled: false"
            echo "resources.limits.cpu: \"200m\""
            echo "resources.limits.memory: \"256Mi\""
            echo "resources.requests.cpu: \"50m\""
            echo "resources.requests.memory: \"64Mi\""
            ;;
        "staging")
            echo "replicaCount: ${replicas:-2}"
            echo "image.tag: \"${version}\""
            echo "ingress.hosts[0].host: \"user-service-staging.local\""
            echo "autoscaling.enabled: true"
            echo "autoscaling.minReplicas: 2"
            echo "autoscaling.maxReplicas: 5"
            echo "resources.limits.cpu: \"500m\""
            echo "resources.limits.memory: \"512Mi\""
            echo "resources.requests.cpu: \"100m\""
            echo "resources.requests.memory: \"128Mi\""
            ;;
        "prod")
            echo "replicaCount: ${replicas:-3}"
            echo "image.tag: \"${version}\""
            echo "ingress.hosts[0].host: \"user-service-prod.local\""
            echo "autoscaling.enabled: true"
            echo "autoscaling.minReplicas: 3"
            echo "autoscaling.maxReplicas: 10"
            echo "resources.limits.cpu: \"1000m\""
            echo "resources.limits.memory: \"1Gi\""
            echo "resources.requests.cpu: \"200m\""
            echo "resources.requests.memory: \"256Mi\""
            ;;
        *)
            echo -e "${RED}❌ Invalid environment: ${environment}${NC}"
            exit 1
            ;;
    esac
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
    echo "Replicas: ${replicas:-'default'}"
    
    # Create namespace if it doesn't exist
    kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Linkerd injection label
    kubectl label namespace "${namespace}" linkerd.io/inject=enabled --overwrite
    
    # Prepare Helm values
    local helm_values=$(get_env_values "$environment" "$version" "$replicas")
    
    # Create temporary values file
    local temp_values=$(mktemp)
    echo "$helm_values" > "$temp_values"
    
    # Deploy with Helm
    local helm_cmd="helm upgrade --install ${release_name} ${HELM_CHART_PATH} --namespace ${namespace} --values ${temp_values}"
    
    if [ "$dry_run" = "true" ]; then
        helm_cmd="${helm_cmd} --dry-run --debug"
        echo -e "${YELLOW}🔍 Dry run mode - showing what would be deployed${NC}"
    else
        helm_cmd="${helm_cmd} --wait --timeout=300s"
    fi
    
    echo "Running: ${helm_cmd}"
    eval "$helm_cmd"
    
    # Clean up temporary file
    rm -f "$temp_values"
    
    if [ "$dry_run" != "true" ]; then
        echo -e "${GREEN}✅ Deployment completed successfully${NC}"
        
        # Show deployment status
        echo -e "${BLUE}📊 Deployment Status:${NC}"
        kubectl get pods -n "${namespace}" -l app="${IMAGE_NAME}"
        kubectl get svc -n "${namespace}" -l app="${IMAGE_NAME}"
        
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
    
    echo -e "${BLUE}🏥 Running health checks...${NC}"
    
    # Wait for pods to be ready
    echo "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l app="${IMAGE_NAME}" -n "${namespace}" --timeout=300s
    
    # Get service endpoint
    local service_ip=$(kubectl get svc "${IMAGE_NAME}-${environment}" -n "${namespace}" -o jsonpath='{.spec.clusterIP}')
    
    if [ -n "$service_ip" ]; then
        echo "Testing health endpoint..."
        kubectl run test-pod --image=curlimages/curl --rm -i --restart=Never -- \
            curl -f "http://${service_ip}/health" || {
            echo -e "${RED}❌ Health check failed${NC}"
            return 1
        }
        
        echo -e "${GREEN}✅ Health checks passed${NC}"
    else
        echo -e "${YELLOW}⚠️  Could not get service IP, skipping health checks${NC}"
    fi
}

# Main function
main() {
    local environment=""
    local version="latest"
    local replicas=""
    local dry_run="false"
    
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
            -d|--dry-run)
                dry_run="true"
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
    
    # Build image
    local image_tag=$(build_image "$version")
    
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
