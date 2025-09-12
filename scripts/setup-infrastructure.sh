#!/bin/bash

# Setup Infrastructure Script
# This script sets up the complete infrastructure for the GitOps workflow

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DOCKER_REGISTRY=${DOCKER_REGISTRY:-"your-registry.com"}
CLUSTER_NAME=${CLUSTER_NAME:-"gitops-cluster"}
NAMESPACE_PREFIX=${NAMESPACE_PREFIX:-"user-service"}

echo -e "${GREEN}🚀 Setting up GitOps Infrastructure${NC}"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}📋 Checking prerequisites...${NC}"
    
    local missing_tools=()
    
    if ! command_exists kubectl; then
        missing_tools+=("kubectl")
    fi
    
    if ! command_exists helm; then
        missing_tools+=("helm")
    fi
    
    if ! command_exists docker; then
        missing_tools+=("docker")
    fi
    
    if ! command_exists linkerd; then
        missing_tools+=("linkerd")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        echo "Please install the missing tools and try again."
        exit 1
    fi
    
    echo -e "${GREEN}✅ All prerequisites are installed${NC}"
}

# Function to setup Linkerd
setup_linkerd() {
    echo -e "${YELLOW}🔗 Setting up Linkerd service mesh...${NC}"
    
    # Install Linkerd CLI if not already installed
    if ! command_exists linkerd; then
        echo "Installing Linkerd CLI..."
        curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh
        export PATH=$PATH:$HOME/.linkerd2/bin
    fi
    
    # Install Linkerd
    linkerd install --crds | kubectl apply -f -
    linkerd install | kubectl apply -f -
    
    # Wait for Linkerd to be ready
    echo "Waiting for Linkerd to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/linkerd-controller -n linkerd
    
    # Verify installation
    linkerd check
    
    echo -e "${GREEN}✅ Linkerd installed successfully${NC}"
}

# Function to setup ArgoCD
setup_argocd() {
    echo -e "${YELLOW}🔄 Setting up ArgoCD...${NC}"
    
    # Create ArgoCD namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Install ArgoCD
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    echo "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    
    # Get ArgoCD admin password
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo -e "${GREEN}✅ ArgoCD installed successfully${NC}"
    echo -e "${YELLOW}📝 ArgoCD admin password: ${ARGOCD_PASSWORD}${NC}"
    
    # Port forward ArgoCD server
    echo "Starting ArgoCD port forward..."
    kubectl port-forward svc/argocd-server -n argocd 8080:443 &
    ARGOCD_PID=$!
    echo "ArgoCD is available at https://localhost:8080"
    echo "Username: admin, Password: ${ARGOCD_PASSWORD}"
}

# Function to setup Jenkins
setup_jenkins() {
    echo -e "${YELLOW}🔧 Setting up Jenkins...${NC}"
    
    # Create Jenkins namespace
    kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Jenkins Helm repository
    helm repo add jenkins https://charts.jenkins.io
    helm repo update
    
    # Install Jenkins
    helm install jenkins jenkins/jenkins \
        --namespace jenkins \
        --set controller.serviceType=LoadBalancer \
        --set controller.servicePort=80 \
        --set controller.adminUser=admin \
        --set controller.adminPassword=admin \
        --set persistence.enabled=true \
        --set persistence.size=8Gi
    
    # Wait for Jenkins to be ready
    echo "Waiting for Jenkins to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/jenkins -n jenkins
    
    # Get Jenkins admin password
    JENKINS_PASSWORD=$(kubectl get secret --namespace jenkins jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 -d)
    echo -e "${GREEN}✅ Jenkins installed successfully${NC}"
    echo -e "${YELLOW}📝 Jenkins admin password: ${JENKINS_PASSWORD}${NC}"
    
    # Port forward Jenkins
    echo "Starting Jenkins port forward..."
    kubectl port-forward svc/jenkins -n jenkins 8081:80 &
    JENKINS_PID=$!
    echo "Jenkins is available at http://localhost:8081"
    echo "Username: admin, Password: ${JENKINS_PASSWORD}"
}

# Function to setup monitoring
setup_monitoring() {
    echo -e "${YELLOW}📊 Setting up monitoring...${NC}"
    
    # Install Prometheus and Grafana
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Prometheus
    helm install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set grafana.adminPassword=admin \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
    
    echo -e "${GREEN}✅ Monitoring stack installed successfully${NC}"
    echo "Grafana is available at http://localhost:3000 (admin/admin)"
}

# Function to create namespaces
create_namespaces() {
    echo -e "${YELLOW}📁 Creating namespaces...${NC}"
    
    local environments=("dev" "staging" "prod")
    
    for env in "${environments[@]}"; do
        kubectl create namespace "${NAMESPACE_PREFIX}-${env}" --dry-run=client -o yaml | kubectl apply -f -
        
        # Add Linkerd injection label
        kubectl label namespace "${NAMESPACE_PREFIX}-${env}" linkerd.io/inject=enabled --overwrite
        
        echo -e "${GREEN}✅ Created namespace: ${NAMESPACE_PREFIX}-${env}${NC}"
    done
}

# Function to deploy ArgoCD applications
deploy_argocd_apps() {
    echo -e "${YELLOW}🚀 Deploying ArgoCD applications...${NC}"
    
    # Wait for ArgoCD to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    
    # Apply ArgoCD applications
    kubectl apply -f argocd/applications/
    
    echo -e "${GREEN}✅ ArgoCD applications deployed${NC}"
}

# Function to build and push Docker image
build_and_push_image() {
    echo -e "${YELLOW}🐳 Building and pushing Docker image...${NC}"
    
    cd app
    
    # Build image
    docker build -t "${DOCKER_REGISTRY}/user-service:latest" .
    
    # Push image (if registry is configured)
    if [ "$DOCKER_REGISTRY" != "your-registry.com" ]; then
        docker push "${DOCKER_REGISTRY}/user-service:latest"
        echo -e "${GREEN}✅ Image pushed to registry${NC}"
    else
        echo -e "${YELLOW}⚠️  Skipping push - please configure DOCKER_REGISTRY${NC}"
    fi
    
    cd ..
}

# Main execution
main() {
    echo -e "${GREEN}🎯 Starting GitOps Infrastructure Setup${NC}"
    
    check_prerequisites
    setup_linkerd
    setup_argocd
    setup_jenkins
    setup_monitoring
    create_namespaces
    build_and_push_image
    deploy_argocd_apps
    
    echo -e "${GREEN}🎉 Infrastructure setup completed successfully!${NC}"
    echo ""
    echo -e "${YELLOW}📋 Access Information:${NC}"
    echo "ArgoCD: https://localhost:8080 (admin/${ARGOCD_PASSWORD})"
    echo "Jenkins: http://localhost:8081 (admin/${JENKINS_PASSWORD})"
    echo "Grafana: http://localhost:3000 (admin/admin)"
    echo ""
    echo -e "${YELLOW}🔧 Next Steps:${NC}"
    echo "1. Configure your Docker registry in Jenkins"
    echo "2. Set up Git webhooks for automatic builds"
    echo "3. Configure Slack notifications in Jenkins"
    echo "4. Test the deployment pipeline"
}

# Run main function
main "$@"
