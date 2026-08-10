# monerod

A private, outbound-only Monero node with a pruned blockchain.

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
| P2P | 18080, outbound only, not advertised (`--hide-my-port`) |
| Restricted RPC | 18089, ClusterIP + `monerod.local.asandov.com` (LAN only) |
| Unrestricted RPC | **never bound** — 18081 exposes unauthenticated admin methods |

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

Nothing here is reachable from the internet. The node makes its own ~12
outbound peer connections and syncs fine with zero inbound ports.

### If we later want a public node

Do **not** port-forward on OPNsense. Extend the existing Oracle jumphost
instead — see [`docs/oracle-wireguard-jumphost.md`](../../docs/oracle-wireguard-jumphost.md).
The sketch, deliberately not implemented yet:

1. Add a **second** WireGuard peer on Oracle, `10.100.0.3/32`, alongside the
   existing TrueNAS peer at `10.100.0.2`. Do not route monerod through TrueNAS.
2. Bring up the tunnel as a **native sidecar** in this pod (an init container
   with `restartPolicy: Always`, `NET_ADMIN`) — the same pattern as gluetun in
   SABnzbd. monerod then binds inside the tunnel's netns with no Talos machine
   config change and no node-level firewall rules.
3. On Oracle, DNAT `tcp/18080` to `10.100.0.3:18080`. Caddy is not usable here:
   Monero P2P is raw TCP, not HTTP.
4. Extend the `wg_restrict` nftables chain to allow `oifname "wg0" tcp dport
   18080` to `10.100.0.3` only, so a compromised VPS still cannot reach
   anything else through the tunnel.
5. Drop `--hide-my-port` and add `--p2p-external-port=18080`.

Publishing the **RPC** publicly is a separate and larger decision — restricted
RPC only, and it would want rate limiting on the Caddy side.
