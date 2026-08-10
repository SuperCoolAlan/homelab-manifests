#!/bin/bash
# Apply all SOPS-encrypted secrets to the cluster
# Run from the homelab-manifests directory

KUBECONFIG=~/.kube/clusters/homelab.yaml

for f in $(find talos -name '*.enc.yaml'); do
  ns=$(sops --decrypt "$f" 2>/dev/null | grep 'namespace:' | head -1 | awk '{print $2}')
  if [ -n "$ns" ]; then
    echo "=== $f -> $ns ==="
    kubectl --kubeconfig "$KUBECONFIG" create namespace "$ns" 2>/dev/null
    sops --decrypt "$f" | kubectl --kubeconfig "$KUBECONFIG" apply -n "$ns" -f -
  else
    echo "=== SKIP $f (no namespace found) ==="
  fi
done

echo ""
echo "Done! All secrets applied."
