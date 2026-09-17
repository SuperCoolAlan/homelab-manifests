# T-Pot honeypot

[T-Pot CE](https://github.com/telekom-security/tpotce) in its distributed layout:
the **hive** (Elasticsearch, Kibana, attack map) runs at home as a KubeVirt VM,
and a **sensor** (the honeypots themselves) runs on a public cloud box and ships
events to the hive. Attackers only ever touch the sensor.

**Status (2026-09-17):** hive installed and running on ramhaus; the web UI answers
behind Authentik. No sensor yet; hosting is undecided (Oracle A1 slot reshuffle vs.
AWS trial), so nothing is exposed and the hive only sees its own honeypots.

```
Internet ──▶ sensor (cloud) ──WireGuard, tcp/64294 only──▶ hive VM (ramhaus)   [not built]
LAN ──▶ traefik ──▶ tpot.local.asandov.com ──▶ hive VM :64297                   [running]
```

## Hive VM — `talos/vms/tpot-hive/`

| Piece | Detail |
|---|---|
| VM | Debian 13 containerdisk, 6 cores, 16 GiB, pinned to talos-ramhaus, namespace `tpot` |
| Disk | DataVolume `tpot-hive-rootdisk`, 256 GiB sparse on `fast-array` (T-Pot hive minimum) |
| Install | cloud-init runs `install.sh -s -t h` from a pinned tpotce commit as user `alan`, then reboots. Log: `/var/log/tpot-install.log`. The installer aborts if the invoking user is named `tpot` — it creates that user itself |
| Secrets | `secrets/tpot-hive-cloud-init.enc.yaml` (SOPS) holds the whole userdata, including the web password for user `alan` |
| Web UI | `https://tpot.local.asandov.com`: Authentik forward auth, then T-Pot's own nginx login. Traefik skips verification of T-Pot's self-signed cert |
| SSH | Installer moves sshd to 64295; `momscloset` key, user `alan`. `ssh tpot` (alias in `~/.ssh/config`, tunnels via `virtctl port-forward`), or `virtctl console tpot-hive -n tpot`. Ports 22 and 64295 are forwarded by masquerade and allowed from virt-api |
| MAC | Pinned in `virtualmachine.yaml`: an unpinned MAC changes on every restart and cloud-init's netplan, which matches on MAC, then leaves the guest with no IP |

The tpotce pin lives inside the encrypted userdata and only matters on first boot,
so Renovate does not track it. Updates happen inside the VM with
`~/tpotce/update.sh -y`.

The latest tagged release (24.04.1, Dec 2024) predates Debian 13 support, which is
why the pin is a master commit rather than a tag.

### Isolation

The hive will ingest attacker-controlled data, so it is treated as untrusted:

| Control | Where |
|---|---|
| Ingress only from traefik on 64297 | `networkpolicy.yaml` (CiliumNetworkPolicy) |
| Egress only to the public internet: 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16 excluded (LAN, nodes, pods, services, API server) | `networkpolicy.yaml` |
| DNS via 1.1.1.1 / 9.9.9.9, never cluster DNS | `dnsPolicy: None` in `virtualmachine.yaml` |
| No host mounts, no NFS, no shared PVCs | disk is its own zvol |

The DNS setting and the egress policy depend on each other: with cluster DNS the
VM would need a hole to kube-dns in `10.0.0.0/8`.

The sensor needs no cluster ingress at all: the hive dials the tunnel out and the
sensor's events arrive on the hive's own `wg0` inside the guest, so Cilium only
sees the encrypted UDP flow the hive opened. See [T-Pot sensor](tpot-sensor.md).

## First boot

Expect 30+ minutes: the installer clones tpotce from github.com (slow over
Starlink) and pulls ~20 images. That download once locked up ramhaus's onboard
e1000e NIC (`Detected Hardware Unit Hang`), taking the node, the tunnels and the
cluster API down with it; TSO/GSO are disabled on `eno1` via an `EthernetConfig`
document in the (gitignored) `talos/config/worker-ramhaus-nvme.yaml`.

```bash
kubectl -n tpot get dv,vm,vmi
virtctl console tpot-hive -n tpot          # watch cloud-init, then the reboot
ssh tpot 'sudo tail -f /var/log/tpot-install.log'   # once sshd is up
talosctl -n 10.0.1.12 dmesg | grep 'Hardware Unit Hang'   # must stay empty during the pulls
curl -sk -o /dev/null -w '%{http_code}\n' https://tpot.local.asandov.com   # 302 to authentik
```

To reinstall from scratch, delete the DataVolume and restart the VM (it holds the
PVC until then); cloud-init only runs once per disk.

## Open items

- Sensor host: no always-free cloud VM fits, so it is an AWS Free plan box (self-closing credits). Template and runbook: [T-Pot sensor](tpot-sensor.md).
- Hive-side WireGuard config + certificate reissued with the tunnel IP as SAN, both covered in that runbook.
