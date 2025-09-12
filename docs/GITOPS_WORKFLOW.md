# GitOps Workflow Documentation

## Overview

This document describes the complete GitOps workflow for deploying a Golang gRPC microservice using Kubernetes, Linkerd service mesh, Jenkins CI/CD, and ArgoCD.

## Architecture Components

### 1. Source Control (Git)
- **Repository**: GitHub repository containing all application code and infrastructure definitions
- **Branches**: 
  - `main`: Production-ready code
  - `develop`: Development branch
  - `feature/*`: Feature branches
- **Triggers**: Webhooks for automatic CI/CD pipeline execution

### 2. CI/CD Pipeline (Jenkins)
- **Build Stage**: Compile Go application, generate protobuf files
- **Test Stage**: Unit tests, integration tests, security scanning
- **Package Stage**: Build Docker image, push to registry
- **Deploy Stage**: Update Helm values, deploy to environments

### 3. GitOps Controller (ArgoCD)
- **Application Management**: Manages application deployments across environments
- **Sync Policies**: Automated synchronization with Git repository
- **Rollback Capabilities**: Quick rollback to previous versions
- **Multi-Environment**: Dev, Staging, Production environments

### 4. Container Orchestration (Kubernetes)
- **Deployment**: Manages application pods and replicas
- **Service**: Exposes application endpoints
- **Ingress**: Routes external traffic to services
- **HPA**: Auto-scaling based on metrics

### 5. Service Mesh (Linkerd)
- **Traffic Management**: Load balancing, retry policies
- **Security**: mTLS between services
- **Observability**: Metrics, tracing, monitoring
- **Traffic Splitting**: Canary deployments

## Workflow Steps

### 1. Development Phase

```bash
# Developer workflow
git checkout -b feature/new-endpoint
# Make changes to code
git add .
git commit -m "feat: add new user endpoint"
git push origin feature/new-endpoint
```

### 2. CI/CD Pipeline Execution

#### Build Stage
```yaml
- Build Go application
- Generate protobuf files
- Run unit tests
- Security scanning with gosec
- Code quality checks
```

#### Package Stage
```yaml
- Build Docker image
- Tag with version
- Push to container registry
- Update Helm chart values
```

#### Deploy Stage
```yaml
- Deploy to development environment
- Run integration tests
- Update ArgoCD application
- Notify team via Slack
```

### 3. GitOps Deployment

#### ArgoCD Sync Process
1. **Detection**: ArgoCD detects changes in Git repository
2. **Validation**: Validates Kubernetes manifests
3. **Deployment**: Applies changes to target environment
4. **Monitoring**: Monitors deployment health
5. **Rollback**: Automatic rollback on failure

#### Environment Promotion
```bash
# Development → Staging
argocd app sync user-service-staging

# Staging → Production (with approval)
argocd app sync user-service-prod
```

### 4. Service Mesh Integration

#### Linkerd Features
- **Automatic mTLS**: Secure communication between services
- **Traffic Splitting**: Gradual rollout of new versions
- **Retry Policies**: Automatic retry on transient failures
- **Circuit Breaking**: Prevent cascade failures

#### Service Profile Configuration
```yaml
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: user-service
spec:
  routes:
  - name: "gRPC UserService"
    condition:
      method: POST
      pathRegex: "/user.UserService/.*"
  retryBudget:
    retryRatio: 0.2
    minRetriesPerSecond: 10
```

## Environment Configuration

### Development Environment
- **Replicas**: 1
- **Resources**: Minimal (50m CPU, 64Mi memory)
- **Auto-scaling**: Disabled
- **Monitoring**: Basic metrics

### Staging Environment
- **Replicas**: 2
- **Resources**: Medium (100m CPU, 128Mi memory)
- **Auto-scaling**: Enabled (2-5 replicas)
- **Monitoring**: Full metrics and tracing

