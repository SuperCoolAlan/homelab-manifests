# jellyfin — staged, not yet deployed

This directory is **inert**. The `talos-apps` ApplicationSet uses an explicit
path allowlist (`talos/argocd/resources/applicationset.yaml`) and
`talos/jellyfin` is deliberately absent from it, so no Argo Application exists
and nothing here is applied.

**To go live**, add one line to the ApplicationSet generator:

```yaml
          # Jellyfin (media server, GPU transcode)
          - path: talos/jellyfin
```

## Do not enable before Phase 4

`media-pv.yaml` points at `/var/mnt/media`, which does not exist until
`ST6000NM0095-pool1` is imported onto ramhaus (see `PHASE4-RUNBOOK.md`).
Enabling early leaves the pod Pending on an unbindable PV.

## Prerequisites

| | Status |
|---|---|
| nvidia RuntimeClass + device plugin | ✅ `talos/cluster-services/nvidia-device-plugin` |
| `media` pool imported at `/var/mnt/media` | ⬜ Phase 4 |
| `/config` copied off TrueNAS | ⬜ see below |

## Config migration

Jellyfin on TrueNAS (app `jellyfin`, image `jellyfin/jellyfin:10.11.5`, currently
**CRASHED** because the GPU left that box) mounts:

| TrueNAS source | Container path | Handled here by |
|---|---|---|
| `/mnt/dual_hdd/app_configs/jellyfin` | `/config` | `jellyfin-config` PVC — **must be copied** |
| `/mnt/Test Stripe/jellyfin-cache/data-cache` | `/cache` | `jellyfin-cache` PVC — 63 MB, regenerable, starts empty |
| `/mnt/transcode-ram` | `/config/transcodes`, `/cache/transcodes` | tmpfs `emptyDir` (was a RAM disk there too) |
| `/mnt/ST6000NM0095-pool1/media` | `/mnt/media` | `media-library` PV |

`/config` holds the library database, metadata and watch states — the part worth
preserving. `dual_hdd` stays on TrueNAS after the swap, so this copy can happen
before or after Phase 4, over NFS, using the same Job pattern as the other
migrations. Check file ownership across the WHOLE tree first, not a sample.

The custom `index.html` web mod lives inside `app_configs/jellyfin`, so it
travels with `/config` automatically.
