# p2pool

P2Pool **mini** sidechain node with its built-in RandomX miner, mining against
our own [`monerod`](../monerod/README.md). No pool operator, no fees; payouts
land on-chain directly in the configured wallet.

## Why the built-in miner, not xmrig

One trusted image (sethforprivacy, same source as monerod), one process, one
2 GiB RandomX dataset. xmrig would add a second dataset and a third-party image
for a few percent of hashrate.

## Schedule

OG&E Time-of-Day: on-peak 14:00–19:00 Central, **June–October**. Two CronJobs
scale the Deployment to 0 at 14:00 and back to 1 at 19:00 in those months;
the rest of the year it runs continuously.

The Deployment deliberately has no `replicas` field. With Argo autosync +
selfHeal, a `replicas` in git would undo every scheduled stop.

## Turbo

`turbo-off` is a privileged native sidecar that writes `1` to
`/sys/devices/system/cpu/intel_pstate/no_turbo` on start and `0` on stop.
Sidecars terminate after the main container, so turbo is off exactly while
mining. It is **node-wide** — everything on ramhaus runs at base clock (3.2 GHz)
during mining hours. If the pod dies uncleanly turbo stays off until the next
clean stop or reboot. There is no RAPL on this kernel, so no power cap.

## Huge pages — pending a reboot

`vm.nr_hugepages=1400` is in ramhaus's machine config, but live allocation only
got 6 pages (ZFS ARC fragments memory). After the next reboot:

1. `talosctl -n 10.0.1.12 read /proc/meminfo | grep HugePages_Total` → 1400
2. Add `hugepages-2Mi: 2800Mi` to the p2pool container's requests and limits.

Until then RandomX runs on normal pages at roughly half hashrate.

## Economics (2026-09 estimates — measure, don't trust)

E5-1660 v4, turbo off, huge pages. Measured 2026-09-10: 4 threads ≈ 2.1 kH/s.
Now 8 threads (one per physical core). CPU request 4 and **no CPU limit**: a
limit equal to the thread count throttled ~69% of periods, and the request alone
still makes mining yield under contention. ~70–80 W extra (unmeasured). Network
~6.07 GH/s, XMR ~$515, 12.5–13.3¢/kWh → on the order of 0.1 XMR/yr for ~$80/yr
of power. This runs for clean-origin coins and network support, not profit.

## Privacy

The payout address is **public** on the p2pool sidechain: anyone can see it
mines and roughly how much. Use a mining-only wallet and move funds out
deliberately. p2pool's own P2P goes out from the home IP; only monerod uses the
Oracle tunnel.

## Cache

`/data` is the `p2pool-data` PVC (1Gi, `ssd-array`), not an emptyDir: it holds
`p2pool.cache` (~453 MB fixed-size) and peer lists, so a replaced pod (push,
reboot, 19:00 scale-up) resumes from the cached sidechain instead of
re-downloading the 2160-block window. The daily 5 h pause still misses most of
a ~6 h window, so evenings still fetch ~1800 blocks. `--no-log-file` keeps the
unrotated on-disk log (~100 MB/day) off the PVC; stdout reaches VictoriaLogs.

After a fresh start p2pool briefly mines a private startup chain (sidechain
height counting from 0, difficulty 100000); shares from it are worthless and
the dashboard's share panels spike until it adopts the real chain.

## Metrics

`stats-httpd` (busybox) serves p2pool's `--data-api` JSON on `127.0.0.1:8081`;
`json-exporter` maps it to `p2pool_*` metrics per `json-exporter.yml`, scraped
via the `p2pool` ServiceMonitor (one endpoint per file, labelled `module`).
Grafana: **Monero → p2pool**. Expected-earnings panels are derived from
hashrate, sidechain difficulty and network difficulty — estimates, not payouts.

## Verifying

```bash
kubectl -n p2pool logs deploy/p2pool -c p2pool | grep -i -e "hashrate" -e "share"
kubectl -n p2pool exec deploy/p2pool -c p2pool -- ls /data/api/local
kubectl -n p2pool logs deploy/p2pool -c turbo-off                     # "turbo off"
talosctl -n 10.0.1.12 read /sys/devices/system/cpu/intel_pstate/no_turbo
kubectl -n p2pool get cronjobs
```
