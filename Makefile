# Makefile for GitOps project

# Variables
DOCKER_REGISTRY ?= your-registry.com
IMAGE_NAME ?= user-service
VERSION ?= latest
NAMESPACE ?= user-service
ENVIRONMENT ?= dev

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

# SAFETY: this is a test repo. Cluster targets only ever use the local kind
# cluster from on-prem/ (see on-prem/README.md), never the default ~/.kube/config.
export KUBECONFIG := $(CURDIR)/on-prem/.kube/config

HELM_CHART := k8s/helm/$(IMAGE_NAME)
RELEASE := $(IMAGE_NAME)-$(ENVIRONMENT)
ENV_NAMESPACE := $(NAMESPACE)-$(ENVIRONMENT)

.PHONY: guard-local help proto build test lint security-scan docker-build docker-push docker-run \
	k8s-apply k8s-delete k8s-status helm-lint helm-template helm-install helm-uninstall helm-upgrade helm-status \
	linkerd-install linkerd-inject linkerd-dashboard argocd-install argocd-apps argocd-dashboard \
	jenkins-install jenkins-dashboard deploy-dev deploy-staging deploy-prod setup-infrastructure \
	clean logs port-forward health-check ci-build all dev-setup

# Refuse to run cluster targets unless KUBECONFIG points at a local API server
guard-local:
	@test -f "$(KUBECONFIG)" || { echo "$(RED)$(KUBECONFIG) not found. Run 'make -C on-prem up' first.$(NC)"; exit 1; }
	@server=$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'); \
	case "$$server" in \
		https://127.0.0.1:*|https://localhost:*) ;; \
		*) echo "$(RED)Refusing to use non-local cluster: $$server$(NC)"; exit 1 ;; \
	esac

# Default target
help: ## Show this help message
	@echo "$(GREEN)GitOps Project Makefile$(NC)"
	@echo ""
	@echo "$(YELLOW)Available targets:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Development targets
proto: ## Regenerate protobuf code (requires protoc, protoc-gen-go, protoc-gen-go-grpc)
	@echo "$(BLUE)Generating protobuf code...$(NC)"
	cd app && \
	protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		proto/user.proto

build: ## Build the Go application
	@echo "$(BLUE)Building Go application...$(NC)"
	cd app && \
	go mod download && \
	CGO_ENABLED=0 go build -trimpath -o main ./src

test: ## Run tests
	@echo "$(BLUE)Running tests...$(NC)"
	cd app && \
	go vet ./... && \
	test -z "$$(gofmt -s -l .)" || { echo "Run 'gofmt -s -w .' on:"; gofmt -s -l .; exit 1; } && \
	go test -race -v ./...

lint: ## Run linters
	@echo "$(BLUE)Running linters...$(NC)"
	cd app && \
	golangci-lint run

security-scan: ## Run security scan
	@echo "$(BLUE)Running security scan...$(NC)"
	cd app && \
	go install github.com/securego/gosec/v2/cmd/gosec@v2.21.4 && \
	gosec -exclude-generated -fmt json -out gosec-report.json -stdout -verbose=text ./...

# Docker targets
docker-build: ## Build Docker image
	@echo "$(BLUE)Building Docker image...$(NC)"
	cd app && \
	docker build -t $(DOCKER_REGISTRY)/$(IMAGE_NAME):$(VERSION) .

docker-push: ## Push Docker image
	@echo "$(BLUE)Pushing Docker image...$(NC)"
	docker push $(DOCKER_REGISTRY)/$(IMAGE_NAME):$(VERSION)

docker-run: ## Run Docker container locally
	@echo "$(BLUE)Running Docker container...$(NC)"
	docker run -p 8080:8080 -p 50051:50051 $(DOCKER_REGISTRY)/$(IMAGE_NAME):$(VERSION)

# Kubernetes targets
k8s-apply: guard-local ## Apply Kubernetes manifests
	@echo "$(BLUE)Applying Kubernetes manifests...$(NC)"
	kubectl apply -f k8s/manifests/

k8s-delete: guard-local ## Delete Kubernetes resources
	@echo "$(BLUE)Deleting Kubernetes resources...$(NC)"
	kubectl delete -f k8s/manifests/ --ignore-not-found=true

k8s-status: guard-local ## Check Kubernetes deployment status
	@echo "$(BLUE)Checking deployment status...$(NC)"
	kubectl get pods -n $(NAMESPACE)
	kubectl get svc -n $(NAMESPACE)
	kubectl get ingress -n $(NAMESPACE)

# Helm targets
HELM_VALUES := -f $(HELM_CHART)/values.yaml -f $(HELM_CHART)/values-$(ENVIRONMENT).yaml \
	--set image.repository=$(DOCKER_REGISTRY)/$(IMAGE_NAME) --set-string image.tag=$(VERSION)

helm-lint: ## Lint the Helm chart for every environment
	@echo "$(BLUE)Linting Helm chart...$(NC)"
	for env in dev staging prod; do \
		helm lint $(HELM_CHART) -f $(HELM_CHART)/values-$$env.yaml || exit 1; \
	done

