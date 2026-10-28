# Backup & Recovery

Backup layering, B2 buckets, retention, current state, and the TODO
list for follow-up work after the 2026-04-21 Immich recovery.

## Layered model

Each data type has **one** local tier and **one** offsite tier. No
double-coverage; each byte gets stored once per location.

| Data type | Local tier | Offsite tier |
|---|---|---|
| Postgres DBs on CNPG (immich, authentik, cms) | none | CNPG plugin `barman-cloud.cloudnative-pg.io` → `asandov-cnpg` |
| Immich photo library (`immich-library-fast`, zfs-localpv) | none | VolSync restic (`copyMethod: Snapshot`) → `asandov-volsync` |
| Bulk/re-obtainable (downloads, media library) | none | none |
| Oracle jumphost boot volumes (jelly, monero, snowflake, signal proxy) | none | OCI policy-based boot volume backups (us-chicago-1, see schedules) |

**Never** back up a live Postgres data directory at the file level. Use
application-aware backup (barman-cloud / pg_dump) for DBs.

## B2 buckets and credentials

| Bucket | Purpose | B2 keyID | Key capability | Where the secret lives |
|---|---|---|---|---|
| `asandov-cnpg` | CNPG `ObjectStore` destination (plugin-barman-cloud) | `004b93bd8d0e47d0000000003` | scoped write | `talos/immich/secrets/b2-asandov-cnpg-credentials.enc.yaml` |
| `asandov-volsync` | VolSync restic repos, one prefix per source (`immich-photos/`) | see secret | read + write + delete (prune) | `talos/immich/secrets/immich-photos-restic.enc.yaml` |
| `asandov-truenas` | **Legacy, no longer written.** Restic repo of the photo library, 30 daily snapshots 2026-07-01 → 07-30 | `004b93bd8d0e47d0000000004` | scoped write + listAllBucketNames | not in this repo |

The original `immich-asandov` bucket + its app key `004b93bd8d0e47d0000000001`
were deleted on 2026-04-22 after the new buckets took over. No live
references remain — don't recreate it.

Restic repository password for the legacy `asandov-truenas` repo:
`truenas/secrets/b2-restic-immich-pw.enc.yaml` (SOPS, project GPG key). It is
the only way to read those July snapshots. Keep the bucket and this file until
a restore from `asandov-volsync` has been verified.

## Automated schedules (currently running)

| Task | Where | Cadence | Retention | Destination |
|---|---|---|---|---|
| CNPG WAL archiving (via plugin sidecar in `immich-postgres-1`) | k8s (`plugin-barman-cloud` sidecar) | continuous, cap 5 min (`archive_timeout`) | 30d (ObjectStore `retentionPolicy`) | `s3://asandov-cnpg/immich-postgres/wals/` |
| CNPG daily base backup (`ScheduledBackup immich-postgres-daily`, `method: plugin`) | k8s | `0 0 2 * * *` (02:00 UTC, 6-field cron) | 30d | `s3://asandov-cnpg/immich-postgres/base/` |
| CNPG daily base backup (`ScheduledBackup cms-postgres-daily`) | k8s | `0 30 2 * * *` (02:30 UTC) | 30d | `s3://asandov-cnpg/cms-postgres/` |
| CNPG daily base backup (`ScheduledBackup authentik-postgres-daily`) | k8s | `0 0 3 * * *` (03:00 UTC) | 30d | `s3://asandov-cnpg/authentik-postgres/` |
| VolSync `ReplicationSource immich-photos` (restic, snapshot clone of `immich-library-fast`) | k8s (`immich` ns) | `0 4 * * *` | 30 daily, 8 weekly, 12 monthly; prune every 14d | `s3://asandov-volsync/immich-photos/` |
| OCI boot volume backup — jelly (`jelly-weekly-mon`) | OCI volume backup policy | weekly Mon 11:00 UTC, incremental | 8d | OCI (Always Free) |
| OCI boot volume backup — monero (`monero-weekly-wed`) | OCI volume backup policy | weekly Wed 11:00 UTC, incremental | 8d | OCI (Always Free) |
| OCI boot volume backup — snowflake (`snowflake-weekly-fri`) | OCI volume backup policy | weekly Fri 11:00 UTC, incremental | 8d | OCI (Always Free) |
| OCI boot volume backup — signal proxy (`signal-weekly-sun`) | OCI volume backup policy | weekly Sun 11:00 UTC, incremental | 6d | OCI (Always Free) |

