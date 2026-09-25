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
- **Language**: Go 1.23
- **Protocol**: gRPC with HTTP health checks
- **Features**: User CRUD operations, health checks, metrics
- **Ports**: 8080 (HTTP), 50051 (gRPC)

### 2. Kubernetes
- **Manifests**: Complete K8s resources (Deployment, Service, Ingress, HPA)
- **Helm Charts**: Parameterized deployment templates
- **Namespaces**: Environment-specific namespaces

### 3. Linkerd Service Mesh
- **Service Profiles**: Per-route metrics, retries for read-only gRPC calls and timeouts (rendered by the Helm chart)
- **mTLS**: Automatic between meshed pods
- **Observability**: Golden metrics via `linkerd viz`

### 4. Jenkins CI/CD
- **Pipeline**: Test, security scan, build image with kaniko, commit the new image tag to Git
- **Features**: Image promotion between environments, manual approval for prod, smoke tests, Slack notifications
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
# Installs Linkerd, ArgoCD, Jenkins (jenkins/values.yaml), Prometheus/Grafana,
# creates the namespaces and applies the ArgoCD app-of-apps
DOCKER_REGISTRY=<your-registry> make setup-infrastructure
```

Before running the pipeline, set `DOCKER_REGISTRY` in `jenkins/Jenkinsfile` and
`image.repository` in `k8s/helm/user-service/values.yaml`, then create:

- Kubernetes secret `registry-credentials` (type `docker-registry`) in the `jenkins` namespace, used by kaniko to push
- Jenkins credential `git-credentials` (username + token with push access to this repo)
- Jenkins credential `argocd-token` (secret text, ArgoCD API token)

### 2. Build and Deploy

```bash
# Run tests and build the application
make test build

# GitOps (recommended): ArgoCD deploys whatever values-<env>.yaml points at
make argocd-apps

# Manual deploy to a cluster without ArgoCD
make deploy-dev VERSION=dev-1
```

### 3. Verify Deployment

```bash
# Check pods
kubectl get pods -n user-service-dev

# Check services
kubectl get svc -n user-service-dev

# Test health endpoint
kubectl port-forward svc/user-service-dev 8080:80 -n user-service-dev
curl http://localhost:8080/health
```

## GitOps Workflow

### 1. Development Flow

```bash
# 1. Developer pushes code
git add .
git commit -m "feat: add new user endpoint"
git push origin main

# 2. Jenkins automatically triggers (ENVIRONMENT=dev)
# - Runs tests and security scans
# - Builds and pushes <registry>/user-service:<git describe>
# - Commits the new tag to k8s/helm/user-service/values-dev.yaml ([skip ci])

# 3. ArgoCD syncs changes
# - Detects the commit and rolls out the new image
# - Jenkins waits for the app to be Synced/Healthy, then runs a smoke test
# - Rollback = revert the commit in Git
```

### 2. Production Deployment

```bash
# 1. Create release tag
git tag v1.0.0
git push origin v1.0.0

# 2. Promote the already-tested image (no rebuild)
# Run the Jenkins job with ENVIRONMENT=staging, VERSION=v1.0.0,
# then ENVIRONMENT=prod, VERSION=v1.0.0 (requires manual approval)

# 3. ArgoCD deploys to production
# - Syncs values-prod.yaml
# - Performs rolling update
# - Monitors deployment health
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GRPC_PORT` | gRPC server port (overrides `grpc.port`) | 50051 |
| `HTTP_PORT` | HTTP server port (overrides `http.port`) | 8080 |
| `LOG_LEVEL` | Logging level (overrides `log.level`) | info |
| `CONFIG_PATH` | Config file path | ./configs/config.yaml |

### Helm Values

Shared defaults live in `values.yaml`; per-environment overrides (including the
image tag that Jenkins updates) live in `values-dev.yaml`, `values-staging.yaml`
and `values-prod.yaml`.

```yaml
replicaCount: 3
image:
  repository: your-registry.com/user-service
  tag: ""  # set per environment
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
linkerd viz stat deployment -n user-service-dev
```

### Prometheus Metrics

The service exposes metrics at `/metrics` endpoint:

- `grpc_server_started_total`, `grpc_server_handled_total`: gRPC requests by method and status code
- `grpc_server_msg_received_total`, `grpc_server_msg_sent_total`: gRPC messages
- `go_*`, `process_*`: Go runtime and process metrics

The server also implements the standard gRPC health checking protocol (`grpc.health.v1.Health`).

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
- Dedicated ServiceAccount per release

## Troubleshooting

### Common Issues

1. **Pod not starting**
   ```bash
   kubectl describe pod <pod-name> -n user-service-dev
   kubectl logs <pod-name> -c user-service -n user-service-dev
   ```

2. **Service not accessible**
   ```bash
   kubectl get svc -n user-service-dev
   kubectl get endpoints -n user-service-dev
   ```

3. **ArgoCD sync issues**
   ```bash
   argocd app get user-service-prod
   argocd app sync user-service-prod
   ```

### Debug Commands

```bash
# Check Linkerd injection
kubectl get pods -n user-service-dev -o yaml | grep linkerd

# View service mesh traffic
linkerd viz tap deployment/user-service-dev -n user-service-dev

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
