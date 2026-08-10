# Filling in the VolSync restic secrets

Thirteen `ReplicationSource`s back application config volumes to Backblaze B2.
Each needs a Kubernetes Secret in its own namespace — VolSync resolves
`spec.restic.repository` as a secret name in the **same namespace as the
source**, which is why there is one per app rather than one shared cluster-wide.

Every one is committed as a **stub**: `RESTIC_REPOSITORY` is filled in and
correct, the other three keys are `REPLACE_ME`. Until they are filled, the
movers will run on schedule and fail.

## The three values

| Key | Value |
|---|---|
| `RESTIC_PASSWORD` | Any strong passphrase. **Losing it means losing the backups** — restic cannot recover a repository without it. Store it in a password manager, not only here. |
| `AWS_ACCESS_KEY_ID` | A B2 **application key ID** (`keyID`). |
| `AWS_SECRET_ACCESS_KEY` | The matching `applicationKey`. |

Two constraints on the B2 key, both of which fail in confusing ways:

- It must be a **non-master** application key. B2's S3-compatible endpoint
  rejects master credentials outright with `Malformed Access Key Id`.
- It needs **read + write + delete** on `asandov-volsync`. Delete is required
  because `pruneIntervalDays` rewrites the repository. Without it, backups keep
  succeeding and only prune fails — which is easy not to notice.

The same three values can be reused across all thirteen. Only
`RESTIC_REPOSITORY` differs, and it is already set — one prefix per source
inside the single `asandov-volsync` bucket.

## Filling them in

Interactively, one at a time:

```sh
sops talos/media-v2/secrets/sonarr-config-restic.enc.yaml
```

Or all at once, without the values touching your shell history:

```sh
read -rs -p 'restic password: ' RP; echo
read -rs -p 'B2 keyID: '        AK; echo
read -rs -p 'B2 applicationKey: ' SK; echo

for f in $(git ls-files 'talos/*/secrets/*-restic.enc.yaml'); do
  sops decrypt "$f" \
    | sed -e "s|RESTIC_PASSWORD: REPLACE_ME|RESTIC_PASSWORD: $RP|" \
          -e "s|AWS_ACCESS_KEY_ID: REPLACE_ME|AWS_ACCESS_KEY_ID: $AK|" \
          -e "s|AWS_SECRET_ACCESS_KEY: REPLACE_ME|AWS_SECRET_ACCESS_KEY: $SK|" \
    | sops encrypt --input-type yaml --output-type yaml \
        --pgp 9D032060B05603F790D340F98B60D1C1CF8E1A50 /dev/stdin > "$f.tmp" \
    && mv "$f.tmp" "$f" && echo "filled $f"
done

unset RP AK SK
```

Then confirm nothing was missed before committing:

```sh
for f in $(git ls-files 'talos/*/secrets/*-restic.enc.yaml'); do
  sops decrypt "$f" | grep -q REPLACE_ME && echo "STILL A STUB: $f"
done
```

## Verifying a backup actually ran

`repository` naming is the usual mistake — it is the **secret name**, not a URL.

```sh
kubectl get replicationsource -A
```

`LAST SYNC` populated and `DURATION` non-empty means it worked. A source that
stays blank for more than a day is failing; check the mover:

```sh
kubectl logs -n <namespace> -l app.kubernetes.io/created-by=volsync --tail=50
```

## What is covered

| Namespace | Source | Roughly |
|---|---|---|
| jellyfin | `jellyfin-config` | 3.3 GB — library DB, plugins, custom `index.html` |
| media-v2 | `sonarr-config`, `radarr-config` | 85 MB / 149 MB |
| media-v2 | `prowlarr-config` | 9 MB — indexer definitions **and their API keys** |
| media-v2 | `bazarr-config`, `jellyseerr-config` | 4 MB / 3 MB |
| media-v2 | `sabnzbd-state` | 336 KB |
| qbittorrent | `qbittorrent-config` | 9 MB — includes `.fastresume` for ~151 torrents |
| maintainerr | `maintainerr-data` | 220 KB |
| status | `gatus-data` | 1.6 MB — uptime history |
| piper | `wyoming-piper-data` | 60 MB — voice models |
| actualbudget | `actualbudget-data` | the budget ledger |
| tracearr | `tracearr-data` | 16 MB |

Deliberately **not** backed up:

- `jellyfin-cache` — regenerated on demand.
- `aldo-rootdisk` — the VM is rebuilt from `quay.io/containerdisks/ubuntu:24.04`
  plus cloud-init, which is exactly how it was recreated on 2026-08-10.
- `media-library` — 4.39 TB of media, reacquirable. The pool is a mirror; a
  second copy off-site is a separate decision, not a config-backup one.

Postgres is handled separately by CNPG's own barman-cloud plugin into
`asandov-cnpg` — see `talos/*/resources/cnpg-objectstore.yaml`.
