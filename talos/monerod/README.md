# monerod

A Monero node with a pruned blockchain. Public P2P through the Oracle VPS,
anonymous transaction relay through Tor, and the block-template feed for
[`talos/p2pool`](../p2pool/README.md).

## Why not an operator

[`cirocosta/monero-operator`](https://github.com/cirocosta/monero-operator) was
the obvious candidate but is dormant (29 stars, 51 commits, no activity in
years), and its real value is `MoneroNetwork` private testnets and `xmrig`
mining fleets — neither of which we want. It wraps a `StatefulSet`; we just
write the `StatefulSet`.

The image, [`sethforprivacy/simple-monerod-docker`](https://github.com/sethforprivacy/simple-monerod-docker),
is the de-facto community build: monerod compiled from source on Alpine,
rebuilt by GitHub Actions on every upstream release, tags matching Monero
versions exactly (`v0.18.5.1`). Renovate bumps the tag.

## Shape

| Thing | Value |
| --- | --- |
| Node | `talos-ramhaus` (pinned — the `ssd` ZFS pool is node-local) |
| Storage | `ssd-array` (openebs-zfs-localpv), 250Gi, expandable |
| P2P | 18080, public at `147.224.205.227:18080` via WireGuard (see below) |
| Tor | `--tx-proxy` for our own txs; `.onion:18084` anonymous inbound (tx relay only) |
| ZMQ | 18083, ClusterIP only — p2pool's block-template feed |
| Restricted RPC | 18089, ClusterIP + `monerod.local.asandov.com` (LAN only) |
| Unrestricted RPC | `127.0.0.1:18081` only — unauthenticated admin methods; used solely by the exporter sidecar |
| Metrics | exporter sidecar `:9000`, ServiceMonitor `monerod`, Grafana folder "Monero" |

Initial sync of a pruned chain is on the order of a day depending on peers and
disk. `--prune-blockchain` only takes effect on a *fresh* data dir; changing it
later requires either `monero-blockchain-prune` or a resync.

## Storage notes

- **Not `fast-array`**, even though it is the cluster-default StorageClass —
  that pool is currently degraded. Anything in this repo that creates a PVC
  without an explicit `storageClassName` still lands there.
- **Not `truenas-nfs`.** monerod's LMDB does memory-mapped random writes.
  Over NFS that is both slow and a corruption risk.

## Exposure

```
internet :18080 ─► Oracle 147.224.205.227 ─DNAT─► wg0 10.100.0.3 (this pod) ─► monerod
monerod egress  ─► default route wg0 ─► Oracle masquerade ─► internet
cluster / LAN   ─► eth0 (10.0.0.0/8 kept off the tunnel: DNS, probes, ingress, p2pool)
```

All of monerod's internet traffic leaves via Oracle, not just replies. If it
dialled out from home, peers would record the home address — which nobody can
dial — and inbound would never arrive. Home is behind Starlink, so there is no
port-forward alternative.

The `wg-up` init container builds the tunnel in the pod's own netns (same
pattern as `talos/jellyfin-tunnel`) and is why the namespace is `privileged`.
If the tunnel is down the default route blackholes: monerod loses peers rather
than falling back to the home IP.

The Oracle side (DNAT, masquerade, peer isolation, OCI security list) is in
[`docs/oracle-wireguard-jumphost.md`](../../docs/oracle-wireguard-jumphost.md#monerod-p2p-gateway).

### Tor

Tor inbound is **not** for block sync — monerod only relays transactions over
anonymity networks. Serving blocks to syncing peers is the Oracle path's job.
The onion key lives on the PVC (`tor/hs/monerod`), so the address is stable;
deleting that directory mints a new one.

### Public RPC

Not published. Doing so is a separate and larger decision — restricted RPC
only, behind Caddy with rate limiting.

## Verifying

```bash
kubectl -n monerod logs monerod-0 -c wg-up                  # tunnel + routes
kubectl -n monerod logs monerod-0 -c tor | tail             # "Bootstrapped 100%"
curl -s https://monerod.local.asandov.com/get_info | jq '{incoming_connections_count, outgoing_connections_count, synchronized}'
ssh oracle 'sudo wg show wg0'                                # handshake on YZxL…/xM=
```

`incoming_connections_count` climbing above 0 within an hour or so means the
Oracle path works end to end.
