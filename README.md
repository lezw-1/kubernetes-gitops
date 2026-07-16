# Kubernetes Deployment

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each
service's Helm chart directly — no Helmfile in front of it.

## Contents

```
kubernetes-deployment/
├── apps/                 # One Helm chart per service
│   └── frontend/
├── bootstrap/             # One-time cluster bootstrap (Argo CD itself)
│   └── argocd/
│       ├── namespace.yaml # Namespace "argocd"
│       ├── values.yaml    # Argo CD Helm values (shared baseline)
│       ├── install.yaml   # Argo CD Application — self-manages its own Helm install
│       └── root-app.yaml  # Root app-of-apps Application
├── clusters/              # Per-environment service overrides
│   ├── dev/frontend.yaml
│   ├── staging/frontend.yaml
│   └── prod/frontend.yaml
└── projects/              # Argo CD control plane
    ├── app-project.yaml   # AppProject
    └── applications/      # Per-service ApplicationSet manifests
```

## Usage

### Prerequisites

- A Kubernetes cluster with `kubectl` configured
- [`helm`](https://helm.sh/) installed

### 1. Bootstrap Argo CD (one-time, per cluster)

```sh
kubectl apply -f bootstrap/argocd/namespace.yaml
```

`bootstrap/argocd/values.yaml` holds shared defaults; per-env differences are passed as
`--set` flags for this one-time install only:

```sh
helm repo add argo https://argoproj.github.io/argo-helm

# Dev/staging: shared defaults as-is
helm install argocd argo/argo-cd -n argocd \
  -f bootstrap/argocd/values.yaml

# Prod: autoscaling, resource requests, redis-ha
helm install argocd argo/argo-cd -n argocd \
  -f bootstrap/argocd/values.yaml \
  --set server.autoscaling.enabled=true \
  --set server.autoscaling.minReplicas=2 \
  --set server.autoscaling.maxReplicas=5 \
  --set server.resources.requests.cpu=250m \
  --set server.resources.requests.memory=256Mi \
  --set controller.resources.requests.cpu=500m \
  --set controller.resources.requests.memory=512Mi \
  --set repoServer.autoscaling.enabled=true \
  --set repoServer.autoscaling.minReplicas=2 \
  --set repoServer.autoscaling.maxReplicas=5 \
  --set redis-ha.enabled=true
```

Port-forward and use the auto-generated admin password, then delete it per
the [Argo CD docs](https://argo-cd.readthedocs.io/en/stable/getting_started/):

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### 2. Hand Argo CD off to itself, then apply the app-of-apps root

`bootstrap/argocd/install.yaml` is an Application that points back at the same
`argo-helm` chart and `values.yaml` used above — applying it makes Argo CD
manage its own future upgrades via GitOps instead of manual `helm upgrade`:

```sh
kubectl apply -f projects/app-project.yaml
kubectl apply -f bootstrap/argocd/install.yaml
kubectl apply -f bootstrap/argocd/root-app.yaml
```

### 3. Promoting to prod

`frontend-prod` syncs manually (`automated: false` in
`projects/applications/frontend.yaml`):

```sh
kubectl -n argocd patch application frontend-prod --type merge -p '{"operation":{"sync":{}}}'
```

## Links

- [Argo CD docs](https://argo-cd.readthedocs.io/)
- [argo-helm chart](https://github.com/argoproj/argo-helm)

## References

- `dev`/`prod` are separate long-lived branches; `staging` tracks the `dev`
  branch. The frontend app repo's CI promotes by updating the image tag in
  `clusters/<env>/frontend.yaml` on that branch (this repo's own
  [.github/workflows/validate.yaml](.github/workflows/validate.yaml) only
  lints/validates on PRs, it does not update tags).
- `projects/applications/frontend.yaml` layers `apps/frontend/values.yaml`
  with `clusters/<env>/frontend.yaml` via Argo CD's multi-source `ref: values`.
