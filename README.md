# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

There are two clusters, each running its own independent Argo CD install: `local` (dev) and `remote` (staging+prod). Both are bootstrapped from the same shared manifests in `argocd/bootstrap/` (`root.yaml`, `install.yaml`) — `targetRevision` and the Application path/values-file directory are `__ENV__`/`__DIR__` placeholders in the committed files, substituted before each is applied. `argocd/local/bootstrap.sh` substitutes `__ENV__=dev`/`__DIR__=local` and applies them by hand for the local cluster; the CI pipeline (`.github/workflows/argocd.yaml`) substitutes `__ENV__=prod`/`__DIR__=remote` and applies them instead for the remote cluster. `argocd/bootstrap/root.yaml` is the root app-of-apps Application — it recursively syncs every Application manifest directly under `argocd/local/` or `argocd/remote/`, depending on which substitution was applied. Each child Application points at a Helm chart and layers a per-cluster values file from `argocd/local/values/` or `argocd/remote/values/` via Argo CD's multi-source `ref: values` pattern — nested so it stays outside the flat `*.yaml` scan each root Application does over its own directory. Both clusters' own Argo CD Helm install is layered onto from `argocd/local/values/argocd.yaml`/`argocd/remote/values/argocd.yaml` the same way.

Every Application's destination is the same in-cluster API server, since each cluster only ever manages itself — there's no cross-cluster reachability. On the remote cluster, `frontend`/`iam` get one Application per environment (`-staging`/`-prod` suffix) tracking their matching Git branch, so promotion stays independent; the platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`, `gateway`) track `prod` only and run as one shared instance, so shared infra only changes on reviewed merges. They're ordered with Argo CD `sync-wave` annotations so the shared `networking` namespace lands first. The local cluster's singletons track `dev` the same way, since local only ever has one environment.

## Components

- **App-of-apps, local (`argocd/local/`)** — one file per Application for the dev cluster, `bootstrap.sh` to drive the one-time local Argo CD install, and `values/` (including `argocd.yaml`, the local Argo CD install's own Helm values) for this cluster's Helm values overrides.
- **App-of-apps, remote (`argocd/remote/`)** — one file per Application for the staging+prod cluster, plus `values/` (including `argocd.yaml`, read directly by the CI pipeline) for this cluster's Helm values overrides.
- **Bootstrap (`argocd/bootstrap/`)** — `root.yaml`, `install.yaml`: the one-time install manifests shared by both clusters, applied with `__ENV__`/`__DIR__` substituted by `argocd/local/bootstrap.sh` (local) or `.github/workflows/argocd.yaml` (remote).
- **Frontend (`helm/apps/frontend`)** — React dashboard Helm chart: Deployment, Service, HPA, HTTPRoute.
- **IAM (`helm/apps/iam`)** — Keycloak-based authentication and token issuance: Deployment, Service, HPA, HTTPRoute, realm/client/user provisioning Job.
- **Networking platform (`helm/platform/networking`)** — shared namespace, cert-manager, Envoy Gateway controller/class, and the cluster Gateway (TLS Certificate/ClusterIssuer, health-check HTTPRoute).

## Prerequisites

- **kubectl** — pointed at the target cluster; used by `bootstrap.sh` to apply the self-management and app-of-apps manifests.
- **Helm** — used by `bootstrap.sh` to install Argo CD.

## Deployment

### Local

One-time bootstrap for the dev cluster — installs Argo CD, then hands self-management and the app-of-apps (`argocd/bootstrap/root.yaml`) over to it:

```sh
./argocd/local/bootstrap.sh
```

The remote (staging+prod) cluster is bootstrapped by `.github/workflows/argocd.yaml` instead, not this script.

### Dev

Cluster values live in `argocd/local/values/frontend.yaml`, `argocd/local/values/iam.yaml`, `argocd/local/values/networking.yaml`.

Deployment is orchestrated by Argo CD syncing the `dev` branch — every Application on the local cluster has `syncPolicy.automated` (prune + self-heal). The frontend image is built locally via `nerdctl build -t frontend:local ...` and never pulled from a registry.

The `iam` chart reads its admin/seeded-user credentials from a Secret (`iam-credentials`, default name — see `helm/apps/iam/values.yaml`'s `credentialsSecret`) that is never committed to Git. Create it once per cluster before `iam` can start:

```sh
kubectl create secret generic iam-credentials -n ai-system-dev \
  --from-literal=admin-username=<admin-username> \
  --from-literal=admin-password=<admin-password> \
  --from-literal=user1-username=<user1-username> \
  --from-literal=user1-password=<user1-password> \
  --from-literal=user2-username=<user2-username> \
  --from-literal=user2-password=<user2-password>
```

### Staging

Cluster values live in `argocd/remote/values/frontend-staging.yaml`, `argocd/remote/values/iam-staging.yaml`.

Deployment is orchestrated by Argo CD syncing the `staging` branch — sync is manual (no `syncPolicy.automated`). The frontend image tag in `argocd/remote/values/frontend-staging.yaml` is bumped by hand today (no CI wires this up yet) once the app source repo publishes a new image.

Same `iam-credentials` Secret requirement as Dev, created in the `ai-system-staging` namespace (`user1`/`user2` keys aren't needed — `provision.enabled` is `false`).

### Prod

Cluster values live in `argocd/remote/values/frontend-prod.yaml`, `argocd/remote/values/iam-prod.yaml`.

Deployment is orchestrated by Argo CD syncing the `prod` branch — sync is manual (no `syncPolicy.automated`). Promotion happens only through a human-reviewed PR from `dev` to `prod`.

Same `iam-credentials` Secret requirement as Dev, created in the `ai-system-prod` namespace (`user1`/`user2` keys aren't needed — `provision.enabled` is `false`).

## Links

- [Argo CD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery, drives every sync in this repo
- [Envoy Gateway](https://gateway.envoyproxy.io/) — Gateway API implementation backing `gateway-controller`/`gateway-class`/`gateway`
- [cert-manager](https://cert-manager.io/) — issues and renews the TLS certs used by the gateway
- [kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) — standalone repo `helm/platform/networking/` was migrated in from
