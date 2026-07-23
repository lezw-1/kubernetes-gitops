# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

Two independent clusters, each with its own Argo CD install:

- **`local` (dev)** and **`remote` (staging+prod)** — bootstrapped from shared manifests in `argocd/bootstrap/` (`root.yaml`, `install.yaml`), with `__ENV__`/`__DIR__` placeholders substituted per cluster: `argocd/clusters/local/bootstrap.sh` for local, `.github/workflows/argocd.yaml` for remote.
- **Root app-of-apps** — `argocd/bootstrap/root.yaml` recursively syncs every Application under `argocd/clusters/local/` or `argocd/clusters/remote/`.
- **Values layering** — each child Application layers a per-cluster values file from `argocd/clusters/local/values/` or `argocd/clusters/remote/values/` via Argo CD's multi-source `ref: values` pattern (nested, so it's excluded from the root Application's flat `*.yaml` scan). Argo CD's own Helm install is layered the same way, from `values/argocd.yaml`. Exception: `iam` on local and `networking-gateway` on remote have SOPS-encrypted values files, so they use the `sops-helm` Config Management Plugin (single source at repo root) instead — native Helm value files can't decrypt SOPS.
- **Single destination** — every Application targets its own in-cluster API server; clusters never reach across.
- **Promotion** — on remote, `frontend`/`iam` get one Application per environment (`-staging`/`-prod`), each tracking its own Git branch, so promotion is independent.
- **Shared infra** — platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`, `gateway`) track `prod` only and run as one instance; local tracks `dev` only. `sync-wave` annotations land `networking`'s namespace first.

## Components

- **App-of-apps, local (`argocd/clusters/local/`)** — one file per Application for the dev cluster, `bootstrap.sh` to drive the one-time local Argo CD install, and `values/` for this cluster's Helm values overrides.
- **App-of-apps, remote (`argocd/clusters/remote/`)** — one file per Application for the staging+prod cluster, plus `values/` for this cluster's Helm values overrides.
- **Bootstrap (`argocd/bootstrap/`)** — `root.yaml`, `install.yaml`: the one-time install manifests shared by both clusters, applied with `__ENV__`/`__DIR__` substituted by `argocd/clusters/local/bootstrap.sh` (local) or `.github/workflows/argocd.yaml` (remote).
- **Frontend (`helm/apps/frontend`)** — React dashboard Helm chart: Deployment, Service, HPA, HTTPRoute.
- **IAM (`helm/apps/iam`)** — Keycloak-based authentication and token issuance: Deployment, Service, HPA, HTTPRoute, plus realm/client/user Secrets and a provisioning Job, gated by `secretsProvisioning.enabled` (on for local, off for staging/prod). On local, rendered via the `sops-helm` CMP so credentials stay SOPS-encrypted in Git.
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

Env variables can be found in: `argocd/clusters/local/values/frontend.yaml`, `argocd/clusters/local/values/iam-secrets.enc.yaml`, `argocd/clusters/local/values/networking.yaml`.

Deployment is orchestrated by Argo CD syncing the `dev` branch — every Application on the local cluster has `syncPolicy.automated` (prune + self-heal). The frontend image is built locally via `nerdctl build -t frontend:local ...` and never pulled from a registry.

On local, `secretsProvisioning.enabled` is `true`, so the `iam` chart creates `admin-credentials` itself (from `argocd/clusters/local/values/iam-secrets.enc.yaml`'s `secrets.admin`) and a Job seeds the `ai-system` realm/clients/users on every install/upgrade — no manual Secret needed.

`argocd/clusters/local/values/iam-secrets.enc.yaml` is SOPS-encrypted with the age recipient in `.sops.yaml` — only its `username`/`password` leaf fields; the rest (image, subpath, realm/client names, roles, etc.) stays plaintext so it's readable in Git diffs. Argo CD's repo server decrypts it via the `sops-helm` Config Management Plugin (`argocd/clusters/local/values/argocd-cmp.yaml`), which needs the matching age **private** key as a `sops-age-key` Secret in the `argocd` namespace — never committed to Git:

```sh
kubectl create secret generic sops-age-key -n argocd \
  --from-file=key.txt="$HOME/Library/Application Support/sops/age/keys.txt"
```

### Staging

Env variables can be found in: `argocd/clusters/remote/values/frontend-staging.yaml`, `argocd/clusters/remote/values/iam-staging.yaml`.

Deployment is orchestrated by Argo CD syncing the `staging` branch — sync is manual (no `syncPolicy.automated`). The frontend image tag in `argocd/clusters/remote/values/frontend-staging.yaml` is bumped by hand today (no CI wires this up yet) once the app source repo publishes a new image.

Same `admin-credentials` Secret requirement as Dev, created in the `ai-system-staging` namespace.
<<<<<<< HEAD

`argocd/clusters/remote/values/networking.enc.yaml` (the shared cluster Gateway's `domain`/`email`) is SOPS-encrypted the same way — see the Dev section above. Argo CD's repo server on the remote cluster decrypts it via the `sops-helm` CMP (`argocd/clusters/remote/values/argocd-cmp.yaml`), which needs the matching age **private** key as a `sops-age-key` Secret in the `argocd` namespace — never committed to Git:

```sh
kubectl create secret generic sops-age-key -n argocd \
  --from-file=key.txt="$HOME/Library/Application Support/sops/age/keys.txt"
```

This is a one-time setup shared with Prod below (one Argo CD install for both).
=======
>>>>>>> 5d3d3aee5a40fd57ebb851252fd6cf36c3e6f894

### Prod

Env variables can be found in: `argocd/clusters/remote/values/frontend-prod.yaml`, `argocd/clusters/remote/values/iam-prod.yaml`.

Deployment is orchestrated by Argo CD syncing the `prod` branch — sync is manual (no `syncPolicy.automated`). Promotion happens only through a human-reviewed PR from `dev` to `prod`.

Same `admin-credentials` Secret requirement as Dev, created in the `ai-system-prod` namespace.

## Links

- [Argo CD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery, drives every sync in this repo
- [Envoy Gateway](https://gateway.envoyproxy.io/) — Gateway API implementation backing `gateway-controller`/`gateway-class`/`gateway`
- [cert-manager](https://cert-manager.io/) — issues and renews the TLS certs used by the gateway
- [kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) — standalone repo `helm/platform/networking/` was migrated in from
