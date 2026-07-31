#!/usr/bin/env bash
# CI stand-in for ksops. The SOPS files in this repo encrypt metadata too,
# so CI cannot know secret names without the GPG private key — which we do
# not put in GitHub. Render everything except the Secrets themselves.
#
# Handles both invocation styles used in this repo:
#  - KRM exec function (config.kubernetes.io/function annotation):
#    ResourceList arrives on stdin, must emit a ResourceList.
#  - Legacy exec plugin (XDG plugin dir): generator config path passed as
#    $1, stdin empty, plain YAML expected — emit nothing.
set -euo pipefail
input=$(cat || true)
if [[ -n "$input" ]]; then
  printf 'apiVersion: config.kubernetes.io/v1\nkind: ResourceList\nitems: []\n'
fi
