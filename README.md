# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each service's Helm chart directly — no Helmfile in front of it.

## Architecture

Three independent clusters, each with its own Argo CD install:

- **`dev`**, **`staging`**, **`prod`** — bootstrapped from shared manifests in `argocd/bootstrap/` (`root.yaml`, `install.yaml`), with `__ENV__`/`__DIR__` placeholders substituted per cluster: `argocd/clusters/dev/bootstrap.sh` for dev, `.github/workflows/argocd.yaml` for staging and prod.
- **Root app-of-apps** — `argocd/bootstrap/root.yaml` recursively syncs every Application under `argocd/clusters/dev/`, `argocd/clusters/staging/`, or `argocd/clusters/prod/`.
- **Values layering** — each child Application layers a per-cluster values file from that cluster's `argocd/clusters/<env>/values/` via Argo CD's multi-source `ref: values` pattern (nested, so it's excluded from the root Application's flat `*.yaml` scan). Argo CD's own Helm install is layered the same way, from `values/argocd.yaml`. Exception: `iam` on dev and `networking-gateway` on every cluster have SOPS-encrypted values files, so they use the `sops-helm` Config Management Plugin (single source at repo root) instead — native Helm value files can't decrypt SOPS.
- **Single destination** — every Application targets its own in-cluster API server; clusters never reach across.
- **Promotion** — `frontend`/`iam` get one Application per environment (`-staging`/`-prod` on their respective clusters), each tracking its own Git branch, so promotion is independent.
- **Per-cluster infra** — platform singletons (`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`, `gateway`) run once per cluster, each tracking that cluster's own branch (`dev`, `staging`, or `prod`). `sync-wave` annotations land `networking`'s namespace first.

## Components

- **App-of-apps, dev (`argocd/clusters/dev/`)** — one file per Application for the dev cluster, `bootstrap.sh` to drive the one-time dev Argo CD install, and `values/` for this cluster's Helm values overrides.
- **App-of-apps, staging (`argocd/clusters/staging/`)** — one file per Application for the staging cluster, plus `values/` for this cluster's Helm values overrides.
- **App-of-apps, prod (`argocd/clusters/prod/`)** — one file per Application for the prod cluster, plus `values/` for this cluster's Helm values overrides.
- **Bootstrap (`argocd/bootstrap/`)** — `root.yaml`, `install.yaml`: the one-time install manifests shared by all three clusters, applied with `__ENV__`/`__DIR__` substituted by `argocd/clusters/dev/bootstrap.sh` (dev) or `.github/workflows/argocd.yaml` (staging, prod).
- **Frontend (`helm/apps/frontend`)** — React dashboard Helm chart: Deployment, Service, HPA, HTTPRoute.
- **IAM (`helm/apps/iam`)** — Keycloak-based authentication and token issuance: Deployment, Service, HPA, HTTPRoute, plus realm/client/user Secrets and a provisioning Job, gated by `secretsProvisioning.enabled` (on for dev, off for staging/prod). On dev, rendered via the `sops-helm` CMP so credentials stay SOPS-encrypted in Git.
- **Networking platform (`helm/platform/networking`)** — shared namespace, cert-manager, Envoy Gateway controller/class, and the cluster Gateway (TLS Certificate/ClusterIssuer, health-check HTTPRoute).

## Prerequisites

- **kubectl** — pointed at the target cluster; used by `bootstrap.sh` to apply the self-management and app-of-apps manifests.
- **Helm** — used by `bootstrap.sh` to install Argo CD.

## Deployment

### Local

One-time bootstrap for the dev cluster (runs locally) — installs Argo CD, then hands self-management and the app-of-apps (`argocd/bootstrap/root.yaml`) over to it:

```sh
./argocd/clusters/dev/bootstrap.sh
```

The staging and prod clusters are each bootstrapped by `.github/workflows/argocd.yaml` instead, not this script — staging on push to the `staging` branch, prod on push to `prod`.

### Dev

Env variables can be found in: `argocd/clusters/dev/values/frontend.yaml`, `argocd/clusters/dev/values/iam-secrets.enc.yaml`, `argocd/clusters/dev/values/networking.yaml`.

