# On-prem local lab

Runs the whole GitOps stack on this machine with [kind](https://kind.sigs.k8s.io):

| Component | How it runs | URL |
|---|---|---|
| Kubernetes 1.35 | kind cluster `gitops-local` (1 node, API on 127.0.0.1 only) | |
| Image registry | `registry:3` container `kind-registry` | `localhost:5001` (in cluster: `kind-registry:5000`) |
| Ingress | ingress-nginx on host ports 80/443 | `http://*.localtest.me` |
| metrics-server | Needed by the HPA | |
| Linkerd (edge) + viz | CLI install, Gateway API CRDs | `make linkerd-dashboard` |
| Argo CD | Helm chart, no Dex/notifications | http://argocd.localtest.me |
| Jenkins | Helm chart + `jenkins/values.yaml` + `values/jenkins.yaml` | http://jenkins.localtest.me |
| user-service | Argo CD app per environment | http://user-service-dev.localtest.me/health |
| kube-prometheus-stack | Optional (`ENABLE_MONITORING=true`) | http://grafana.localtest.me |

`*.localtest.me` is public DNS that resolves to `127.0.0.1`, so no `/etc/hosts` edits are needed.

## Safety: the real cluster is never touched

- The lab uses its own kubeconfig, `on-prem/.kube/config` (gitignored). `kind` is told to write there, so
  `~/.kube/config` and its current context are left unchanged.
- Every `kubectl`, `helm` and `linkerd` call in `scripts/` passes `--kubeconfig` and `--context kind-gitops-local`
  explicitly, after `guard_local_cluster` checks that the API server is `https://127.0.0.1:*`.
- The root `Makefile` and `scripts/*.sh` also use this kubeconfig and refuse any non-local API server.
- Helm repositories and cache are kept in `on-prem/.helm`; CLIs are downloaded into `on-prem/.bin`.

To use `kubectl` yourself against the lab:

```bash
export KUBECONFIG=$PWD/on-prem/.kube/config   # only in this shell
kubectl get pods -A
```

## Quick start

```bash
cd on-prem
cp .env.example .env      # optional: GitHub token so Jenkins can push deploy commits
make up                   # tools + cluster + registry + image + all addons + Argo CD apps
make urls                 # URLs and generated passwords
make status
```

### Resources

The kind node container is capped at `KIND_NODE_CPUS=4` / `KIND_NODE_MEMORY=4g` (see `config.env`) with
`docker update`, so the lab can never starve other containers on this machine. Without the cap, the first start
(Jenkins downloading plugins while Argo CD, Linkerd and the control plane start) pushed the Docker VM to a load
average of 50+ on 8 CPUs.

The default set (dev only, no monitoring) needs about 2.5 GB. A Jenkins build pod needs up to about 1 GB more,
and staging/prod add more pods (`ENVIRONMENTS="dev staging prod"`). Raise the cap if you enable more.

```bash
make stop     # pause the lab when you are not using it (keeps all state)
make start    # resume it
```

Each component can also be installed on its own: `make cluster ingress metrics-server linkerd linkerd-viz argocd jenkins apps`.

## How the GitOps flow works locally

1. Argo CD tracks `GIT_REPO_URL` at `GIT_REVISION` (default: this repo on GitHub, `main`). It renders
   `k8s/helm/user-service` with `values.yaml` + `values-<env>.yaml`. The lab only overrides the image registry
   (`localhost:5001/user-service`) and the ingress host (see `argocd/application.yaml.tpl`).
2. Jenkins has a preconfigured `user-service` pipeline job (JCasC + Job DSL). It polls the repo every 2 minutes,
   because GitHub cannot send webhooks to a local Jenkins.
3. The pipeline builds the image with kaniko, pushes it to `kind-registry:5000`, commits the new tag to
   `values-<env>.yaml` (needs `GITHUB_USERNAME`/`GITHUB_TOKEN` in `.env`), waits for Argo CD, then smoke tests.
   The local settings come from Jenkins global variables `CI_REGISTRY`, `CI_KANIKO_EXTRA_ARGS`, `CI_ARGOCD_OPTS`
   and `CI_GIT_BRANCH` (see `values/jenkins.yaml`).
4. The Argo CD token for Jenkins is created automatically for a dedicated API-only account `jenkins`,
   which can only `get`/`sync` applications.

Argo CD deploys what is **pushed** to GitHub. Changes in your working tree are not seen until you push them. To test
from a branch, set `GIT_REVISION=<branch>` in `.env` and run `make apps` (and `make jenkins` so the job follows it).

To try the chart without Git, build an image (`make image TAG=dev-1`) and install the chart with Helm into a
scratch namespace using the lab kubeconfig.

## Common tasks

```bash
make image TAG=latest     # build + push user-service to localhost:5001
make apps                 # (re)create Argo CD applications for ENVIRONMENTS
make linkerd-dashboard    # Linkerd viz dashboard
make stop / make start    # pause / resume the lab
make down                 # delete the cluster (the registry and its images are kept)
make destroy              # delete the cluster and the registry
```

## Troubleshooting

- **Port 80/443 already in use**: set `HTTP_PORT`/`HTTPS_PORT` in `.env` and recreate the cluster
  (`make down cluster`). URLs then become `http://argocd.localtest.me:<port>`.
- **`localtest.me` does not resolve** (DNS rebinding protection on some routers): add the hosts you need to
  `/etc/hosts` pointing at `127.0.0.1`.
- **Argo CD app shows `ComparisonError` for `values-dev.yaml`**: the branch in `GIT_REVISION` does not contain the
  per-environment values files yet. Push the changes, or point `GIT_REVISION` at a branch that has them.
- **Jenkins takes a long time to start**: the first start downloads about 25 MB of update-center metadata and the
  plugins from `updates.jenkins.io`. On a flaky connection the init container retries; later starts reuse the
  persistent volume.
- **Argo CD repo-server in CrashLoopBackOff / `dial udp 10.96.0.10:53: i/o timeout`**: the chart's NetworkPolicies
  do not work with kindnet's policy enforcement, so `values/argocd.yaml` disables them (`global.networkPolicy.create: false`).
- **ingress-nginx** is retired upstream (best-effort maintenance ended in March 2026). It is fine for a local lab;
  consider Gateway API or Traefik for anything longer-lived.
