# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

Two independent clusters, each with its own Argo CD install:

- **`local` (dev)** and **`remote` (staging+prod)** — bootstrapped from shared manifests in `argocd/bootstrap/` (`root.yaml`, `install.yaml`), with `__ENV__`/`__DIR__` placeholders substituted per cluster: `argocd/clusters/local/bootstrap.sh` for local, `.github/workflows/argocd.yaml` for remote.
- **Root app-of-apps** — `argocd/bootstrap/root.yaml` recursively syncs every Application under `argocd/clusters/local/` or `argocd/clusters/remote/`.
- **Values layering** — each child Application layers a per-cluster values file from `argocd/clusters/local/values/` or `argocd/clusters/remote/values/` via Argo CD's multi-source `ref: values` pattern (nested, so it's excluded from the root Application's flat `*.yaml` scan). Argo CD's own Helm install is layered the same way, from `values/argocd.yaml`.
- **Single destination** — every Application targets its own in-cluster API server; clusters never reach across.
- **Promotion** — on remote, `frontend`/`iam` get one Application per environment (`-staging`/`-prod`), each tracking its own Git branch, so promotion is independent.
- **Shared infra** — platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`, `gateway`) track `prod` only and run as one instance; local tracks `dev` only. `sync-wave` annotations land `networking`'s namespace first.

## Components

- **App-of-apps, local (`argocd/clusters/local/`)** — one file per Application for the dev cluster, `bootstrap.sh` to drive the one-time local Argo CD install, and `values/` for this cluster's Helm values overrides.
- **App-of-apps, remote (`argocd/clusters/remote/`)** — one file per Application for the staging+prod cluster, plus `values/` for this cluster's Helm values overrides.
- **Bootstrap (`argocd/bootstrap/`)** — `root.yaml`, `install.yaml`: the one-time install manifests shared by both clusters, applied with `__ENV__`/`__DIR__` substituted by `argocd/clusters/local/bootstrap.sh` (local) or `.github/workflows/argocd.yaml` (remote).
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
./argocd/clusters/local/bootstrap.sh
```

The remote (staging+prod) cluster is bootstrapped by `.github/workflows/argocd.yaml` instead, not this script.

### Dev

Env variables can be found in: `argocd/clusters/local/values/frontend.yaml`, `argocd/clusters/local/values/iam.yaml`, `argocd/clusters/local/values/networking.yaml`.

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

Env variables can be found in: `argocd/clusters/remote/values/frontend-staging.yaml`, `argocd/clusters/remote/values/iam-staging.yaml`.

Deployment is orchestrated by Argo CD syncing the `staging` branch — sync is manual (no `syncPolicy.automated`). The frontend image tag in `argocd/clusters/remote/values/frontend-staging.yaml` is bumped by hand today (no CI wires this up yet) once the app source repo publishes a new image.

Same `iam-credentials` Secret requirement as Dev, created in the `ai-system-staging` namespace (`user1`/`user2` keys aren't needed — `provision.enabled` is `false`).

### Prod

Env variables can be found in: `argocd/clusters/remote/values/frontend-prod.yaml`, `argocd/clusters/remote/values/iam-prod.yaml`.

Deployment is orchestrated by Argo CD syncing the `prod` branch — sync is manual (no `syncPolicy.automated`). Promotion happens only through a human-reviewed PR from `dev` to `prod`.

Same `iam-credentials` Secret requirement as Dev, created in the `ai-system-prod` namespace (`user1`/`user2` keys aren't needed — `provision.enabled` is `false`).

## Links

- [Argo CD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery, drives every sync in this repo
- [Envoy Gateway](https://gateway.envoyproxy.io/) — Gateway API implementation backing `gateway-controller`/`gateway-class`/`gateway`
- [cert-manager](https://cert-manager.io/) — issues and renews the TLS certs used by the gateway
- [kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) — standalone repo `helm/platform/networking/` was migrated in from
