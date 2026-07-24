#!/usr/bin/env bash
# ==================================================
# One-command Argo CD bootstrap for the dev cluster (runs locally) — see
# README for the manual step-by-step. The staging and prod clusters are each
# bootstrapped by the CI pipeline instead (.github/workflows/argocd.yaml),
# which substitutes the same argocd/bootstrap/ manifests with
# ENV=staging/DIR=staging and ENV=prod/DIR=prod respectively.
# ==================================================

# Exit on error, on unset variables, and on failures inside pipelines
set -euo pipefail

# Absolute path to argocd/clusters/dev/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install.yaml/root.yaml live in argocd/bootstrap/, two levels up
BOOTSTRAP_DIR="$SCRIPT_DIR/../../bootstrap"

# Chart version pin lives in install.yaml — read it here instead of duplicating it
ARGOCD_VERSION="$(grep -m1 'targetRevision:' "$BOOTSTRAP_DIR/install.yaml" | awk '{print $2}')"

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
  -f "$SCRIPT_DIR/values/argocd.yaml" \
  -f "$SCRIPT_DIR/values/argocd-cmp.yaml"

CURRENT_STEP="hand self-management over to Argo CD"
echo "Step: $CURRENT_STEP"
sed -e 's/__ENV__/dev/g' -e 's/__DIR__/dev/g' "$BOOTSTRAP_DIR/install.yaml" | kubectl apply -f - -n argocd

CURRENT_STEP="apply the app-of-apps"
echo "Step: $CURRENT_STEP"
sed -e 's/__ENV__/dev/g' -e 's/__DIR__/dev/g' "$BOOTSTRAP_DIR/root.yaml" | kubectl apply -f - -n argocd

echo "Bootstrap complete — Argo CD is now managing itself and the app-of-apps."