The tenancy gets 5 free volume backups at any time; this is Pay-As-You-Go, so a
6th is billed, not refused. Staggered days with 8d retention keep jelly, monero
and snowflake covered at all times; the signal proxy keeps 6d (no backup for a day
each week, it is rebuildable from `docs/oracle-wireguard-jumphost.md`) so the total
peaks at 5. A manual backup before risky changes fits on Tue/Thu/Sat/Sun only.
Don't align the days or use bronze/silver/gold (they retain 12+ backups each).

## TODOs

### Done during the 2026-04-21 → 2026-04-22 recovery + cleanup

- [x] Recover Immich DB from `immich-asandov/cnpg/` (barman PITR to ~2026-03-16 01:40 UTC, 3907 live assets)
- [x] Reset admin password via `immich-admin reset-admin-password`
- [x] Re-point ongoing CNPG backup to new `asandov-cnpg` bucket; manual base backup confirmed
- [x] Create TrueNAS cloud_backup task + seed run (finished successfully; 20.83 GiB in restic repo, 2 snapshots)
- [x] Create TrueNAS periodic ZFS snapshot tasks (immich-photos + media/nfs/v)
- [x] SOPS-encrypt restic password DR artifact
- [x] Disable Immich in-app nightly DB dumps (user handled in admin UI)
- [x] Fix CNPG `ScheduledBackup` cron to 6-field form (`0 0 2 * * *`) — was firing hourly
- [x] Delete VolSync `ReplicationSource immich-library-backup` + manifest + old secret
- [x] Drop `externalClusters` block from `cnpg-cluster.yaml`; live cluster patched to match
- [x] Delete k8s Secrets `cnpg-b2-credentials` and `volsync-restic-b2`
- [x] Delete B2 bucket `immich-asandov` and its app key `...000000001`
- [x] Wipe `/data/backups/*.sql.gz` on the `immich-library` PVC (≈ 414 MiB reclaimed; 14 pre-recovery dumps)
- [x] Resolve the 2026-03-16 WAL archiver incident — origin precedes the full-cluster tear-down and redeploy (see "Incident timeline" below). No further forensics possible since the observability stack was rebuilt along with the cluster.
- [x] Delete the zombie `cnpg-controller-manager` deployment in `cnpg-system` (plus its `cnpg-manager` SA, ClusterRole, and ClusterRoleBinding). Helm-managed `cnpg-cloudnative-pg` is now the sole operator.
- [x] Migrate Immich CNPG from in-tree `spec.backup.barmanObjectStore` to plugin-barman-cloud v0.12.0. Plugin manifest vendored at `talos/cluster-services/cnpg-operator/charts/plugin-barman-cloud/v0.12.0/manifest.yaml`. New `ObjectStore immich-postgres-store` + `spec.plugins` wired up; ScheduledBackup switched to `method: plugin`. Verified with manual backup `20260422T202035`.
- [x] Fix `immich-postgres-app` secret `username` field (`app` → `immich`) to match Cluster's `bootstrap.initdb.owner`. CNPG instance-manager was spamming reconciler errors rotating the password until the fields agreed.

## Incident timeline (2026-03-16 → 2026-04-22)

