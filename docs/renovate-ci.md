# Renovate + CI validation

Automated dependency updates and pre-merge validation for this repo.

## What runs

### Renovate (`.github/workflows/renovate.yml`)
Self-hosted Renovate runs weekly (Saturday 08:00 UTC, or manually via
*Run workflow*). Config lives in `renovate.json5`. It opens PRs for:

- **Helm chart versions** — every `helmCharts[].version` in a
  `kustomization.yaml` (kustomize manager).
- **Image tags** — any values file line annotated with
  `# renovate: datasource=docker depName=<org>/<image>` directly above a
  `tag:` line (see `talos/piper/values.yaml` for an example).
- **GitHub Actions** used by the workflows themselves.

Major updates get their own PR with a `major` label — read the release
notes Renovate embeds in the PR body before merging those. The servarr
charts in `talos/media-v2` are grouped into one PR for minor/patch bumps.

### Validation (`.github/workflows/validate.yml`)
Runs on every PR:

1. **Render** — `kustomize build --enable-helm --enable-alpha-plugins
   --enable-exec` for every kustomization under `talos/`. ksops is
   replaced by a stub that emits no Secrets (metadata in the SOPS files is
   encrypted, and the GPG key never goes to GitHub), so everything except
   Secrets renders. A chart that fails to template (broken values after a
   bump, removed options, etc.) fails the PR here.
2. **Re-vendor tracked charts** — most `charts/` dirs are an untracked
   kustomize cache (`**/charts/` is gitignored), but charts whose repos
   the cluster can't reach over IPv6 are force-added to git (currently
   authentik, volsync, twingate). When a PR bumps one of those versions,
   CI force-adds the new chart copy, removes the stale one, and pushes the
   commit back to the PR branch. Nothing manual to do.
3. **Schema validation** — kubeconform against upstream k8s schemas plus
   the datree CRD catalog (`-ignore-missing-schemas` for exotic CRDs).
4. **Rendered diff** — the PR's full rendered output is diffed against the
   base branch and posted to the workflow run's **Summary** page. This is
   the drift/breaking-change check: review what actually changes in the
   cluster, not just the version number in the PR diff.

## One-time setup

Renovate needs a token to open PRs. Create a fine-grained PAT (or classic
PAT with `repo` + `workflow` scope) for this repo with **Contents:
read/write** and **Pull requests: read/write**, then add it as the
repository secret `RENOVATE_TOKEN`.

## Gotchas

- kustomize's helm integration still uses helm v3 flags; CI pins helm
  3.x. If you build locally with helm 4 you'll see
  `unknown shorthand flag: 'c'` — keep a helm 3 binary around for
  kustomize builds.
- `talos/cluster-services/traefik` declares
  `apiVersions: [monitoring.coreos.com/v1]` in its helmCharts entry; the
  chart hard-fails to template without that capability (ArgoCD supplies
  it at sync time via `--helm-api-versions`, plain kustomize does not).
- The cnpg barman-cloud plugin manifest lives under a gitignored
  `charts/` path and must stay force-added (`git add -f`) when its
  version changes.
