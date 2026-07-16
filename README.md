# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

`bootstrap/root.yaml` is the root app-of-apps Application (tracks `prod`) — it recursively syncs every Application manifest under `argocd/`. Each child Application points at a Helm chart in `helm/` and layers a per-environment values file from `envs/` via Argo CD's multi-source `ref: values` pattern.

There is a single cluster — every Application's destination is the same in-cluster API server, and environments are separated by namespace rather than by cluster. `dev`/`staging`/`prod` Applications track their matching Git branch, while the cluster-wide singleton platform components track `prod` only, so shared infra only changes on reviewed merges. Platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`) are ordered with Argo CD `sync-wave` annotations so the shared `networking` namespace lands first.

## Components

- **Bootstrap (`bootstrap/`)** — `bootstrap.sh` one-time script: installs Argo CD via Helm, then hands self-management and the app-of-apps over to Argo CD.
- **App-of-apps (`argocd/`)** — Argo CD Application manifests; one per service/environment plus the platform singletons.
- **Frontend (`helm/apps/frontend`)** — React dashboard Helm chart: Deployment, Service, HPA, HTTPRoute.
- **Networking platform (`helm/platform/networking`)** — shared namespace, cert-manager, Envoy Gateway controller/class, and the per-environment Gateway (TLS Certificate/ClusterIssuer, health-check HTTPRoute).
- **Environment overrides (`envs/`)** — per-environment values layered onto each chart via Argo CD's multi-source `$values` ref.

## Prerequisites

- **kubectl** — pointed at the target cluster; used by `bootstrap.sh` to apply the self-management and app-of-apps manifests.
- **Helm** — used by `bootstrap.sh` to install Argo CD.

## Deployment

### Local

One-time cluster bootstrap — installs Argo CD, then hands self-management and the app-of-apps over to it:

```sh
./bootstrap/bootstrap.sh
```

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
