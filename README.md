# Kubernetes GitOps

GitOps repo: Argo CD watches this repo (app-of-apps) and syncs each
service's Helm chart directly — no Helmfile in front of it.

## Contents

```
kubernetes-gitops/
├── apps/                   # One Helm chart per service
│   └── frontend/           # Chart.yaml, values.yaml, templates/
├── argocd/                 # Argo CD control plane — ApplicationSet per service
│   └── frontend.yaml
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

`argocd/frontend.yaml` layers `apps/frontend/values.yaml` with
`clusters/<env>/frontend.yaml` via Argo CD's multi-source `ref: values`,
generating one Application per environment (`frontend-dev`,
`frontend-staging`, `frontend-prod`).

Both `bootstrap/argocd/install.yaml` and `bootstrap/root-app.yaml` use
`project: default` — Argo CD's built-in AppProject, no separate manifest
needed.