Deployment is orchestrated by Argo CD syncing the `dev` branch — every Application on the dev cluster has `syncPolicy.automated` (prune + self-heal). The frontend image is built locally via `nerdctl build -t frontend:local ...` and never pulled from a registry.

On dev, `secretsProvisioning.enabled` is `true`, so the `iam` chart creates `admin-credentials` itself (from `argocd/clusters/dev/values/iam-secrets.enc.yaml`'s `secrets.admin`) and a Job seeds the `ai-system` realm/clients/users on every install/upgrade — no manual Secret needed.

`argocd/clusters/dev/values/iam-secrets.enc.yaml` is SOPS-encrypted with the age recipient in `.sops.yaml` — only its `username`/`password` leaf fields; the rest (image, subpath, realm/client names, roles, etc.) stays plaintext so it's readable in Git diffs. Argo CD's repo server decrypts it via the `sops-helm` Config Management Plugin (`argocd/clusters/dev/values/argocd-cmp.yaml`), which needs the matching age **private** key as a `sops-age-key` Secret in the `argocd` namespace — never committed to Git:

```sh
kubectl create secret generic sops-age-key -n argocd \
  --from-file=key.txt="$HOME/Library/Application Support/sops/age/keys.txt"
```

### Staging

Its own independent remote cluster and Argo CD install — no longer shared with prod.

Env variables can be found in: `argocd/clusters/staging/values/frontend.enc.yaml`, `argocd/clusters/staging/values/iam.enc.yaml`.

Deployment is orchestrated by Argo CD syncing the `staging` branch — sync is manual (no `syncPolicy.automated`). The frontend image tag in `argocd/clusters/staging/values/frontend.enc.yaml` is bumped by hand today (no CI wires this up yet) once the app source repo publishes a new image.

Like dev, `secretsProvisioning.enabled` is `true`, so the `iam` chart creates `admin-credentials` itself (from `argocd/clusters/staging/values/iam.enc.yaml`'s `secrets.admin`) and a Job seeds the `ai-system` realm/clients/users on every install/upgrade — no manual Secret needed. `argocd/clusters/staging/values/iam.enc.yaml` is SOPS-encrypted the same way as `frontend.enc.yaml` below — only its `username`/`password`/`email` leaf fields.

`argocd/clusters/staging/values/networking.enc.yaml` (the cluster Gateway's `domain`/`email`) is SOPS-encrypted the same way — see the Dev section above, but under staging's own age key (`.sops.yaml`'s `argocd/clusters/staging/` rule, distinct from dev's and prod's). Argo CD's repo server on the staging cluster decrypts it via the `sops-helm` CMP (`argocd/clusters/staging/values/argocd-cmp.yaml`), which needs the matching age **private** key as a `sops-age-key` Secret in the `argocd` namespace — never committed to Git:

```sh
kubectl create secret generic sops-age-key -n argocd \
  --from-file=key.txt="$HOME/Library/Application Support/sops/age/keys.txt"
```

If the Secret already exists, overwrite it instead:

```sh
kubectl create secret generic sops-age-key -n argocd \
  --from-file=key.txt="$HOME/Library/Application Support/sops/age/keys.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Prod

Env variables can be found in: `argocd/clusters/prod/values/frontend.yaml`, `argocd/clusters/prod/values/iam.yaml`.

Deployment is orchestrated by Argo CD syncing the `prod` branch — sync is manual (no `syncPolicy.automated`). Promotion happens only through a human-reviewed PR from `dev` to `prod`.

Same `admin-credentials` Secret requirement as Dev, created in the `ai-system-prod` namespace. Uses the same `sops-age-key` setup as Staging above, under prod's own age key (`.sops.yaml`'s `argocd/clusters/prod/` rule).

## Links

- [Argo CD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery, drives every sync in this repo
- [Envoy Gateway](https://gateway.envoyproxy.io/) — Gateway API implementation backing `gateway-controller`/`gateway-class`/`gateway`
- [cert-manager](https://cert-manager.io/) — issues and renews the TLS certs used by the gateway
- [kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) — standalone repo `helm/platform/networking/` was migrated in from
