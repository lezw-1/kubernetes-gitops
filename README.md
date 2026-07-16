# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each
service's Helm chart directly — no Helmfile in front of it.

## Contents

- `apps/` — Helm charts for application services.
- `argocd/` — Argo CD Application manifests for each deployment.
- `bootstrap/` — one-time cluster bootstrap (e.g. installing Argo CD).
- `clusters/` — per-environment config overrides.
- `platform/` — Helm charts for platform/cluster resources (e.g. networking).

```
kubernetes-gitops/
├── apps/                   # One Helm chart per application service
│   └── frontend/           # Chart.yaml, values.yaml, templates/
├── platform/               # One Helm chart per platform/infra service
│   └── networking/
│       ├── namespace/          # Singleton — creates the "networking" namespace
│       ├── certs-manager/      # Singleton
│       ├── gateway-controller/ # Singleton
│       ├── gateway-class/      # Singleton
│       └── gateway/            # Deployed once per environment (dev/local/prod)
├── argocd/                 # Argo CD control plane — one folder per service
│   ├── frontend/           # One Application per environment
│   │   ├── dev.yaml
│   │   ├── staging.yaml
│   │   └── prod.yaml
│   └── networking/
│       ├── namespace/       # Singleton
│       ├── certs-manager/   # Singleton
│       ├── gateway-controller/ # Singleton
│       ├── gateway-class/   # Singleton
│       └── gateway/         # One Application per environment (dev/local/prod)
├── bootstrap/               # One-time cluster bootstrap (Argo CD itself)
│   ├── argocd/
│   │   ├── values.yaml      # Argo CD Helm values (shared baseline)
│   │   └── install.yaml     # Argo CD Application — self-manages its own Helm install
│   └── root.yaml            # Root app-of-apps Application, points at argocd/
└── clusters/                # Per-environment service overrides
    ├── dev/frontend.yaml
    ├── dev/gateway.yaml
    ├── staging/frontend.yaml
    ├── prod/frontend.yaml
    ├── prod/gateway.yaml
    └── local/gateway.yaml
```

Each file in `argocd/frontend/` layers `apps/frontend/values.yaml` with
`clusters/<env>/frontend.yaml` via Argo CD's multi-source `ref: values`
(`frontend-dev`, `frontend-staging`, `frontend-prod`). Only `dev.yaml` has
`syncPolicy.automated` — staging and prod sync manually. `argocd/networking/gateway/*`
follows the same pattern against `platform/networking/gateway/values.yaml`.

Both `bootstrap/argocd/install.yaml` and `bootstrap/root.yaml` use
`project: default` — Argo CD's built-in AppProject, no separate manifest
needed.

`platform/networking/` was migrated in from the standalone
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