helm-template: ## Render the Helm chart for ENVIRONMENT
	helm template $(RELEASE) $(HELM_CHART) --namespace $(ENV_NAMESPACE) $(HELM_VALUES)

helm-install: guard-local ## Install Helm chart (manual deploy; ArgoCD-managed envs deploy via Git)
	@echo "$(BLUE)Installing Helm chart...$(NC)"
	helm upgrade --install $(RELEASE) $(HELM_CHART) \
		--namespace $(ENV_NAMESPACE) \
		--create-namespace \
		$(HELM_VALUES)

helm-uninstall: guard-local ## Uninstall Helm chart
	@echo "$(BLUE)Uninstalling Helm chart...$(NC)"
	helm uninstall $(RELEASE) -n $(ENV_NAMESPACE)

helm-upgrade: guard-local ## Upgrade Helm chart
	@echo "$(BLUE)Upgrading Helm chart...$(NC)"
	helm upgrade $(RELEASE) $(HELM_CHART) \
		--namespace $(ENV_NAMESPACE) \
		$(HELM_VALUES)

helm-status: guard-local ## Check Helm release status
	@echo "$(BLUE)Checking Helm release status...$(NC)"
	helm status $(RELEASE) -n $(ENV_NAMESPACE)

# Linkerd targets
linkerd-install: guard-local ## Install Linkerd
	@echo "$(BLUE)Installing Linkerd...$(NC)"
	linkerd check --pre
	linkerd install --crds | kubectl apply -f -
	linkerd install | kubectl apply -f -
	linkerd check --wait 5m

linkerd-inject: guard-local ## Inject Linkerd into namespace
	@echo "$(BLUE)Injecting Linkerd into namespace...$(NC)"
	kubectl label namespace $(ENV_NAMESPACE) linkerd.io/inject=enabled --overwrite

linkerd-dashboard: guard-local ## Open Linkerd dashboard
	@echo "$(BLUE)Opening Linkerd dashboard...$(NC)"
	linkerd dashboard

# ArgoCD targets
argocd-install: guard-local ## Install ArgoCD
	@echo "$(BLUE)Installing ArgoCD...$(NC)"
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

argocd-apps: guard-local ## Deploy ArgoCD applications (app-of-apps)
	@echo "$(BLUE)Deploying ArgoCD applications...$(NC)"
	kubectl apply -f argocd/app-of-apps.yaml

argocd-dashboard: guard-local ## Port forward ArgoCD dashboard
	@echo "$(BLUE)Port forwarding ArgoCD dashboard...$(NC)"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

# Jenkins targets
jenkins-install: guard-local ## Install Jenkins
	@echo "$(BLUE)Installing Jenkins...$(NC)"
	kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
	helm repo add jenkins https://charts.jenkins.io
	helm repo update jenkins
	helm upgrade --install jenkins jenkins/jenkins -n jenkins -f jenkins/values.yaml

jenkins-dashboard: guard-local ## Port forward Jenkins dashboard
	@echo "$(BLUE)Port forwarding Jenkins dashboard...$(NC)"
	kubectl port-forward svc/jenkins -n jenkins 8081:80

# Deployment targets
deploy-dev: ## Deploy to development environment
	@echo "$(BLUE)Deploying to development...$(NC)"
	./scripts/deploy.sh dev -v $(VERSION)

deploy-staging: ## Deploy to staging environment
	@echo "$(BLUE)Deploying to staging...$(NC)"
	./scripts/deploy.sh staging -v $(VERSION)

deploy-prod: ## Deploy to production environment
	@echo "$(BLUE)Deploying to production...$(NC)"
	./scripts/deploy.sh prod -v $(VERSION)

# Infrastructure targets
setup-infrastructure: ## Setup complete infrastructure
	@echo "$(BLUE)Setting up infrastructure...$(NC)"
	./scripts/setup-infrastructure.sh

# Utility targets
clean: ## Clean up build artifacts
	@echo "$(BLUE)Cleaning up...$(NC)"
	cd app && rm -f main gosec-report.json

logs: guard-local ## Show application logs
	@echo "$(BLUE)Showing application logs...$(NC)"
	kubectl logs -f deployment/$(RELEASE) -c $(IMAGE_NAME) -n $(ENV_NAMESPACE)

port-forward: guard-local ## Port forward to service
	@echo "$(BLUE)Port forwarding to service...$(NC)"
	kubectl port-forward svc/$(RELEASE) 8080:80 -n $(ENV_NAMESPACE)

health-check: ## Run health check
	@echo "$(BLUE)Running health check...$(NC)"
	curl -f http://localhost:8080/health || echo "$(RED)Health check failed$(NC)"

# CI targets (deployment is done by ArgoCD from Git, see jenkins/Jenkinsfile)
ci-build: build test security-scan docker-build ## Run CI build pipeline
	@echo "$(GREEN)CI build completed successfully$(NC)"

# All-in-one targets
all: build test docker-build docker-push helm-install ## Build, test, and deploy everything
	@echo "$(GREEN)All targets completed successfully$(NC)"

dev-setup: setup-infrastructure deploy-dev ## Setup development environment
	@echo "$(GREEN)Development environment setup completed$(NC)"
