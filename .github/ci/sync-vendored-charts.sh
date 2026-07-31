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
    # Look for tracked copies on the BASE branch, not this one: Renovate
    # deletes the old vendored chart dir in its own commit, so the PR
    # branch has nothing tracked by the time we run. (-m1 avoids SIGPIPE
    # under pipefail.)
    base_ref=${GITHUB_BASE_REF:-main}
    tracked=$(git ls-tree -r --name-only "origin/$base_ref" -- "$dir/charts/" 2>/dev/null \
      | grep -m1 "^$dir/charts/$name-" || true)
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
