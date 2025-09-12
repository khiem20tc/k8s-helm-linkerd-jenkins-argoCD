# GitOps Full Flow with K8s, Linkerd, Jenkins, and ArgoCD

This repository demonstrates a complete GitOps workflow for deploying a Golang gRPC microservice using Kubernetes, Linkerd service mesh, Jenkins CI/CD, and ArgoCD.

## Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Developer     │    │     Jenkins     │    │     ArgoCD      │
│                 │    │                 │    │                 │
│ 1. Push Code    │───▶│ 2. Build & Test │───▶│ 3. Deploy to K8s│
│                 │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │  Docker Registry│    │   Kubernetes    │
                       │                 │    │   + Linkerd     │
                       │ 3. Push Image   │    │ 4. Run Service  │
                       └─────────────────┘    └─────────────────┘
```

## Components

### 1. Golang gRPC Microservice
- **Language**: Go 1.21
- **Protocol**: gRPC with HTTP health checks
- **Features**: User CRUD operations, health checks, metrics
- **Ports**: 8080 (HTTP), 50051 (gRPC)

### 2. Kubernetes
- **Manifests**: Complete K8s resources (Deployment, Service, Ingress, HPA)
- **Helm Charts**: Parameterized deployment templates
- **Namespaces**: Environment-specific namespaces

### 3. Linkerd Service Mesh
- **Service Profiles**: Traffic routing and retry policies
- **Traffic Splits**: Canary deployments
- **Observability**: Metrics, tracing, and monitoring

### 4. Jenkins CI/CD
- **Pipeline**: Multi-stage build, test, and deploy
- **Features**: Security scanning, integration tests, Slack notifications
- **Environments**: Dev, Staging, Production

### 5. ArgoCD GitOps
- **Applications**: Environment-specific deployments
- **App of Apps**: Centralized application management
- **Sync Policies**: Automated deployments with rollback

## Quick Start

### Prerequisites

1. **Kubernetes Cluster** (minikube, kind, or cloud provider)
2. **Docker** for building images
3. **Helm** for package management
4. **kubectl** for cluster management
5. **Linkerd CLI** for service mesh
6. **ArgoCD CLI** for GitOps

### 1. Setup Infrastructure

```bash
# Install Linkerd
linkerd install | kubectl apply -f -
linkerd check

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Install Jenkins
kubectl create namespace jenkins
helm repo add jenkins https://charts.jenkins.io
helm install jenkins jenkins/jenkins -n jenkins
```

### 2. Build and Deploy

```bash
# Build the application
cd app
docker build -t user-service:latest .

# Deploy using Helm
cd ../k8s/helm
helm install user-service ./user-service --namespace user-service --create-namespace

# Deploy ArgoCD applications
kubectl apply -f ../argocd/applications/
```

### 3. Verify Deployment

```bash
# Check pods
kubectl get pods -n user-service

# Check services
kubectl get svc -n user-service

# Test health endpoint
kubectl port-forward svc/user-service 8080:80 -n user-service
curl http://localhost:8080/health
```

## GitOps Workflow

### 1. Development Flow

```bash
# 1. Developer pushes code
git add .
git commit -m "feat: add new user endpoint"
git push origin main

# 2. Jenkins automatically triggers
# - Builds Docker image
# - Runs tests and security scans
# - Updates Helm values
# - Deploys to dev environment

# 3. ArgoCD syncs changes
# - Monitors Git repository
# - Applies changes to Kubernetes
# - Provides rollback capabilities
```

### 2. Production Deployment

```bash
# 1. Create release tag
git tag v1.0.0
git push origin v1.0.0

# 2. Jenkins builds production image
# - Tags image with version
# - Runs comprehensive tests
# - Updates ArgoCD application

# 3. ArgoCD deploys to production
# - Validates configuration
# - Performs rolling update
# - Monitors deployment health
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GRPC_PORT` | gRPC server port | 50051 |
| `HTTP_PORT` | HTTP server port | 8080 |
| `LOG_LEVEL` | Logging level | info |
| `CONFIG_PATH` | Config file path | /app/configs/config.yaml |

### Helm Values

Key configuration options in `values.yaml`:

```yaml
replicaCount: 3
image:
  repository: user-service
  tag: "latest"
service:
  type: ClusterIP
  port: 80
  grpcPort: 50051
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
```

## Monitoring and Observability

### Linkerd Dashboard

```bash
# Access Linkerd dashboard
linkerd dashboard

# View service metrics
linkerd stat deployment -n user-service
```

### Prometheus Metrics

The service exposes metrics at `/metrics` endpoint:

- `http_requests_total`: Total HTTP requests
- `grpc_requests_total`: Total gRPC requests
- `service_uptime`: Service uptime

### Health Checks

- **Liveness**: `GET /health`
- **Readiness**: `GET /ready`
- **Metrics**: `GET /metrics`

## Security

### Container Security

- Non-root user (UID 1001)
- Read-only root filesystem
- Minimal base image (Alpine)
- Security scanning with gosec

### Network Security

- Linkerd mTLS between services
- Network policies for traffic control
- RBAC for Kubernetes resources

## Troubleshooting

### Common Issues

1. **Pod not starting**
   ```bash
   kubectl describe pod <pod-name> -n user-service
   kubectl logs <pod-name> -n user-service
   ```

2. **Service not accessible**
   ```bash
   kubectl get svc -n user-service
   kubectl get endpoints -n user-service
   ```

3. **ArgoCD sync issues**
   ```bash
   argocd app get user-service-prod
   argocd app sync user-service-prod
   ```

### Debug Commands

```bash
# Check Linkerd injection
kubectl get pods -n user-service -o yaml | grep linkerd

# View service mesh traffic
linkerd tap deployment/user-service -n user-service

# Check ArgoCD application status
argocd app list
argocd app get user-service-prod
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
