# Oracle WireGuard Jumphost for Jellyfin

How `jellyfin.asandov.com` reaches the internet.

**Updated 2026-08-10:** the home end of this tunnel moved from TrueNAS into the
cluster. See [History](#history) for what changed and why.

## Why this exists at all

Every other public service here (authentik, immich, gatus, jellyseerr) goes
through the Cloudflare tunnel. Jellyfin does not, because Cloudflare's terms
discourage serving video through their proxy. So it takes a separate path with
a plain **DNS-only** A record and its own reverse proxy.

This also means `jellyfin.asandov.com` does not benefit from Cloudflare's
protection - the Oracle VPS is directly exposed. The firewall rules below are
load-bearing, not decoration.

## Architecture

```
Internet
    │
    ▼
┌──────────────────────────────────────┐
│  Oracle Cloud VPS                    │
│  163.192.195.190 (us-chicago-1)      │
│  VM.Standard.A1.Flex, ARM, free tier │
│                                      │
│  ┌─────────────┐   ┌─────────────┐   │
│  │   Caddy     │──▶│  WireGuard  │   │
│  │  :443/:80   │   │  wg0        │   │
│  └─────────────┘   └──────┬──────┘   │
│                           │          │
└───────────────────────────┼──────────┘
                            │ 10.100.0.1 ◄─► 10.100.0.2
                            ▼
┌──────────────────────────────────────┐
│  talos-ramhaus                       │
│  ┌────────────────────────────────┐  │
│  │ pod: jellyfin-tunnel           │  │
│  │   initContainer wg-up  → wg0   │  │
│  │       holds 10.100.0.2         │  │
│  │   container forwarder (socat)  │  │
│  │       :30013 ──┐               │  │
│  └────────────────┼───────────────┘  │
│                   ▼                  │
│    Service jellyfin.jellyfin:8096    │
└──────────────────────────────────────┘
```

Nothing is published on the LAN. Traffic arrives inside the tunnel pod's own
network namespace - there is no Service, NodePort or Ingress on this path.

## Home end — `talos/jellyfin-tunnel/`

Managed by Argo like everything else. Three things worth knowing before editing:

**The WireGuard link is created by an init container, not a running one.**
Kernel WireGuard is stateless once configured: the interface lives in the pod's
network namespace for the pod's lifetime, and the kernel drives handshakes and
keepalives with no userspace help. So nothing privileged stays running - steady
state is a single unprivileged `socat` with all capabilities dropped. The init
container needs `NET_ADMIN`, which is why this has its own
PodSecurity-privileged namespace instead of living in `jellyfin`.

**Port 30013 is hardcoded in three places** - the socat listener, the Caddyfile
on Oracle, and Oracle's nftables egress rule. Changing one alone produces a 502
from Caddy with nothing visibly wrong in the cluster. Change all three or none.

**MTU is pinned to 1420** (1500 minus WireGuard's 80-byte header). At the 1500
default the failure mode is: handshake succeeds, small requests succeed, video
stalls. Do not "clean this up".

`wg-quick` is deliberately not used - it rewrites `resolv.conf` and installs
routes, and in a pod that breaks the cluster DNS `socat` needs to resolve the
jellyfin Service. The init container uses `ip` and `wg setconf` directly.

Only the private key is in SOPS (`secrets/jellyfin-wg-key.enc.yaml`). The peer
public key, endpoint and allowed IPs are public facts and sit readable in the
manifest.

## Oracle VPS

### WireGuard (`/etc/wireguard/wg0.conf`)

```ini
[Interface]
PrivateKey = <redacted>
Address = 10.100.0.1/32
ListenPort = 51820

[Peer]
PublicKey = iTzh+uCyXx/Whjs3EB3gSDlHEVqHX2g5qavJQ0KtcQ0=
AllowedIPs = 10.100.0.2/32
```

The peer has no `Endpoint` - the cluster dials out and Oracle learns the address
from the handshake, so a changing home IP needs no action here. Previous config
is kept at `/etc/wireguard/wg0.conf.bak-20260810`.

### Caddy (`/etc/caddy/Caddyfile`)

```
jellyfin.asandov.com {
    reverse_proxy 10.100.0.2:30013 {
        transport http {
            read_timeout 0
            write_timeout 0
        }
        flush_interval -1
    }
}
```

The disabled timeouts and `flush_interval -1` are what keep long video streams
and the playback WebSocket alive. Without them the stream drops mid-playback.

### Firewall (nftables)

```
table ip wg_restrict {
    chain output {
        type filter hook output priority filter; policy accept;
        oifname "wg0" tcp dport 30013 accept
        oifname "wg0" icmp type echo-request accept
        oifname "wg0" ct state established,related accept
        oifname "wg0" counter drop
    }
}
```

If the VPS is compromised, this stops the tunnel being used to reach anything
but jellyfin. It is now the *second* of two controls: the pod on the other end
exposes nothing except the socat listener, so even without this rule there is no
lateral path into the cluster.

## monerod P2P gateway

Runs on its own instance, `monero-jumphost-20260910` (`147.224.205.227`,
A1.Flex 1 OCPU / 6 GB), separate from the jellyfin jumphost. Its WireGuard
peers are `10.100.0.3` (pubkey `YZxLSdNUR3XK5Vo25Kqgp7VaBd/Z95KD70bQ2YDC/xM=`),
the `talos/monerod` pod, and `10.100.0.4`, the `talos/p2pool` pod (see
[p2pool P2P gateway](#p2pool-p2p-gateway)); the server pubkey is
`rE+qZRl4LnX8iG4wUTUxj+jVRMhqLlvP8kpH8vrzMQM=`. SSH needs the `momscloset` key
(the one in the instance's OCI metadata). This is a
**router** role: the VPS DNATs inbound P2P to the pod and masquerades all of
the pod's egress, so peers see `147.224.205.227` as the node's address.

| Piece | Where |
|---|---|
| Forwarding | `/etc/sysctl.d/99-wg-forward.conf` (`net.ipv4.ip_forward=1`) |
| Peer | `[Peer]` block in `/etc/wireguard/wg0.conf`, `AllowedIPs = 10.100.0.3/32`, `MTU = 1370` |
| DNAT / masquerade / isolation | `/etc/nftables-monerod.nft` (table `ip monerod_gw`) and `/etc/nftables-p2pool.nft` (table `ip p2pool_gw`), both `include`d from `/etc/nftables.conf` |
| INPUT / FORWARD accepts | `/etc/iptables/rules.v4` only, ahead of the image's reject |
| OCI NSG `monero-jumphost` | ingress TCP 18080 and TCP 37888 from 0.0.0.0/0; attached to this instance's VNIC only |
| OCI security list (shared with jellyfin box) | UDP 51820 from 0.0.0.0/0. 18080 was removed from it 2026-09-13 so the jellyfin box is closed on it at the cloud layer; previous rules backed up before the change |
| CrowdSec engine | LAPI on `0.0.0.0:8080` (`/etc/crowdsec/config.yaml.local`), this VPS only; jelly-jumphost runs its own since 2026-09-14. See `talos/cluster-services/crowdsec/README.md` |
| crowdsec-web-ui peer | wg0 `[Peer]` `10.100.0.6/32` (talos/crowdsec-lapi-tunnel) and `-A INPUT -s 10.100.0.6/32 -i wg0 ... --dport 8080 -j ACCEPT` in `rules.v4`. jelly-jumphost has the same with `10.100.0.5`, in both `rules.v4` and `/etc/nftables.conf`. Removing either rule blanks that engine in the web UI |

`/etc/nftables.conf` must not `flush ruleset`: `netfilter-persistent` owns
`table ip filter`, and a flush at boot would wipe the FORWARD accepts.

`monerod_gw`'s forward chain drops `wg0 → wg0` and anything from `wg0` not
sourced from `{ 10.100.0.3, 10.100.0.4 }`, so the box routes for exactly those
two pods and they cannot reach each other through it. Its output chain drops
anything the VPS itself opens into `wg0`. The CrowdSec bouncer's forward-hook
chain drops banned IPs on both the 18080 and 37888 paths.

The image's original firewall is at `/etc/iptables/rules.v4.bak-20260910`.

```bash
ssh ubuntu@147.224.205.227 'sudo wg show wg0'                  # handshake for YZxL…
ssh ubuntu@147.224.205.227 'sudo nft list table ip monerod_gw' # dnat/masquerade counters
nc -vz 147.224.205.227 18080                                   # from anywhere outside
```

## p2pool P2P gateway

Added 2026-09-13 on the same box. Peer `10.100.0.4` (pubkey
`ZJQ62XdacI/gbLZs9x2IXg391K2SmorhH52feLQYXyk=`) is the `talos/p2pool` pod. It
is stricter than monerod's path because p2pool only ever speaks TCP:

| Rule | Where |
|---|---|
| DNAT `enp0s6` tcp/37888 → `10.100.0.4` | `p2pool_gw` prerouting |
| Masquerade only `ip saddr 10.100.0.4` **TCP** out `enp0s6` | `p2pool_gw` postrouting |
| Drop any non-TCP from `10.100.0.4` | `p2pool_gw` forward (priority filter - 5) |
| Accept `enp0s6→wg0` tcp/37888 to .4; accept `wg0→enp0s6` TCP from .4 | `/etc/iptables/rules.v4` FORWARD, ahead of the reject |

Both peers' isolation lives in `monerod_gw` (above). Pre-change copies of every
edited file are `*.bak-20260913`.

```bash
ssh oracle-monero-jumphost 'sudo wg show wg0'                    # handshake for ZJQ6…
ssh oracle-monero-jumphost 'sudo nft list table ip p2pool_gw'    # dnat/masquerade
nc -vz 147.224.205.227 37888                                     # from anywhere outside
```

## Snowflake proxy

Added 2026-09-14 on its own instance, `snowflake-jumphost-20260914`
(`170.9.244.226`, A1.Flex 1 OCPU / 4 GB, SSH alias `oracle-snowflake-jumphost`,
`momscloset` key). Unlike the other boxes this is not a router: the Tor
Snowflake proxy runs **on the VPS itself**. From home it tested `NAT type:
restricted` behind Starlink CGNAT and got almost no clients; here it tests
`unrestricted`. Nothing from home is reachable through it.

WireGuard serves only metrics: peer `10.100.0.7` (pubkey
`WzQX0m95K/hilamomP3f3DFyA7OL1jFQx5tIyTPWG18=`) is the `talos/snowflake` socat
pod; server pubkey `B31LFquE549qd8JW4zGS7b1XsVNIPI/mS29xFVhRDkA=`.

| Piece | Where |
|---|---|
| Proxy | `snowflake-proxy.service` running `/usr/local/bin/snowflake-proxy` (static binary + geoip extracted from the image digest in the unit; checksums in `/usr/local/share/snowflake`), `DynamicUser`, `NoNewPrivileges`, systemd sandboxing. Not podman: with `no-new-privileges` Ubuntu 24.04 stacks crun's AppArmor profile, which denies inet sockets |
| Upgrading | `crane export --platform linux/arm64 <image@digest> - \| tar -xf - bin/proxy usr/share/tor/geoip usr/share/tor/geoip6`, copy to the paths above, update the digest comment, restart |
| Ports | `-ephemeral-ports-range 32768:60999`; must match the NSG and `rules.v4` or the NAT test falls back to restricted |
| Metrics | `-metrics-address 10.100.0.1` (wg0 only), `:9999` |
| OCI NSG `snowflake-jumphost` | ingress UDP 32768-60999 from 0.0.0.0/0; UDP 51820 comes from the shared security list |
| INPUT accepts | `/etc/iptables/rules.v4`: UDP 51820, UDP 32768:60999, TCP 9999 from `10.100.0.7` on wg0 |
| wg0 output | `/etc/nftables-wg-restrict.nft` (table `ip wg_restrict`): VPS may only reply into wg0 |
| Egress cap | `egress-cap.service`: `tc ... cake bandwidth 20mbit` on `enp0s6` (max ~6.5 TB/month) |
| Egress guard | `snowflake-egress-guard.timer` every 15 min: stops the proxy once vnstat shows 7 TB tx this month, restarts it next month |

Both the cap and the guard exist to keep the tenancy inside the free 10 TB/month
outbound; the account is Pay-As-You-Go, so overage bills. Pre-change copies are
`*.bak-20260914`.

```bash
ssh oracle-snowflake-jumphost 'sudo journalctl -u snowflake-proxy -o cat | grep -E "NAT type|In the last"'
ssh oracle-snowflake-jumphost 'vnstat -m -i enp0s6; tc -s qdisc show dev enp0s6 | head -3'
ssh oracle-snowflake-jumphost 'sudo wg show wg0'               # handshake for WzQX…
```

## DNS

`jellyfin.asandov.com` → `163.192.195.190` in Cloudflare, **DNS Only** (grey
cloud, not proxied). Proxying it would defeat the purpose.

Do not add a Cloudflare-tunnel Ingress for this hostname. One was added by
mistake on 2026-08-09 and removed the next day: the tunnel controller tries to
publish a CNAME, Cloudflare rejects it because the A record already exists
(error 81053), and because the controller applies its whole configuration in one
call per reconcile, that single failure aborted the batch for authentik, gatus,
immich and jellyseerr too. See `talos/jellyfin/ingress.yaml`.

## Verifying

```bash
# home end
kubectl -n jellyfin-tunnel get pods
kubectl -n jellyfin-tunnel logs deploy/jellyfin-tunnel -c wg-up      # interface setup
kubectl -n jellyfin-tunnel exec deploy/jellyfin-tunnel -c forwarder -- true

# oracle end — look for a recent handshake and non-zero received
ssh ubuntu@163.192.195.190 'sudo wg show'
ssh ubuntu@163.192.195.190 'curl -s http://10.100.0.2:30013/health'   # expect: Healthy

# end to end
curl -s https://jellyfin.asandov.com/health                            # expect: Healthy
```

### Reading a failure

| Symptom | Where to look |
|---|---|
| 502 from Caddy | Tunnel is up, upstream is not. Check the tunnel pod and the jellyfin Service. |
| No handshake on `wg show` | Peer public key mismatch, or the pod is not running. |
| Handshake fine, video stalls | MTU. Confirm `wg0` is 1420 in the init container log. |
| Stream drops after a while | Caddy timeouts - confirm `read_timeout 0` / `write_timeout 0` survived a config edit. |

## History

Originally the tunnel terminated on TrueNAS: `10.100.0.2` was TrueNAS, and
jellyfin was a Docker container reached on host port 30013 with hand-maintained
nftables rules in Docker's `DOCKER-USER` chain restricting `wg0` to port 8096,
persisted through a `@reboot` cron entry.

When jellyfin moved into the cluster, that tunnel **kept working** - it was
still handshaking days later with 4.79 GiB transferred - but the jellyfin behind
it was gone, so Caddy returned 502 for every request. It was also the last live
service on TrueNAS, and the reason the box was still powered on.

Moving it into the cluster rather than onto the Talos host was deliberate: a
host-level `wg0` in the machine config would have been fewer moving parts, but
machine configs are gitignored here, so it would not have been in gitops, and it
would have needed a NodePort publishing jellyfin on 30013 across the LAN.

The keypair was rotated at the same time, since the old private key had been
sitting on a host being decommissioned.

## Maintenance

```bash
ssh ubuntu@163.192.195.190
sudo systemctl restart wg-quick@wg0
sudo systemctl restart caddy
sudo journalctl -u caddy -f
```

### Rotating the WireGuard key

```bash
wg genkey > /tmp/k && wg pubkey < /tmp/k          # note the public key
# 1. put the private key into talos/jellyfin-tunnel/secrets/jellyfin-wg-key.enc.yaml
#    (sops -e --pgp 9D032060B05603F790D340F98B60D1C1CF8E1A50), commit, let Argo sync
# 2. update PublicKey in /etc/wireguard/wg0.conf on Oracle
# 3. sudo systemctl restart wg-quick@wg0
```

Order matters only in that both ends are briefly mismatched; jellyfin stays up
locally throughout.

## OCI CLI

Config at `~/.oci/config`, API key at `~/.ssh/oci_api_key.pem`.

```bash
oci compute instance list --compartment-id <your-tenancy-ocid> --output table
```
