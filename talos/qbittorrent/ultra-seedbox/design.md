# One-month seedbox: ratio push + handoff home

**Goal:** raise the private-tracker ratio with a rented seedbox for exactly one
billing month, then bring every torrent that hasn't met the tracker's seeding
rule back to home qBittorrent and seed it until it has. Nothing gets
hit-and-run, and the seedbox never renews.

**Why a seedbox:** home qbt is connectable (WireGuard via Windscribe, port
forwarded), but it uploads almost nothing. The swarms it seeds are saturated
with seeders, and Starlink upload (which Jellyfin gets first) can't race
datacenter boxes during the first hours of a release, when most of the leeching
happens. Paid upload credit costs $0.30–0.50/GB. The seedbox breaks even at
about 23 GB of upload a month.

## Pieces

| Where | What | In git? |
|---|---|---|
| Seedbox (Ultra.cc, 1 TB disk, 2 TB/month upload cap) | qBittorrent + autobrr, from the provider's app installer | No. Configured by hand; filters are summarized below |
| Cluster, `qbittorrent` ns | `seedbox-handoff` CronJob | Yes, this directory |
| Cluster, `qbittorrent` ns | `seedbox-handoff` SOPS secret | Yes, encrypted |
| GHCR | `seedbox-handoff` image: python + `qbittorrent-api` + rclone | Yes, `images/seedbox-handoff/`, built by `build-images.yml` |

The tracker isn't named anywhere in git. Its announce host lives in the secret
and is only used to filter torrents.

## Timeline

Day 0 is the day the seedbox goes live. That date is the only input the jobs
need (`SEEDBOX_START` in the ConfigMap).

| Day | Event |
|---|---|
| 0 | Seedbox live. **Turn off auto-renew.** Install qbt + autobrr. Run the speed test (below). |
| 0–3 | autobrr grabs freeleech-only to prove the filters, the rotation and the upload. |
| 3 | Start the paid freeleech pass (one month). Widen the filters to new popular releases. |
| ~24 | autobrr stops grabbing (filter disabled by hand, or its max-downloads drops to 0). Keeps the handoff small. |
| 25 | `space` phase: report how much the handoff needs vs pool1 free space. |
| 27 | `handoff` phase: copy torrents that haven't met the rule, add them to home qbt. Retries daily through day 29. |
| 30 | Seedbox expires. |
| 30–44 | `expire` phase: remove each handoff torrent from home once its total seeding time reaches the rule. |

## autobrr filters (on the seedbox)

- Freeleech only until the pass starts; after that, any new release.
- Movies and TV, 2–30 GB, 1080p/2160p WEB-DL from popular groups.
- A max-downloads-per-day cap sized so the 1 TB disk and the 2 TB upload cap last the month. Keep ~350 GB of the cap in reserve for the handoff, since copying data off the box is outbound traffic.
- Seedbox qbt: remove a torrent and its files once it is **past the seeding rule and idle**, never before the rule.

## CronJob: `seedbox-handoff`

Runs once a day. Each run works out the day number from `SEEDBOX_START` and does
whichever phases apply. All phases are idempotent, so a missed or repeated run
is harmless. It talks to home qbt through the webui Service; the pod-subnet auth
bypass covers it, the same way it covers the exporter. It must schedule on
ramhaus, because `media-library` is a local PV there.

### Phase `space` (day ≥ 25; report only, never deletes)

1. Ask the seedbox qbt for torrents from the tracker whose seeding time is under the rule. Sum their size: that's **needed**.
2. Compare that with free space on `/downloads`, keeping pool1 below 90% after the handoff (ZFS slows down above that).
3. If it's short, list cleanup candidates on home qbt. A candidate must meet all of these:
   - past the seeding rule;
   - 0 leechers;
   - no activity for 7+ days;
   - every file has link count 1, i.e. not hardlinked into the library, so deleting it actually frees space.
4. Post the report (needed, free, candidates) to Discord.

**Deleting needs a human.** The job only deletes home torrents carrying the
`cleanup-ok` tag, which you add in the qbt UI after reading the report. There's
no flag in git that does it, because the candidate list would expose torrent
names in a public repo.

### Phase `handoff` (days 27–29)

For each seedbox torrent still under the rule:

1. Skip it if home qbt already has the hash.
2. Export the `.torrent` from the seedbox (`/api/v2/torrents/export`).
3. Copy the content over SFTP with rclone into `/downloads/seedbox-handoff/`, using parallel streams (`--transfers 8 --multi-thread-streams 4`). Single connections across the Atlantic over Starlink can crawl.
4. Add it to home qbt: same name, savepath `/downloads/seedbox-handoff/`, category `seedbox-handoff` (Sonarr/Radarr ignore it), and a tag `seed-until:YYYY-MM-DD` computed from the seedbox's `seeding_time`. qbt rechecks the data, then seeds.
5. Abort the run if the handoff would push pool1 past 90%.

The handoff runs in the download direction over Starlink, so it doesn't compete
with Jellyfin's upload. It also doesn't count as download on the tracker,
because the data arrives by copy, not over BitTorrent.

### Phase `expire` (day ≥ 30, until the category is empty)

Remove a `seedbox-handoff` torrent and its files once its `seed-until` date has
passed and home qbt reports it as seeding (so home has actually announced). If
something is worth keeping, move it to another category first and the job
leaves it alone.

After the category is empty, delete the CronJob, the secret and the image.

## Speed test (day 0)

Pull a ~5 GB file from the seedbox with the same rclone flags. Plan:

| Effective speed | 300 GB handoff |
|---|---|
| 100 Mbit/s | ~7 h |
| 50 Mbit/s | ~13 h |
| 20 Mbit/s | ~33 h, still fits days 27–29 |
| < 10 Mbit/s | too slow: start the handoff at day 24 and stop grabbing earlier |

## Secret: `seedbox-handoff` (SOPS)

`SEEDBOX_QBT_URL`, `SEEDBOX_QBT_USER`, `SEEDBOX_QBT_PASS`, `SEEDBOX_SFTP_HOST`,
`SEEDBOX_SFTP_USER`, `SEEDBOX_SFTP_PASS`, `TRACKER_HOST`, `DISCORD_WEBHOOK`.

## Open questions

- Is the tracker's rule a flat 14 days, or "14 days or 1:1"? If 1:1 counts, most popular grabs pass within days and the handoff shrinks to almost nothing; `space` and `handoff` would test for either condition.
- Does seeding time carry over when the same account seeds the torrent from a new IP? It normally does, because the tracker counts time per account and per torrent.
- Can the freeleech pass be started on a chosen day, and does a download still in progress when it ends count?
- Does Ultra.cc's 2 TB cap count SFTP downloads off the box? Assume yes.
