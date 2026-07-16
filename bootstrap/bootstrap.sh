#!/usr/bin/env bash
# One-command Argo CD bootstrap — see README for the manual step-by-step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Absolute path to bootstrap/
ARGOCD_VERSION="10.1.3" # Must match install.yaml's targetRevision

# 1. Create the argocd namespace
kubectl apply -f "$SCRIPT_DIR/argocd/namespace.yaml"

# 2. Add/refresh the Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

# 3. Initial install — the only step Argo CD can't do for itself
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_VERSION" \
  --namespace argocd \
  -f "$SCRIPT_DIR/argocd/values.yaml"

# 4. Hand self-management over to Argo CD
kubectl apply -f "$SCRIPT_DIR/argocd/install.yaml" -n argocd

# 5. Apply the app-of-apps — pulls in argocd/*.yaml from git
kubectl apply -f "$SCRIPT_DIR/root-app.yaml" -n argocd

echo "Bootstrap complete — Argo CD is now managing itself and the app-of-apps."
