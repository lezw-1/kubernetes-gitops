# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

There are two clusters, each running its own independent Argo CD install: one for `dev`, one for `staging`+`prod`. The dev cluster is bootstrapped locally via `bootstrap/bootstrap.sh`; the staging/prod cluster is bootstrapped by the CI pipeline (`.github/workflows/bootstrap.yaml`) instead. `bootstrap/root.yaml` is the root app-of-apps Application — it recursively syncs Application manifests under `argocd/`, filtered via `directory.include` to just one cluster's subset. Which env it targets is configured inside the file (`targetRevision` + `directory.include`); default is `dev`. Each child Application points at a Helm chart in `helm/` and layers a per-environment values file from `envs/` via Argo CD's multi-source `ref: values` pattern.

Every Application's destination is the same in-cluster API server, since each cluster only ever manages itself — there's no cross-cluster reachability. `dev`/`staging`/`prod` Applications track their matching Git branch, while the cluster-wide singleton platform components track `prod` only, so shared infra only changes on reviewed merges. Platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`) run independently on both clusters and are ordered with Argo CD `sync-wave` annotations so the shared `networking` namespace lands first.

## Components

- **Bootstrap (`bootstrap/`)** — `bootstrap.sh` one-time script for the dev cluster: installs Argo CD via Helm, then hands self-management and `root.yaml` over to Argo CD. Staging/prod use the CI pipeline instead.
- **App-of-apps (`argocd/`)** — Argo CD Application manifests; one per service/environment plus the platform singletons. `root.yaml` picks up `dev.yaml`/`install.yaml` files by default; the staging/prod cluster's pipeline picks up `staging.yaml`/`prod.yaml`.
- **Frontend (`helm/apps/frontend`)** — React dashboard Helm chart: Deployment, Service, HPA, HTTPRoute.
- **Networking platform (`helm/platform/networking`)** — shared namespace, cert-manager, Envoy Gateway controller/class, and the per-environment Gateway (TLS Certificate/ClusterIssuer, health-check HTTPRoute).
- **Environment overrides (`envs/`)** — per-environment values layered onto each chart via Argo CD's multi-source `$values` ref.

## Prerequisites

- **kubectl** — pointed at the target cluster; used by `bootstrap.sh` to apply the self-management and app-of-apps manifests.
- **Helm** — used by `bootstrap.sh` to install Argo CD.

## Deployment

### Local

One-time bootstrap for the dev cluster — installs Argo CD, then hands self-management and `root.yaml` (default env: dev) over to it:

```sh
./bootstrap/bootstrap.sh
```

The staging/prod cluster is bootstrapped by `.github/workflows/bootstrap.yaml` instead, not this script.

### Dev

Env variables can be found in: `envs/dev/frontend.yaml`, `envs/dev/gateway.yaml`.

Deployment is orchestrated by Argo CD syncing the `dev` branch — the only environment with `syncPolicy.automated` (prune + self-heal). The frontend image is built locally via `nerdctl build -t frontend:local ...` and never pulled from a registry.

### Staging

Env variables can be found in: `envs/staging/frontend.yaml`, `envs/staging/gateway.yaml`.

Deployment is orchestrated by Argo CD syncing the `staging` branch — sync is manual (no `syncPolicy.automated`). `.github/workflows/deploy-frontend.yaml` bumps the frontend image tag on `workflow_dispatch`, triggered once the app source repo's CI pushes a new image.

### Prod

Env variables can be found in: `envs/prod/frontend.yaml`, `envs/prod/gateway.yaml`.

Deployment is orchestrated by Argo CD syncing the `prod` branch — sync is manual (no `syncPolicy.automated`). Promotion happens only through a human-reviewed PR from `dev` to `prod`.

## Links

- [Argo CD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery, drives every sync in this repo
- [Envoy Gateway](https://gateway.envoyproxy.io/) — Gateway API implementation backing `gateway-controller`/`gateway-class`/`gateway`
- [cert-manager](https://cert-manager.io/) — issues and renews the TLS certs used by the gateway
- [kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) — standalone repo `helm/platform/networking/` was migrated in from
