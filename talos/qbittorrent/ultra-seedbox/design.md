# One-month seedbox: ratio push

**Goal:** raise the private-tracker ratio with a rented seedbox for exactly one
billing month, racing new releases while the tracker's freeleech pass makes
downloads free. The seedbox never renews.

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
| Cluster, `qbittorrent` ns | `alerts.yaml` VMRule; seedbox scrapes and the Ultra dashboard | Yes |

The tracker isn't named anywhere in git.

## Rotation (since day 0)

The freeleech pass includes hit-and-run immunity, so the tracker's 14-day seeding
rule doesn't apply while the pass lasts. Nearly all upload arrives in the first
hours of a release, so the box grabs every new release, seeds it briefly, and
drops it to make room for the next.

- Filter `ipt-new-releases`: every new release in any category, 100 MB–50 GB, 400 a day; autobrr's client allows 6 active downloads. Downloads don't count during the pass.
- `disk-guard` external filter (`~/bin/autobrr-disk-ok.sh`, rejects on error) accepts a grab only while:
  - the account is under 92% of its 932 GB quota (preallocation reserves each grab up front, so the ~75 GB left covers one more 50 GB grab);
  - it's before 2026-10-31T23:00Z, an hour before the pass, its hit-and-run immunity and the seedbox all end.
- Kill switch: the `seedbox-killswitch.timer` systemd user timer (Persistent, so it also fires after downtime) runs `~/bin/seedbox-killswitch.py` at 2026-10-31T23:00Z. It stops and disables autobrr and stops every unfinished download; finished torrents keep seeding.
- Seedbox qbt removes a torrent and its files after 3 days of seeding or 12 h without upload, whichever comes first.
- Seedbox qbt upload slots are unlimited and connections are 1000 global / 200 per torrent, so no swarm is throttled by slot limits.
- The binding limit is the provider's 2 TB/month upload cap, not the disk.

## Alerts

`alerts.yaml` pages the homelab Discord channel when seedbox qbt, autobrr, or autobrr's announce IRC connection is down for 15 minutes, and once when about 90% of the 2 TB upload allowance is used. The rules switch themselves off when the seedbox expires.

## CronJob: `seedbox-handoff` (cancelled)

Not needed while hit-and-run immunity covers every grab. Kept for a future month without it.

### Original design

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

- Does seeding time carry over when the same account seeds the torrent from a new IP? It normally does, because the tracker counts time per account and per torrent.
- Can the freeleech pass be started on a chosen day, and does a download still in progress when it ends count?
- Does Ultra.cc's 2 TB cap count SFTP downloads off the box? Assume yes.
