# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each
service's Helm chart directly — no Helmfile in front of it.

## Contents

```
kubernetes-gitops/
├── apps/                   # One Helm chart per service
│   └── frontend/           # Chart.yaml, values.yaml, templates/
├── argocd/                 # Argo CD control plane — one folder per service
│   └── frontend/           # One Application per environment
│       ├── dev.yaml
│       ├── staging.yaml
│       └── prod.yaml
├── bootstrap/               # One-time cluster bootstrap (Argo CD itself)
│   ├── argocd/
│   │   ├── namespace.yaml   # Namespace "argocd"
│   │   ├── values.yaml      # Argo CD Helm values (shared baseline)
│   │   └── install.yaml     # Argo CD Application — self-manages its own Helm install
│   └── root-app.yaml        # Root app-of-apps Application, points at argocd/
└── clusters/                # Per-environment service overrides
    ├── dev/frontend.yaml
    ├── staging/frontend.yaml
    └── prod/frontend.yaml
```

Each file in `argocd/frontend/` layers `apps/frontend/values.yaml` with
`clusters/<env>/frontend.yaml` via Argo CD's multi-source `ref: values`
(`frontend-dev`, `frontend-staging`, `frontend-prod`). Only `dev.yaml` has
`syncPolicy.automated` — staging and prod sync manually.

Both `bootstrap/argocd/install.yaml` and `bootstrap/root-app.yaml` use
`project: default` — Argo CD's built-in AppProject, no separate manifest
needed.

## Usage

```
./bootstrap/bootstrap.sh
```

One-time cluster bootstrap: creates the `argocd` namespace, installs Argo CD
via Helm, then hands self-management and the app-of-apps over to Argo CD.
Requires `kubectl` and `helm` pointed at the target cluster.
