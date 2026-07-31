# Torrent-store hardlink migration

**Goal:** store each media file once. qBittorrent seeds and Jellyfin serves the
same blocks; Radarr/Sonarr import via hardlink instead of copy. Reclaims the
duplicated space in the old torrent store (~977G dataset, much of it copies of
library content).

**Why it's currently impossible:** the qbt store is its own ZFS dataset
(`pool0-evac/media/nfs/v/pvc-58505e09…`, served at the legacy pool0 path) while
the library is the `ST6000NM0095-pool1/media` dataset. Hardlinks cannot cross
datasets, and cannot cross separate volume mounts inside a container either.

**Target layout** — everything inside the `ST6000NM0095-pool1/media` dataset:

```
/mnt/ST6000NM0095-pool1/media/
  film/       library (unchanged; Jellyfin + Radarr)
  tv/         library (unchanged; Jellyfin + Sonarr)
  torrents/   NEW — qbt store (torrents seed from here)
    incomplete/   qbt temp path
```

Key trick: qbt currently mounts the old store at `/downloads` with
`SavePath=/downloads/`. After staging, we remount `media` `subPath: torrents`
at the same `/downloads` path → identical paths + identical bytes → fastresume
stays valid, **no recheck, seeding never breaks**.

## Phases

### Phase 0 — dry run (read-only, no risk)
Run the staging Job with `--dry-run`: walks the store, matches files against a
size-index of `film/` + `tv/`, byte-verifies candidate matches, reports how
much would hardlink vs copy. Confirms space headroom (pool1 has ~723G free;
only the non-duplicate portion gets copied).

### Phase 1 — stage data (seeding unaffected)
Same Job without `--dry-run`. For every file under the store (skipping
`incomplete/`):
- content already in library → `link()` library file to `torrents/<same relpath>`
- unique content → copy (`.part` + rename), owner 1000:3001 via Job security context

Idempotent (skips existing same-size destinations); re-run for delta as new
torrents land. Old store is only ever read.

Job runs in the `torrent-staging` namespace (NOT Argo-managed, so app syncs
can't prune it) with its own static PVs to the two NFS paths.

### Phase 2 — cutover (minutes of qbt downtime, no recheck)
1. Scale qbt to 0.
2. Final staging pass with `--include-incomplete` (picks up `incomplete/` and
   anything that completed since the last pass).
3. Commit + sync mount changes:
   - qbittorrent: `downloads` volume → `media-library` claim, `subPath:
     torrents`, still at `/downloads`. Old store PVC no longer mounted.
   - radarr/sonarr: replace the `film`/`tv` subPath mounts and
     `/downloads-torrent` with a single full `media-library` mount at `/media`
     (root folders `/media/film`, `/media/tv` keep the same paths — no *arr DB
     surgery).
4. qbt back up → seeds resume from `/downloads` (same paths, same bytes).

### Phase 3 — app config + verify (manual, see MANUAL_SETUP.md)
- Radarr + Sonarr → Settings → Download Clients → Remote Path Mappings:
  host = qbt, remote `/downloads/`, local `/media/torrents/`.
- Confirm Settings → Media Management → "Use Hardlinks instead of Copy" = on.
- Force-recheck 2–3 torrents in qbt (should be 100%).
- Grab one test item; confirm import is a hardlink (`stat -c %i` equal in
  `/media/torrents/...` and `/media/film|tv/...`) and qbt keeps seeding it.

### Phase 4 — cleanup (after a few days' soak)
- Remove `qbittorrent-downloads` PV/PVC from `talos/qbittorrent/pvcs.yaml` and
  the media-v2 equivalents (`qbittorrent-downloads-media-v2` PV).
- Destroy dataset `ST6000NM0095-pool1/pool0-evac/media/nfs/v/pvc-58505e09…`
  (+ its evac snapshots) → frees ~977G on pool1.
- Delete the `torrent-staging` namespace.
- Optionally `jdupes`-style pass for any historical dupes elsewhere.

## Safety
- The old store is never written; pool0 disks (pulled) also still hold the
  originals — two levels of rollback.
- Byte-verification (`cmp`) before every hardlink — a wrong link would corrupt
  a seed, so no size-only shortcuts.
- Seed clocks (IPT, ~2026-08-09) unaffected: seeding continues through staging
  and only pauses for the minutes of cutover.
- `complete/` (12G legacy dir) is copied as-is; prune manually later if it's
  dead weight.
