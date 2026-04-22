# Backup & Recovery

Backup layering, B2 buckets, retention, current state, and the TODO
list for follow-up work after the 2026-04-21 Immich recovery.

## Layered model

Each data type has **one** local tier and **one** offsite tier. No
double-coverage; each byte gets stored once per location.

| Data type | Local tier | Offsite tier |
|---|---|---|
| Postgres DBs on CNPG (k8s) | *(none — PV is on local NVMe, not ZFS)* | CNPG `barman-cloud` → `asandov-cnpg` |
| Postgres DB on TrueNAS (Authentik, future) | `pg_dump` cron (local, short retention) | `pg_dump` pushed to `asandov-truenas` (separate prefix) |
| NFS-backed files (photos, *arr configs, etc.) | TrueNAS periodic ZFS snapshots | TrueNAS `cloud_backup` (restic) → `asandov-truenas` |
| Bulk/re-obtainable (downloads, media library) | none | none |

**Never** back up a live Postgres data directory at the file level. Use
application-aware backup (barman-cloud / pg_dump) for DBs.

## B2 buckets and credentials

| Bucket | Purpose | B2 keyID | Key capability | Where the secret lives |
|---|---|---|---|---|
| `asandov-cnpg` | CNPG barman destination | `004b93bd8d0e47d0000000003` | scoped write | `talos/immich/secrets/b2-asandov-cnpg-credentials.enc.yaml` |
| `asandov-truenas` | TrueNAS cloud_backup + cloud_sync destination | `004b93bd8d0e47d0000000004` | scoped write + listAllBucketNames | TrueNAS cred id=2 (`b2-asandov-truenas-s3`, S3-compat type) |

The original `immich-asandov` bucket + its app key `004b93bd8d0e47d0000000001`
were deleted on 2026-04-22 after the new buckets took over. No live
references remain — don't recreate it.

Restic repository password for the TrueNAS cloud_backup:
`truenas/secrets/b2-restic-immich-pw.enc.yaml` (SOPS, project GPG key).
**Required** to restore from `asandov-truenas` — if TrueNAS is lost, this
file is the only way back.

## Automated schedules (currently running)

| Task | Where | Cadence | Retention | Destination |
|---|---|---|---|---|
| CNPG WAL archiving (`immich-postgres`) | k8s (CNPG instance) | continuous, cap 5 min (`archive_timeout`) | 30d | `s3://asandov-cnpg/immich-postgres/wals/` |
| CNPG daily base backup (`ScheduledBackup immich-postgres-daily`) | k8s | `0 2 * * *` (02:00 UTC) | 30d | `s3://asandov-cnpg/immich-postgres/base/` |
| TrueNAS ZFS snapshot — `immich-photos` (task id=1, recursive) | TrueNAS `pool.snapshottask` | every 6h | 30d | pool-local only |
| TrueNAS ZFS snapshot — `media/nfs/v` (task id=2, recursive + exclude `pvc-58505e09-…`) | TrueNAS `pool.snapshottask` | every 6h | 30d | pool-local only |
| TrueNAS cloud_backup — `immich-photos/v1` (task id=1, restic, via S3-compat cred id=2) | TrueNAS `cloud_backup` | `0 3 * * *` (03:00 UTC) | `keep_last=30` | `s3://asandov-truenas/immich-photos/` |

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

### Deferred (after this cleanup)

- [ ] Set up Authentik OIDC for Immich login (waiting on Authentik stability)
- [ ] Migrate Authentik postgres to its own dedicated TrueNAS dataset + pg_dump→B2 cron
- [ ] Migrate CNPG `Cluster` spec away from native `barmanObjectStore` (deprecated in CNPG 1.29) to the Barman Cloud Plugin
- [ ] Democratic-csi split: two helm releases with separate parent datasets (configs vs bulk) so new PVCs auto-partition
- [ ] Keep ArgoCD auto-sync **off** for `immich` — per user policy, never auto-enable

## Recovery playbooks

### CNPG Postgres (PITR from B2)

