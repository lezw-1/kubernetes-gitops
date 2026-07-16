# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each
service's Helm chart directly — no Helmfile in front of it.

## Contents

- `argocd/` — Argo CD Application manifests for each deployment.
- `bootstrap/` — one-time cluster bootstrap (e.g. installing Argo CD).
- `envs/` — per-environment config overrides.
- `helm/` — Helm chart sources: `apps/` (application services) and
  `platform/` (platform/cluster resources, e.g. networking).

```
kubernetes-gitops/
├── argocd/                 # Argo CD control plane — one folder per service
│   ├── frontend/           # One Application per environment
│   │   ├── dev.yaml         # Tracks the dev branch
│   │   ├── staging.yaml     # Tracks the staging branch
│   │   └── prod.yaml        # Tracks the prod branch
│   └── networking/
│       ├── namespace/       # Singleton — tracks prod
│       ├── certs-manager/   # Singleton — tracks prod
│       ├── gateway-controller/ # Singleton — tracks prod
│       ├── gateway-class/   # Singleton — tracks prod
│       └── gateway/         # One Application per environment (dev/staging/prod)
├── bootstrap/               # One-time cluster bootstrap (Argo CD itself)
│   ├── argocd/
│   │   ├── values.yaml      # Argo CD Helm values (shared baseline)
│   │   └── install.yaml     # Argo CD Application — self-manages its own Helm install
│   └── root.yaml            # Root app-of-apps Application, points at argocd/ — tracks prod
├── envs/                    # Per-environment service overrides
│   ├── dev/frontend.yaml
│   ├── dev/gateway.yaml
│   ├── staging/frontend.yaml
│   ├── staging/gateway.yaml
│   ├── prod/frontend.yaml
│   └── prod/gateway.yaml
└── helm/
    ├── apps/                # One Helm chart per application service
    │   └── frontend/        # Chart.yaml, values.yaml, templates/
    └── platform/            # One Helm chart per platform/infra service
        └── networking/
            ├── namespace/          # Singleton — creates the "networking" namespace
            ├── certs-manager/      # Singleton
            ├── gateway-controller/ # Singleton
            ├── gateway-class/      # Singleton
            └── gateway/            # Deployed once per environment (dev/staging/prod)
```

Each file in `argocd/frontend/` layers `helm/apps/frontend/values.yaml` with
`envs/<env>/frontend.yaml` via Argo CD's multi-source `ref: values`
(`frontend-dev`, `frontend-staging`, `frontend-prod`). Only `dev.yaml` has
`syncPolicy.automated` — staging and prod sync manually. `argocd/networking/gateway/*`
follows the same pattern against `helm/platform/networking/gateway/values.yaml`.

Both `bootstrap/argocd/install.yaml` and `bootstrap/root.yaml` use
`project: default` — Argo CD's built-in AppProject, no separate manifest
needed.

There is a single cluster, so it runs as the production environment:
`bootstrap/root.yaml` and the cluster-wide singleton platform components
(`namespace`, `certs-manager`, `gateway-controller`, `gateway-class`) track
the `prod` branch rather than `dev`, so only reviewed changes reach shared,
cluster-critical infra. Per-environment Applications (`argocd/frontend/*`,
`argocd/networking/gateway/*`) track their matching branch instead.

`helm/platform/networking/` was migrated in from the standalone
[kubernetes-networking](https://github.com/lezw-1/kubernetes-networking) repo
so the whole platform is one self-contained repo — one app-of-apps, one
bootstrap. `namespace`/`certs-manager`/`gateway-controller`/`gateway-class`
are cluster-wide singletons (one `install.yaml` each, `sync-wave` ordered so
the namespace lands first); `gateway` is deployed once per environment into
the shared `networking` namespace, with resource names suffixed per env
(e.g. `cluster-gateway-dev`) to avoid collisions.

## Usage

```
./bootstrap/bootstrap.sh
```

One-time cluster bootstrap: creates the `argocd` namespace, installs Argo CD
via Helm, then hands self-management and the app-of-apps over to Argo CD.
Requires `kubectl` and `helm` pointed at the target cluster.
