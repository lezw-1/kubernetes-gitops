#!/usr/bin/env bash
# ==================================================
# One-command Argo CD bootstrap — see README for the manual step-by-step.
# ==================================================

# Exit on error, on unset variables, and on failures inside pipelines
set -euo pipefail

# Absolute path to bootstrap/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This is the local, manual bootstrap for the dev cluster only — staging/prod
# are bootstrapped by the CI pipeline instead (.github/workflows/bootstrap.yaml).
# root.yaml's env is configured inside that file (default: dev).

# Chart version pin lives in install.yaml — read it here instead of duplicating it
ARGOCD_VERSION="$(grep -m1 'targetRevision:' "$SCRIPT_DIR/argocd/install.yaml" | awk '{print $2}')"

# Fires on any command that fails under set -e; all steps are safe to re-run from the top once the reported step is fixed
CURRENT_STEP=""
trap 'echo "Bootstrap failed during: $CURRENT_STEP" >&2' ERR

CURRENT_STEP="add/refresh the Argo Helm repo"
echo "Step: $CURRENT_STEP"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

CURRENT_STEP="install Argo CD via Helm"
echo "Step: $CURRENT_STEP"
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_VERSION" \
  --namespace argocd \
  --create-namespace \
  -f "$SCRIPT_DIR/argocd/values.yaml"

CURRENT_STEP="hand self-management over to Argo CD"
echo "Step: $CURRENT_STEP"
kubectl apply -f "$SCRIPT_DIR/argocd/install.yaml" -n argocd

CURRENT_STEP="apply the app-of-apps"
echo "Step: $CURRENT_STEP"
kubectl apply -f "$SCRIPT_DIR/root.yaml" -n argocd

echo "Bootstrap complete — Argo CD is now managing itself and the app-of-apps."