1. Scale immich-server to 0; pause ArgoCD sync on `immich`.
2. `kubectl -n immich delete clusters.postgresql.cnpg.io immich-postgres`
3. `kubectl -n immich delete pvc -l cnpg.io/cluster=immich-postgres`
4. `kubectl patch pv immich-postgres-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'`
5. Edit `talos/immich/resources/cnpg-cluster.yaml`:
   - Replace `bootstrap.initdb` with `bootstrap.recovery.source: immich-postgres-b2`.
   - Add an `externalClusters` entry named `immich-postgres-b2` pointing at `s3://asandov-cnpg/` with `serverName: immich-postgres` and `cnpg-b2-asandov-credentials` as the secret ref.
   - **Comment out** the `backup:` block. CNPG refuses to start if the ongoing-backup destination already contains WAL from the cluster being recovered — see "Pitfalls" below.
6. `kubectl apply -f talos/immich/resources/cnpg-cluster.yaml` (Argo paused).
7. Wait for `status.phase` = `Cluster in healthy state` (≈90s).
8. Re-enable the `backup:` block (unchanged — it already points at `asandov-cnpg`); `kubectl apply` again. Then remove `bootstrap.recovery` and `externalClusters` by JSON patch (CNPG won't let `kubectl apply` replace them cleanly): `kubectl patch cluster immich-postgres --type=json -p='[{"op":"remove","path":"/spec/bootstrap/recovery"},{"op":"add","path":"/spec/bootstrap/initdb","value":{…}},{"op":"remove","path":"/spec/externalClusters"}]'`.
9. `ALTER USER immich WITH PASSWORD '<secret>';` — CNPG restores the OLD password hash from barman; the k8s Secret was rotated post-init, so the two drift. Apply the current secret value into `pg_authid`.
10. Scale immich-server back to 1; reset the Immich admin password via `immich-admin reset-admin-password` if needed.
11. Commit the final manifest state to `main`.

### TrueNAS ZFS rollback (same pool)

```bash
# Read-only browse of snapshot
ls /mnt/<pool>/<dataset>/.zfs/snapshot/<snap-name>/

# Destructive rollback (DISCARDS all changes since the snapshot)
zfs rollback -r <pool>/<dataset>@<snap-name>
```

### TrueNAS cloud_backup (restic) restore from B2

1. Need the restic password from `truenas/secrets/b2-restic-immich-pw.enc.yaml`.
2. `midclt call cloud_backup.list_snapshots <task-id>` to enumerate snapshots.
3. `midclt call cloud_backup.restore <task-id> <snapshot-id> <subfolder> <destination-path>`.
4. If TrueNAS itself is lost, install restic on any machine and point at
   `s3:s3.us-west-004.backblazeb2.com/asandov-truenas/immich-photos` using
   B2 keyID `...000000004` + the SOPS-stored restic password.

## Pitfalls hit during the 2026-04-21 recovery

1. **"Expected empty archive"**: CNPG 1.28 refuses `bootstrap.recovery` when `spec.backup.barmanObjectStore` points at a non-empty destination, even if that's the same path we're recovering from. Fix = comment the `backup:` block during recovery; re-enable afterward (at a different bucket).
2. **Password drift after PITR**: CNPG restores the Postgres role password from the backup. The k8s Secret may have been rotated since. Reconcile by `ALTER USER … WITH PASSWORD` from the current secret value.
3. **B2 `ListBuckets` 403 "not entitled"**: rclone S3 backend calls `ListBuckets` during TrueNAS task creation. A bucket-scoped B2 app key must have the **"Allow List All Bucket Names"** capability ticked, or task creation fails.
4. **TrueNAS cloud_backup and B2**: `cloud_backup` (restic-based) does *not* support the native B2 rclone backend (`NotImplementedError`). Use the **S3-compatible endpoint** (`https://s3.us-west-<region>.backblazeb2.com`) with provider type `S3` instead. Credential region: `us-west-004`.
5. **Interactive `immich-admin` CLI**: `reset-admin-password` prompts for a new password. Piping a single word via `<<<'y'` sets the literal password to that word — pipe the real desired password or a strong random one.
6. **CNPG `ScheduledBackup` uses 6-field cron** (`sec min hour dom mon dow`), not the 5-field standard. A 5-field `0 2 * * *` gets parsed as `sec=0 min=2 hour=*` → fires every hour at `HH:02`. Caught this 2026-04-22 after the 2026-04-21 recovery: 9 unnecessary base backups in 9 h. Same bug caused the "12 base backups in 22 min" on 2026-03-16 that we initially flagged as a crash loop. Use e.g. `"0 0 2 * * *"` for daily 02:00 UTC.