### Production Environment
- **Replicas**: 3
- **Resources**: High (200m CPU, 256Mi memory)
- **Auto-scaling**: Enabled (3-10 replicas)
- **Monitoring**: Full observability stack
- **Security**: Enhanced security policies

## Monitoring and Observability

### Metrics Collection
- **Application Metrics**: Custom business metrics
- **Infrastructure Metrics**: CPU, memory, network
- **Service Mesh Metrics**: Request rates, latencies, errors

### Dashboards
- **Grafana**: Custom dashboards for application monitoring
- **Linkerd Dashboard**: Service mesh observability
- **Prometheus**: Metrics storage and alerting

### Alerting
- **Slack Notifications**: Deployment status, failures
- **Email Alerts**: Critical system issues
- **PagerDuty**: Production incidents

## Security Considerations

### Container Security
- **Non-root User**: Application runs as non-root
- **Read-only Filesystem**: Immutable container filesystem
- **Security Scanning**: Automated vulnerability scanning
- **Base Image**: Minimal Alpine Linux base

### Network Security
- **mTLS**: Mutual TLS between services via Linkerd
- **Network Policies**: Kubernetes network segmentation
- **RBAC**: Role-based access control
- **Secrets Management**: Kubernetes secrets for sensitive data

### CI/CD Security
- **Secret Management**: Secure handling of credentials
- **Image Signing**: Signed container images
- **Access Control**: Limited access to production environments
- **Audit Logging**: Complete audit trail

## Troubleshooting Guide

### Common Issues

#### 1. Pod Not Starting
```bash
# Check pod status
kubectl get pods -n user-service-prod

# Check pod logs
kubectl logs -f deployment/user-service -n user-service-prod

# Check pod events
kubectl describe pod <pod-name> -n user-service-prod
```

#### 2. Service Not Accessible
```bash
# Check service endpoints
kubectl get endpoints -n user-service-prod

# Check service configuration
kubectl get svc user-service -n user-service-prod -o yaml

# Test connectivity
kubectl run test-pod --image=curlimages/curl --rm -i --restart=Never -- \
  curl -f http://user-service.user-service-prod.svc.cluster.local/health
```

#### 3. ArgoCD Sync Issues
```bash
# Check application status
argocd app get user-service-prod

# Force sync
argocd app sync user-service-prod

# Check sync history
argocd app history user-service-prod
```

#### 4. Linkerd Issues
```bash
# Check Linkerd injection
kubectl get pods -n user-service-prod -o yaml | grep linkerd

# Check service mesh traffic
linkerd tap deployment/user-service -n user-service-prod

# Check Linkerd status
linkerd check
```

### Debug Commands

```bash
# Port forward for local testing
kubectl port-forward svc/user-service 8080:80 -n user-service-prod

# Check application health
curl http://localhost:8080/health

# Check metrics
curl http://localhost:8080/metrics

# View Linkerd dashboard
linkerd dashboard

# View ArgoCD dashboard
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Best Practices

### 1. Git Workflow
- Use feature branches for development
- Require pull request reviews
- Use semantic versioning for releases
- Keep commit messages clear and descriptive

### 2. CI/CD Pipeline
- Fail fast on errors
- Run tests in parallel
- Use caching for dependencies
- Implement proper secret management

### 3. Kubernetes Deployment
- Use resource limits and requests
- Implement health checks
- Use rolling updates
- Monitor resource usage

### 4. Service Mesh
- Enable mTLS for all services
- Configure proper retry policies
- Monitor service mesh metrics
- Use traffic splitting for canary deployments

### 5. Monitoring
- Set up comprehensive alerting
- Use structured logging
- Monitor business metrics
- Implement distributed tracing

## Conclusion

This GitOps workflow provides a robust, scalable, and secure way to deploy and manage microservices in a Kubernetes environment. The combination of Jenkins for CI/CD, ArgoCD for GitOps, and Linkerd for service mesh provides comprehensive automation, observability, and security for modern cloud-native applications.
