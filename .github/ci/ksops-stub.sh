#!/usr/bin/env bash
# CI stand-in for ksops. The SOPS files in this repo encrypt metadata too,
# so CI cannot know secret names without the GPG private key — which we do
# not put in GitHub. Emit an empty KRM ResourceList so kustomize builds
# render everything except the Secrets themselves.
set -euo pipefail
cat > /dev/null || true
printf 'apiVersion: config.kubernetes.io/v1\nkind: ResourceList\nitems: []\n'