| Date (UTC) | What | Source |
|---|---|---|
| 2026-03-06 02:00 | Last Immich in-app pg_dump lands in `/data/backups` | filesystem mtimes |
| 2026-03-15 19:39 | Last successful Immich photo ingest (last new file in `/data/thumbs` + `/data/encoded-video`) | filesystem mtimes |
| 2026-03-15 19:28 | Last VolSync Restic snapshot to B2 | restic snapshot list |
| 2026-03-16 01:07 – 01:29 | **12 CNPG base backups in 22 minutes** (~2 min apart) — CNPG operator reconcile-storm or retry loop, origin never identified (logs gone) | B2 object timestamps (since deleted) |
| 2026-03-16 01:40 | Last successful WAL archive (`000000010000000700000008`). Pipeline stops. | B2 object timestamps (since deleted) |
| ~2026-03-22 | Full cluster tear-down and redeploy. CNPG operator recreated (helm, chart `cloudnative-pg-0.27.0`). Static NFS PVs hand-rebound to pre-existing TrueNAS paths. | deployment creationTimestamp |
| 2026-03-27 | `monitoring` namespace recreated (Victoria Metrics/Logs rebuilt). Pre-incident log retention lost. | namespace creationTimestamp |
| 2026-03-28 | Stray `cnpg-controller-manager` deployment appears (bare manifest install, not ArgoCD/Helm). Not cleaned up. | deployment creationTimestamp |
| 2026-04-10 20:04 | `immich-postgres-1` pod recreated with empty data dir — DB wipe event. Immich boots into `select_database_restore` maintenance mode, starts crashlooping the startup probe. | pod creationTimestamp, maintenance-status API |
| 2026-04-21 | Incident recovery: barman PITR from `immich-asandov/cnpg/` into new local PV; password reconciled; backup re-pointed at new `asandov-cnpg` bucket; TrueNAS cloud_backup stood up for photos. | this doc |
| 2026-04-22 | Cleanup: ScheduledBackup cron fixed (6-field), stale secrets + VolSync retired, `immich-asandov` bucket deleted, old pg_dumps wiped. | this doc |
| 2026-04-22 (later) | CNPG backup migrated to plugin-barman-cloud v0.12.0. `spec.backup.barmanObjectStore` removed; `ObjectStore` CR + `spec.plugins` in place. Primary restarted once to inject the sidecar. Manual backup `20260422T202035` confirmed the new path writes to `asandov-cnpg`. | this doc |

### Deferred (after this cleanup)

- [ ] Set up Authentik OIDC for Immich login (waiting on Authentik stability)
- [ ] Verify a restore from `asandov-volsync/immich-photos`, then retire `asandov-truenas` and `truenas/secrets/`
- [ ] Keep ArgoCD auto-sync **off** for `immich` — per user policy, never auto-enable

## Recovery playbooks

### CNPG Postgres (PITR from B2)

With the plugin now installed, recovery uses `externalClusters` that reference the ObjectStore indirectly via the plugin. Current manifest (`bootstrap.initdb` + `spec.plugins`) is the from-scratch-start shape; for PITR, the manifest needs a **temporary edit** to swap bootstrap + add an externalCluster that knows how to talk to the plugin.

1. Scale immich-server to 0; pause ArgoCD sync on `immich`.
2. `kubectl -n immich delete clusters.postgresql.cnpg.io immich-postgres`
3. `kubectl -n immich delete pvc -l cnpg.io/cluster=immich-postgres`
4. `kubectl patch pv immich-postgres-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'`
5. Edit `talos/immich/resources/cnpg-cluster.yaml`:
   - Replace `bootstrap.initdb` with `bootstrap.recovery.source: immich-postgres-b2`.
   - Add an `externalClusters` entry named `immich-postgres-b2` — same shape as the current `spec.plugins`, but under `externalClusters.*.plugin` with `parameters.barmanObjectName: immich-postgres-store` (the already-deployed ObjectStore CR). Ensure the ObjectStore is still in-cluster first; it doesn't need replacing.
   - **Comment out** the `spec.plugins` block for the duration. CNPG refuses to start if the ongoing-archive destination already contains WAL from the cluster being recovered — see "Pitfalls" below. (Plugin semantics are the same as the old in-tree "Expected empty archive" check.)
