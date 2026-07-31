#!/usr/bin/env bash
# Render every kustomization under talos/ into <outdir>/<app>.yaml.
# --enable-helm makes kustomize pull any chart version missing from the
# adjacent charts/ dir (the vendored cache the cluster relies on, since it
# cannot reach chart repos over IPv6).
set -uo pipefail

outdir=${1:?usage: render-all.sh <outdir>}
mkdir -p "$outdir"
fail=0

while IFS= read -r kfile; do
  dir=$(dirname "$kfile")
  name=${dir#talos/}
  name=${name//\//_}
  if ! kustomize build --enable-helm --enable-alpha-plugins --enable-exec \
      "$dir" > "$outdir/$name.yaml" 2> "$outdir/$name.err"; then
    echo "::error::kustomize build failed for $dir"
    sed 's/^/  /' "$outdir/$name.err"
    rm -f "$outdir/$name.yaml"
    fail=1
  fi
  rm -f "$outdir/$name.err"
done < <(find talos -name kustomization.yaml -not -path '*/charts/*' | sort)

exit $fail
