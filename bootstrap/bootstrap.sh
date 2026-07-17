#!/usr/bin/env bash
# ==================================================
# One-command Argo CD bootstrap — see README for the manual step-by-step.
# ==================================================

# Exit on error, on unset variables, and on failures inside pipelines
set -euo pipefail

# Absolute path to bootstrap/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This is the local, manual bootstrap for the dev cluster only — staging/prod
# are bootstrapped by the CI pipeline instead (.github/workflows/bootstrap.yaml),
# which sets TARGET_ENV=prod below.

# Branch that root.yaml and argocd/install.yaml track — "dev" for the local
# dev cluster (default), or "prod" for the shared staging+prod cluster.
TARGET_ENV="${TARGET_ENV:-dev}"

# Per-env Application files root.yaml loads, plus the platform singletons.
if [ "$TARGET_ENV" = "dev" ]; then
  ROOT_INCLUDE="**/{dev,install}.yaml"
else
  ROOT_INCLUDE="**/{staging,prod,install}.yaml"
fi

# Chart version pin lives in install.yaml — read it here instead of duplicating it
ARGOCD_VERSION="$(grep -m1 'targetRevision:' "$SCRIPT_DIR/argocd/install.yaml" | awk '{print $2}')"

# Rendered copies of root.yaml/install.yaml with TARGET_ENV/ROOT_INCLUDE substituted in
RENDERED_INSTALL="$(mktemp)"
RENDERED_ROOT="$(mktemp)"
trap 'rm -f "$RENDERED_INSTALL" "$RENDERED_ROOT"' EXIT

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

CURRENT_STEP="render root.yaml and argocd/install.yaml for TARGET_ENV=$TARGET_ENV"
echo "Step: $CURRENT_STEP"
sed "s/__TARGET_ENV__/$TARGET_ENV/g" "$SCRIPT_DIR/argocd/install.yaml" > "$RENDERED_INSTALL"
sed -e "s/__TARGET_ENV__/$TARGET_ENV/g" -e "s#__ROOT_INCLUDE__#$ROOT_INCLUDE#g" "$SCRIPT_DIR/root.yaml" > "$RENDERED_ROOT"

CURRENT_STEP="hand self-management over to Argo CD"
echo "Step: $CURRENT_STEP"
kubectl apply -f "$RENDERED_INSTALL" -n argocd

CURRENT_STEP="apply the app-of-apps"
echo "Step: $CURRENT_STEP"
kubectl apply -f "$RENDERED_ROOT" -n argocd

echo "Bootstrap complete — Argo CD is now managing itself and the app-of-apps."