6. `kubectl apply -f talos/immich/resources/cnpg-cluster.yaml` (Argo paused).
7. Wait for `status.phase` = `Cluster in healthy state` (≈90s + plugin sidecar first-pull, see Pitfall #8 if the node hasn't pulled the sidecar image).
8. Restore the `spec.plugins` block (unchanged from pre-recovery); `kubectl apply` again. Then remove `bootstrap.recovery` and `externalClusters` by JSON patch (CNPG won't let `kubectl apply` replace them cleanly): `kubectl patch cluster immich-postgres --type=json -p='[{"op":"remove","path":"/spec/bootstrap/recovery"},{"op":"add","path":"/spec/bootstrap/initdb","value":{…}},{"op":"remove","path":"/spec/externalClusters"}]'`.
9. `ALTER USER immich WITH PASSWORD '<secret>';` — CNPG restores the OLD password hash from the backup; the k8s Secret was rotated post-init, so the two drift. Apply the current secret value into `pg_authid`.
10. Also verify `immich-postgres-app` secret `username: immich` (see Pitfall #7).
11. Scale immich-server back to 1; reset the Immich admin password via `immich-admin reset-admin-password` if needed.
12. Commit the final manifest state to `main`.

### Legacy photo snapshots (restic, `asandov-truenas`)

Install restic anywhere and point it at
`s3:s3.us-west-004.backblazeb2.com/asandov-truenas/immich-photos`, with B2 keyID
`...000000004` and the restic password from
`truenas/secrets/b2-restic-immich-pw.enc.yaml`.

## Pitfalls hit during the 2026-04-21 recovery

1. **"Expected empty archive"**: CNPG 1.28 refuses `bootstrap.recovery` when `spec.backup.barmanObjectStore` points at a non-empty destination, even if that's the same path we're recovering from. Fix = comment the `backup:` block during recovery; re-enable afterward (at a different bucket).
2. **Password drift after PITR**: CNPG restores the Postgres role password from the backup. The k8s Secret may have been rotated since. Reconcile by `ALTER USER … WITH PASSWORD` from the current secret value.
3. **B2 `ListBuckets` 403 "not entitled"**: rclone's S3 backend calls `ListBuckets` before it writes. A bucket-scoped B2 app key must have the **"Allow List All Bucket Names"** capability ticked, or task creation fails.
4. **Interactive `immich-admin` CLI**: `reset-admin-password` prompts for a new password. Piping a single word via `<<<'y'` sets the literal password to that word — pipe the real desired password or a strong random one.
5. **CNPG `ScheduledBackup` uses 6-field cron** (`sec min hour dom mon dow`), not the 5-field standard. A 5-field `0 2 * * *` gets parsed as `sec=0 min=2 hour=*` → fires every hour at `HH:02`. Caught this 2026-04-22 after the 2026-04-21 recovery: 9 unnecessary base backups in 9 h. Same bug caused the "12 base backups in 22 min" on 2026-03-16 that we initially flagged as a crash loop. Use e.g. `"0 0 2 * * *"` for daily 02:00 UTC.
6. **CNPG app secret `username` must match `bootstrap.initdb.owner`**. CNPG auto-generates `<cluster>-app` with `username: app` by default. If your Cluster spec sets a custom owner (e.g. `immich`), you MUST also set `stringData.username: immich` in the secret. Otherwise the instance-manager spams `"while updating database owner password: wrong username 'app' in secret, expected 'immich'"` every reconcile and cannot rotate the role password. Fix: `kubectl -n <ns> patch secret <cluster>-app -p '{"data":{"username":"<base64>"}}'`.
7. **First plugin backup restart pulls a ~100 MB sidecar image**. Switching a Cluster to `spec.plugins.[].name=barman-cloud.cloudnative-pg.io` makes CNPG restart the primary to inject a `plugin-barman-cloud` sidecar (image `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:vX.Y.Z`, ~100 MiB). First-time pull added ~40s to the pod start in our case. Shows as "Primary instance is being restarted without a switchover" with the pod in `PodInitializing` — this is normal. Don't panic-delete the cluster.
