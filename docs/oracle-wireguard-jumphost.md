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

## Immich (photos.asandov.com)

Added 2026-09-15. Immich moved off the Cloudflare tunnel because Cloudflare caps a
request body at 100 MB and Immich uploads each asset in a single request, so video
uploads failed. It shares the Jellyfin box and tunnel:

```
photos.asandov.com (DNS-only A record → this VPS)
  → Caddy site photos.asandov.com (request_body max_size 0, no read/write timeouts)
  → wg0 10.100.0.2:30014
  → jellyfin-tunnel pod, container immich-forwarder (socat)
  → traefik tunnel entrypoint :8081 → immich-public Ingress → immich-server:2283
```

- **Port 30014** is hardcoded in the socat listener, the Caddyfile and the
  `wg_restrict` nftables rule, the same way 30013 is for Jellyfin.
- **Traefik, not Immich directly**: going through the `tunnel` entrypoint keeps the
  CrowdSec bouncer and traefik access logs. The entrypoint trusts X-Forwarded-For
  from 10.244.0.0/16, so the real client IP Caddy sets survives the socat hop.
- **Timeouts**: the `tunnel` entrypoint runs with `readTimeout: 0s`; the 60 s
  default cuts off long uploads.
- **Egress budget**: photo and video downloads now leave through this box's
  uncapped Oracle egress (see [Egress budget](#egress-budget)).
- The jelly engine's CrowdSec already reads `/var/log/caddy/*.log`, so the new
  site is covered by its caddy scenarios and nftables bouncer.

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
| Egress cap | `egress-cap.service`: `tc ... cake bandwidth 8mbit` on `enp0s6`, covering monerod, p2pool and the VPS itself. `monero-egress-throttle.timer` (every 15 min) drops it to 500 kbit/s once vnstat shows 630 GB tx this month and restores 8 Mbit/s when the month rolls over, so a 31-day month tops out near 0.8 TB. It writes `monero_egress_{throttle_active,month_tx_bytes,throttle_threshold_bytes}` to node-exporter's textfile dir. No guard: the node must never shut off. See [Egress budget](#egress-budget) |

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
| Tor obfs4 bridge | `tor@default` from `deb.torproject.org` (`/etc/apt/sources.list.d/tor.sources`) + Ubuntu `obfs4proxy`; `/etc/tor/torrc`: `BridgeRelay 1`, ORPort 9443, obfs4 on 8443, nickname `chicagoobfs4`, no ContactInfo. Drop-in `tor@default.service.d/wg0.conf` orders it after wg0 |
| Tor metrics | `MetricsPort 10.100.0.1:9035` + `MetricsPortPolicy accept 10.100.0.7`; scraped as `job="tor-bridge"`. Never widen the policy: tor's own manual warns public metrics endanger users |
| Psiphon Conduit | `conduit.service` running `/usr/local/bin/conduit start --data-dir /var/lib/conduit --metrics-addr 10.100.0.1:9090 --bandwidth 10` (release-cli-2.0.0 arm64, checksum in `/usr/local/share/conduit/VERSION`), `DynamicUser`, same sandboxing as the proxy. WebRTC ports fall inside the existing 32768:60999 accept. Scraped as `job="conduit"` |
| Upgrading Conduit | download the new `conduit-linux-arm64`, verify against the release `checksums.txt`, `install -m 0755` over the binary, update `VERSION`, restart |
| OCI NSG `snowflake-jumphost` (bridge) | ingress TCP 9443 and TCP 8443 from 0.0.0.0/0 |
| INPUT accepts | `/etc/iptables/rules.v4`: UDP 51820, UDP 32768:60999, TCP 9443 + 8443, TCP 9999/9035/9090 from `10.100.0.7` on wg0, TCP 8080 from `10.100.0.11` on wg0 |
| CrowdSec engine | apt `crowdsec` 1.7.8 + `crowdsec-firewall-bouncer-nftables` 0.0.36 (held), LAPI `0.0.0.0:8080` (`config.yaml.local`), sshd via journald (`acquis.d/sshd-journal.yaml`). Console `oracle-snowflake-jumphost`. See `talos/cluster-services/crowdsec/README.md` |
| crowdsec-web-ui peer | wg0 `[Peer]` `10.100.0.11/32` (talos/crowdsec-lapi-tunnel), pubkey `NzhhHkFAmXsWAoi3IKVxZUxrmFER7aovcl198KR4vxM=`. A peer added live with `wg set` gets no route (only `wg-quick up` adds them): also run `ip route replace <peer>/32 dev wg0`, or replies leave via enp0s6 and the tunnel times out |
| wg0 output | `/etc/nftables-wg-restrict.nft` (table `ip wg_restrict`): VPS may only reply into wg0 |
| Egress cap | `egress-cap.service`: `tc ... cake bandwidth 19500kbit` on `enp0s6` (at most 6.53 TB in a 31-day month), shared by all three relays. Change it live with `tc qdisc change`: restarting the unit also restarts Conduit, which `Requires=` it |
| Egress guard | `snowflake-egress-guard.timer` every 15 min: stops snowflake, the bridge and Conduit once vnstat shows 6.6 TB tx this month, restarts them next month. A backstop only; the cap keeps it from tripping. See [Egress budget](#egress-budget) |
| Auto-updates | `/etc/apt/apt.conf.d/52unattended-upgrades-local`: adds `-updates` and `TorProject:noble`, auto-reboot at 10:00 UTC (jelly 09:00, monero 09:30, same file). CrowdSec stays held |

Both the cap and the guard exist to keep the tenancy inside the free 10 TB/month
outbound; the account is Pay-As-You-Go, so overage bills. Pre-change copies are
`*.bak-20260914`.

```bash
ssh oracle-snowflake-jumphost 'sudo journalctl -u snowflake-proxy -o cat | grep -E "NAT type|In the last"'
ssh oracle-snowflake-jumphost 'vnstat -m -i enp0s6; tc -s qdisc show dev enp0s6 | head -3'
ssh oracle-snowflake-jumphost 'sudo wg show wg0'               # handshake for WzQX…
```

## Signal TLS proxy

Added 2026-09-15 on its own instance, `signal-proxy-20260915`
(`147.224.156.61`, A1.Flex 1 OCPU / 4 GB, SSH alias `oracle-signal-proxy`,
`momscloset` key). Share link: `https://signal.tube/#signal.asandov.com`.
`signal.asandov.com` is a Cloudflare A record, **DNS only**: proxying would put
Cloudflare's certificate in front and break the outer TLS layer.

It is a native port of `signalapp/Signal-TLS-Proxy` (pinned at
`cc41daab1f38f7c01de833875065f46435914151`): one nginx terminates the outer TLS
on 443 with the Let's Encrypt certificate and hands the stream to a loopback
relay on `127.0.0.1:4433`, which reads the inner SNI and splices only to the
Signal hostnames in upstream's map. Anything else goes to `127.0.0.1:9` and
fails. The proxy never sees message contents; the inner TLS is end-to-end with
Signal.

| Piece | Where |
|---|---|
| nginx | Ubuntu `nginx` + `libnginx-mod-stream`; `/etc/nginx/nginx.conf` is the merged terminate + relay config (no sites-enabled). Logs off, as upstream |
| Certificate | `certbot certonly --webroot -w /var/www/certbot`, no email (as upstream), `certbot.timer` renews, deploy hook reloads nginx. TLS params from certbot's repo in `/etc/letsencrypt/` |
| Upstream drift | `signal-proxy-upstream-check.timer` (daily) compares upstream `data/nginx-relay/nginx.conf` with `/usr/local/share/signal-proxy/nginx-relay.pinned.conf` and writes `signal_proxy_upstream_{drift,check_success,last_check_timestamp_seconds}` to node-exporter's textfile dir. Alerts `SignalProxyUpstreamChanged` / `SignalProxyUpstreamCheckStale` |
| Re-syncing | copy upstream's map/upstreams into the `stream` block, replace the pinned copy and `PINNED_SHA`, `nginx -t`, `systemctl reload nginx`. Signal gives ~30 days before a change is required |
| Firewall | Shared security list already allows TCP 80/443 (no NSG needed). `rules.v4`: TCP 80, 443, UDP 51820, TCP 9100 from `10.100.0.12` on wg0, TCP 8080 from `10.100.0.13` on wg0 |
| WireGuard | server pubkey `CDzfORMvOMa5sHqUsfV1+PTyXm4FcItbMQ1y9qBrYAE=`; peers `10.100.0.12` oracle-telemetry (`DOXpuMy6io8/HluVcCf0X0kNKvoljf5wukDtZVvsozs=`), `10.100.0.13` crowdsec-lapi-tunnel (`D73KyjISJJ5+zjeliHXyOxNRBQVYLlnQf779eyfwAkk=`) |
| wg0 output | `/etc/nftables-wg-restrict.nft`, journald push to `10.100.0.12:9428` only |
| CrowdSec engine | held 1.7.8 + nftables bouncer 0.0.36, LAPI `0.0.0.0:8080`, sshd via journald, Console `oracle-signal-proxy` |
| Auto-updates | same `52unattended-upgrades-local`, auto-reboot 10:30 UTC |
| Backups | OCI policy `signal-weekly-sun` (see `docs/backup-and-recovery.md`) |
| Gatus | `tls://signal.asandov.com:443`, connected + certificate > 10 days |

No egress cap and no guard: the proxy must never be throttled or shut off. See
[Egress budget](#egress-budget). Pre-change copies are `*.bak-20260915`.

```bash
echo | openssl s_client -connect signal.asandov.com:443 -servername signal.asandov.com 2>/dev/null | openssl x509 -noout -subject -enddate
ssh oracle-signal-proxy 'cat /var/lib/prometheus/node-exporter/signal_proxy.prom; systemctl list-timers certbot.timer signal-proxy-upstream-check.timer --no-pager'
```

## Egress budget

The tenancy's free outbound is 10 TB/month and the account is Pay-As-You-Go, so
overage bills. Each box gets a `tc cake` cap on `enp0s6` sized so its worst-case
31-day month fits a fixed share. Personal services and the Signal proxy never
shut off; only the volunteer relays on the snowflake box have a guard, and its
cap keeps that guard from tripping.

| Box | `egress-cap.service` | Worst case / 31 days | Shut-off |
|---|---|---|---|
| snowflake | 19.5 Mbit/s | 6.53 TB | guard at 6.6 TB (unreachable backstop) |
| monero | 8 Mbit/s, 500 kbit/s past 630 GB/month (`monero-egress-throttle.timer`) | ~0.8 TB (measured ~0.6 TB) | never; `MoneroEgressThrottled` fires when throttled |
| signal | none | Signal clients | never |
| jelly | none | remote Jellyfin streaming | never |

That leaves ~2.67 TB/month shared by jelly and signal before billing. `OracleTenancyEgressHigh`
fires at 9 TB summed over the last 30 days. Every box has vnstat
(`vnstat -m -i enp0s6`). Carve a new box's cap out of this table rather than
raising the total.

## Oracle telemetry (all Oracle boxes)

Added 2026-09-14. Each VPS gets one more WireGuard peer, a pod in
`talos/oracle-telemetry`:

| VPS | Peer | Pod pubkey |
|---|---|---|
| jelly-jumphost | `10.100.0.8` | `7nkSNZABpwn43FYr07Ge7RJAIjRywELaSWdC31a2n2s=` |
| monero-jumphost | `10.100.0.9` | `z95Kwa4GhiMI707V78rbRIc00IoxuFxoOMSQ4SriQRE=` |
| snowflake-jumphost | `10.100.0.10` | `OPglLmGEvHQjLidsCRnXIloKlXtbNApHUMly5CIT4WQ=` |
| signal-proxy | `10.100.0.12` | `DOXpuMy6io8/HluVcCf0X0kNKvoljf5wukDtZVvsozs=` |

**Metrics (pull).** `prometheus-node-exporter` listens on `10.100.0.1:9100`
only (`/etc/default/prometheus-node-exporter`, drop-in ordering it after
`wg-quick@wg0`). vmagent scrapes the pod's socat, `job="oracle-node"`,
`instance` = jelly / monero / snowflake / signal. INPUT accepts 9100 from the peer only:
`rules.v4` on all boxes, plus `/etc/nftables.conf` on jelly.

**Logs (push).** `systemd-journal-upload` sends the whole journal to
`http://<peer>:9428/insert/journald`
(`/etc/systemd/journal-upload.conf.d/victorialogs.conf`). This is the one place
a VPS may open a connection into wg0, and only to its own peer on 9428:

| VPS | wg0 output accept |
|---|---|
| jelly | `/etc/nftables.conf`, table `wg_restrict` |
| monero | `/etc/nftables-monerod.nft`, table `monerod_gw` output chain |
| snowflake | `/etc/nftables-wg-restrict.nft` |
| signal | `/etc/nftables-wg-restrict.nft` |

On the pod side nginx accepts only `POST /insert/journald/upload` from
`10.100.0.1` and 403s everything else, because VictoriaLogs' 9428 also serves the
query and delete APIs. A compromised VPS can append logs but not read or delete
them. VictoriaLogs stays ClusterIP; nothing is published.

journal-upload keeps its cursor in `/var/lib/private/systemd/journal-upload/state`
and resumes after tunnel outages. That file was seeded with the journal tail at
setup: without a cursor journal-upload ships the entire journal from the start
(2 GB on jelly). Delete it only if you want that backfill.

**Uploader must never give up.** The stock unit restarts 5 times in 10 s and then
stops for good, so a routine restart of the ingest pod or VictoriaLogs silently
ended log shipping on three boxes on 2026-09-15. Each box has
`/etc/systemd/system/systemd-journal-upload.service.d/10-retry-forever.conf`
(`StartLimitIntervalSec=0`, `Restart=always`, `RestartSec=30`).

**Alerting on it.** node-exporter runs with
`--collector.systemd --collector.systemd.unit-include=systemd-journal-upload\.service`
in `/etc/default/prometheus-node-exporter`, which exposes only that unit's state.
`OracleJournalUploadDown` (alertgroup `homelab`, to Discord) fires after 15 min
when the unit isn't active or the state metric is missing while the box is up.

`systemd-journal-remote.service`/`.socket` from the same package stay masked;
nothing here listens for remote journals. Pre-change copies are `*.bak-20260914`.

```bash
kubectl -n oracle-telemetry get pods
ssh oracle-monero-jumphost 'systemctl status systemd-journal-upload --no-pager | tail -3'
ssh oracle-monero-jumphost 'curl -s -o /dev/null -w "%{http_code}\n" http://10.100.0.9:9428/select/logsql/query'  # expect 403
# VictoriaLogs: _stream:{_HOSTNAME="monero-jumphost-20260910"}   VictoriaMetrics: up{job="oracle-node"}
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
