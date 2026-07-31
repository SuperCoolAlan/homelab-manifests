#!/usr/bin/env bash
# Most charts/ dirs are an untracked kustomize cache (gitignored), but a few
# charts are deliberately force-added to git because the cluster cannot reach
# their repos over IPv6 (e.g. GitHub Pages hosted repos).
#
# For each helmCharts entry whose chart already has a *tracked* copy in git:
#   - force-add the currently referenced version (kustomize just pulled it)
#   - drop tracked copies of other versions
# Untracked cache-only charts are left alone.
set -euo pipefail

while IFS= read -r kfile; do
  dir=$(dirname "$kfile")
  while IFS=$'\t' read -r name version; do
    [[ -n "$name" && -n "$version" ]] || continue
    # "|| true" guards the SIGPIPE head causes under pipefail
    tracked=$(git ls-files -- "$dir/charts/$name-*" | head -1 || true)
    [[ -n "$tracked" ]] || continue

    want="$dir/charts/$name-$version"
    if [[ -d "$want" ]]; then
      git add -f "$want"
    else
      echo "::warning::$want referenced but not present after render"
    fi

    for old in "$dir/charts/$name"-*/; do
      [[ -d "$old" ]] || continue
      [[ "${old%/}" == "$want" ]] && continue
      if [[ -n "$(git ls-files -- "$old")" ]]; then
        echo "un-vendoring stale $old"
        git rm -rq -- "$old"
      fi
    done
  done < <(yq -r '.helmCharts[]? | [.name, .version] | @tsv' "$kfile")
done < <(find talos -name kustomization.yaml -not -path '*/charts/*' | sort)

git status --short -- '*/charts*' || true
