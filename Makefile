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

.PHONY: help build test deploy clean setup-infrastructure

# Default target
help: ## Show this help message
	@echo "$(GREEN)GitOps Project Makefile$(NC)"
	@echo ""
	@echo "$(YELLOW)Available targets:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Development targets
build: ## Build the Go application
	@echo "$(BLUE)Building Go application...$(NC)"
	cd app && \
	go mod download && \
	protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		proto/user.proto && \
	CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main ./src

test: ## Run tests
	@echo "$(BLUE)Running tests...$(NC)"
	cd app && \
	go test -v ./... && \
	go vet ./... && \
	gofmt -s -l . | wc -l | xargs -I {} test {} -eq 0

lint: ## Run linters
	@echo "$(BLUE)Running linters...$(NC)"
	cd app && \
	golangci-lint run

security-scan: ## Run security scan
	@echo "$(BLUE)Running security scan...$(NC)"
	cd app && \
	go install github.com/securecodewarrior/gosec/v2/cmd/gosec@latest && \
	gosec -fmt json -out gosec-report.json ./...

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
k8s-apply: ## Apply Kubernetes manifests
	@echo "$(BLUE)Applying Kubernetes manifests...$(NC)"
	kubectl apply -f k8s/manifests/

k8s-delete: ## Delete Kubernetes resources
	@echo "$(BLUE)Deleting Kubernetes resources...$(NC)"
	kubectl delete -f k8s/manifests/ --ignore-not-found=true

k8s-status: ## Check Kubernetes deployment status
	@echo "$(BLUE)Checking deployment status...$(NC)"
	kubectl get pods -n $(NAMESPACE)
	kubectl get svc -n $(NAMESPACE)
	kubectl get ingress -n $(NAMESPACE)

# Helm targets
helm-install: ## Install Helm chart
	@echo "$(BLUE)Installing Helm chart...$(NC)"
	helm upgrade --install $(IMAGE_NAME)-$(ENVIRONMENT) k8s/helm/$(IMAGE_NAME) \
		--namespace $(NAMESPACE)-$(ENVIRONMENT) \
		--create-namespace \
		--set image.tag=$(VERSION)

helm-uninstall: ## Uninstall Helm chart
	@echo "$(BLUE)Uninstalling Helm chart...$(NC)"
	helm uninstall $(IMAGE_NAME)-$(ENVIRONMENT) -n $(NAMESPACE)-$(ENVIRONMENT)

helm-upgrade: ## Upgrade Helm chart
	@echo "$(BLUE)Upgrading Helm chart...$(NC)"
	helm upgrade $(IMAGE_NAME)-$(ENVIRONMENT) k8s/helm/$(IMAGE_NAME) \
		--namespace $(NAMESPACE)-$(ENVIRONMENT) \
		--set image.tag=$(VERSION)

helm-status: ## Check Helm release status
	@echo "$(BLUE)Checking Helm release status...$(NC)"
	helm status $(IMAGE_NAME)-$(ENVIRONMENT) -n $(NAMESPACE)-$(ENVIRONMENT)

# Linkerd targets
linkerd-install: ## Install Linkerd
	@echo "$(BLUE)Installing Linkerd...$(NC)"
	linkerd install --crds | kubectl apply -f -
	linkerd install | kubectl apply -f -
	linkerd check

linkerd-inject: ## Inject Linkerd into namespace
	@echo "$(BLUE)Injecting Linkerd into namespace...$(NC)"
	kubectl label namespace $(NAMESPACE)-$(ENVIRONMENT) linkerd.io/inject=enabled --overwrite

linkerd-dashboard: ## Open Linkerd dashboard
	@echo "$(BLUE)Opening Linkerd dashboard...$(NC)"
	linkerd dashboard

# ArgoCD targets
argocd-install: ## Install ArgoCD
	@echo "$(BLUE)Installing ArgoCD...$(NC)"
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

argocd-apps: ## Deploy ArgoCD applications
	@echo "$(BLUE)Deploying ArgoCD applications...$(NC)"
	kubectl apply -f argocd/applications/

argocd-dashboard: ## Port forward ArgoCD dashboard
	@echo "$(BLUE)Port forwarding ArgoCD dashboard...$(NC)"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

# Jenkins targets
jenkins-install: ## Install Jenkins
	@echo "$(BLUE)Installing Jenkins...$(NC)"
	kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
	helm repo add jenkins https://charts.jenkins.io
	helm install jenkins jenkins/jenkins -n jenkins

jenkins-dashboard: ## Port forward Jenkins dashboard
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
	cd app && rm -f main
	docker system prune -f

logs: ## Show application logs
	@echo "$(BLUE)Showing application logs...$(NC)"
	kubectl logs -f deployment/$(IMAGE_NAME) -n $(NAMESPACE)-$(ENVIRONMENT)

port-forward: ## Port forward to service
	@echo "$(BLUE)Port forwarding to service...$(NC)"
	kubectl port-forward svc/$(IMAGE_NAME)-$(ENVIRONMENT) 8080:80 -n $(NAMESPACE)-$(ENVIRONMENT)

health-check: ## Run health check
	@echo "$(BLUE)Running health check...$(NC)"
	curl -f http://localhost:8080/health || echo "$(RED)Health check failed$(NC)"

# CI/CD targets
ci-build: build test security-scan docker-build ## Run CI build pipeline
	@echo "$(GREEN)CI build completed successfully$(NC)"

ci-deploy: docker-push helm-upgrade ## Run CI deploy pipeline
	@echo "$(GREEN)CI deploy completed successfully$(NC)"

# All-in-one targets
all: build test docker-build docker-push helm-install ## Build, test, and deploy everything
	@echo "$(GREEN)All targets completed successfully$(NC)"

dev-setup: setup-infrastructure deploy-dev ## Setup development environment
	@echo "$(GREEN)Development environment setup completed$(NC)"
