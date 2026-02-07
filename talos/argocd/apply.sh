#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/clusters/kubeconfig-talos-dell.yaml}"

echo "Building and applying ArgoCD manifests..."
kustomize build --enable-exec --enable-alpha-plugins "$SCRIPT_DIR" \
  | kubectl apply --kubeconfig "$KUBECONFIG" -f -

echo "Applying OIDC secret (server-side apply to preserve across rebuilds)..."
sops --decrypt "$SCRIPT_DIR/secrets/argocd-oidc-secret.enc.yaml" \
  | kubectl apply --kubeconfig "$KUBECONFIG" --server-side --field-manager=sops-oidc --force-conflicts -f -

echo "Done."
