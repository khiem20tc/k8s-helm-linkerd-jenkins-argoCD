# Rendered by scripts/addons.sh for each environment in ENVIRONMENTS.
# Same app names as argocd/applications/ so jenkins/Jenkinsfile works unchanged;
# only the image registry and ingress host are overridden for the local lab.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: user-service-__ENV__
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: __GIT_REPO_URL__
    targetRevision: __GIT_REVISION__
    path: k8s/helm/user-service
    helm:
      valueFiles:
        - values.yaml
        - values-__ENV__.yaml
      # image.tag still comes from values-__ENV__.yaml in Git
      parameters:
        - name: image.repository
          value: localhost:__REGISTRY_PORT__/user-service
        - name: ingress.hosts[0].host
          value: user-service-__ENV__.__DOMAIN__
        - name: ingress.hosts[0].paths[0].path
          value: /
        - name: ingress.hosts[0].paths[0].pathType
          value: Prefix
  destination:
    server: https://kubernetes.default.svc
    namespace: user-service-__ENV__
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        linkerd.io/inject: enabled
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
