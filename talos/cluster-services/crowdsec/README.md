# CrowdSec

Crowd-sourced intrusion detection and remediation, split across two engines
(LAPIs): this cluster's, and one on the Oracle monero jumphost that serves both
Oracle VPSes. Bans are not shared between the two engines; each gets CAPI plus
its own Console blocklist subscriptions.

Deployed 2026-08-31. Phased plan and rationale: `docs/crowdsec-plan.md`.

## Topology

```
  cluster (ns: crowdsec)                   Oracle VCN 10.67.0.0/24
  ┌──────────────────────────────────┐     ┌─────────────────────────────────────┐
  │ LAPI (crowdsec-lapi) :8080       │     │ monero-jumphost 10.67.0.60          │
  │   SQLite on fast-array PVC       │     │   LAPI :8080, private IP only       │
  │   ▲                              │     │   ├─ agent (sshd)                   │
  │   ├─ log processor               │     │   └─ nftables bouncer               │
  │   │  (VictoriaLogs, 5 streams)   │     │        ▲                            │
  │   └─ traefik bouncer plugin      │     │ jelly-jumphost 10.67.0.152          │
  │      enforces on tunnel apps     │     │   ├─ agent (caddy + sshd) ──► LAPI  │
  └──────────────────────────────────┘     │   └─ nftables bouncer (oracle-fw)   │
                                           └─────────────────────────────────────┘
```

The Oracle LAPI accepts connections only from jelly-jumphost's private IP
(OCI security-list rule plus `/etc/iptables/rules.v4` on monero-jumphost).
Nothing CrowdSec-related crosses the WireGuard tunnels. Box-level details:
`docs/oracle-wireguard-jumphost.md`.

## What is deployed

| Component | Where | State |
|---|---|---|
| LAPI | this dir, `crowdsec-lapi` Deployment | live, enrolled in Console as `talos-ramhaus` |
| Log processor | this dir, `crowdsec-agent` Deployment | live, reads VictoriaLogs (no DaemonSet) |
| Oracle LAPI | monero-jumphost, apt `crowdsec` 1.7.8 (held) | live, enrolled in Console as `oracle-monero-jumphost` |
| monero-jumphost agent + bouncer | local to the Oracle LAPI | live |
| jelly-jumphost agent | apt `crowdsec` 1.7.8 (held) | live, machine `oracle-jellyfin-jumphost` on the Oracle LAPI |
| jelly-jumphost bouncer | `crowdsec-firewall-bouncer-nftables` 0.0.36 (held) | live, bouncer `oracle-fw` on the Oracle LAPI |
| Traefik bouncer | `cluster-services/traefik` (plugin + Middleware) | live, bouncer `traefik-bouncer` |
| AppSec / WAF | — | not deployed |
| Cloudflare Worker bouncer | — | not deployed (see Todo) |
| OPNsense satellite | — | not deployed |

### Detection coverage

| Source | Acquisition | Verified working |
|---|---|---|
| Traefik access logs (all tunnel apps) | `type: traefik` | yes — HTTP probing / CVE / scanners |
| Caddy access logs (jellyfin) | file, on jelly-jumphost (Oracle LAPI) | yes |
| sshd (jelly-jumphost) | journald (Oracle LAPI) | yes — catches real brute force daily |
| sshd (monero-jumphost) | journald (Oracle LAPI) | **unverified** |
| Jellyfin | `type: jellyfin` | yes — end-to-end, real client IP |
| Immich | `type: immich` | yes — logs real client IP natively |
| Jellyseerr | `type: jellyseerr` | **unverified** — local auth endpoints 500'd under test |
| Authentik | `type: authentik` | **broken** — see Known issues |

### Enforcement

- **Tunnel apps** (auth, photos, jellyseerr, status): traefik bouncer plugin.
- **jellyfin.asandov.com + VPS sshd**: nftables bouncer on each Oracle VPS,
  fed by the Oracle LAPI. monero-jumphost's bouncer also drops banned IPs on
  the forwarded monerod P2P path (18080).
- **Home WAN**: nothing — no inbound forwards, default-deny already covers it.

Cluster LAPI decisions come from our own scenarios plus CAPI (community) and
three subscribed blocklists (FireHOL GreenSnow, FireHOL BotScout, OTX
honeypot). ~26k enforced; roughly 24.5k are pre-emptive blocklist entries and
a handful are live local detections. The Oracle LAPI gets CAPI plus whatever
`oracle-monero-jumphost` is subscribed to in the Console; subscriptions are
per engine, so the cluster's three do not carry over.

## Operating it

There is **no web UI** in chart 0.24.x — the old Metabase dashboard is gone.
Visibility comes from three places:

- **Grafana** → Security → CrowdSec Overview (ServiceMonitors feed VM).
- **Console** at app.crowdsec.net — alerts with geo/AS enrichment.
- **cscli** in the LAPI pod, e.g.
  `kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli alerts list`

`crowdsec-lapi.local.asandov.com` is the LAPI **API**, not a UI. It exists so
remote satellites can register.

### Lockout recovery

If a ban ever catches your own IP, it only affects the Oracle VPSes or the
tunnel apps — never cluster access, which is Twingate → LAN and touches
neither. Delete it on the engine that issued it:

```
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions delete --ip <ip>   # tunnel apps
ssh oracle-monero-jumphost sudo cscli decisions delete --ip <ip>                   # Oracle VPSes
```

Bouncers pick that up within their poll interval (~60s), no git round-trip. If
an Oracle ban blocks SSH to both VPSes, use the OCI Console's instance console
connection on monero-jumphost.

Three allowlists guard against this, and they must be kept in sync by hand:

1. **Cluster LAPI** `trusted-admin` (`cscli allowlists inspect trusted-admin`
   in the LAPI pod) — applies to the traefik bouncer. Lives in the LAPI database.
2. **Oracle LAPI** `trusted-admin`
   (`ssh oracle-monero-jumphost sudo cscli allowlists inspect trusted-admin`)
   — applies to both Oracle bouncers. Lives in that LAPI's database.
3. **Parser whitelist** in `values.yaml` (`config.parsers.s02-enrich`) — GitOps,
   drops cluster events before they can become alerts.

Home egress is **Starlink CGNAT and rotates**; re-add it on **both** engines
when it changes: `cscli allowlists add trusted-admin <ip> -d "home"`.

### Testing a bouncer without banning yourself

Replay an IP through traefik from inside the pod network (trusted for XFF),
rather than banning your own address:

```
kubectl exec -n crowdsec deploy/crowdsec-lapi -- wget -qS -O /dev/null \
  --header="Host: status.asandov.com" --header="X-Forwarded-For: <banned-ip>" \
  http://traefik.traefik.svc.cluster.local:8081/
```

Banned → 403, clean → 200.

## Gotchas that cost us time

- **LAPI secrets must stay SOPS-pinned.** Kustomize re-renders the chart on
  every sync, so chart-generated random secrets would churn and break agent
  auth. Never drop `secrets.externalSecret`.
- **Acquisition `labels.type` must equal the hub parser's `program` filter**
  exactly. Check the parser source, don't guess.
- **VictoriaLogs tail mode starts at "now"** — no replay across processor
  restarts, and crowdsec#3653 means the processor exits if VL is unreachable
  past `max_failure_duration` (raised to 10m here).
- **Keep the VPS agent version ≤ LAPI version.** The packagecloud repo ships
  newer than 1.7.8; it is pinned deliberately.
- **New VMServiceScrapes need a vmagent restart** — its Role can't hot-reload
  and the CR status lies about it.

## Known issues

### Authentik detection is broken

`firix/authentik-logs`: thousands of hits, zero parsed. Two independent causes:

1. The parser expects the whole JSON in the log line
   (`JsonExtract(evt.Parsed.message, 'action')`), but the VictoriaLogs
   collector **flattens** JSON — `action`, `client_ip` and `identifier` become
   separate VL fields and CrowdSec only receives the short `_msg`
   (`"invalid_login"`). A LogsQL `format` pipe rebuilds the JSON correctly in
   query mode but **tail mode rejects it with a 500**, and tail is what the
   datasource uses.
2. Authentik records `client_ip` as the **cloudflared pod IP**, not the real
   client, so even with parsing fixed the private-range whitelist would
   discard every event. Routing was ruled out — only one `cloudflare-tunnel`
   Ingress exists and it points at traefik. This is Authentik's own
   X-Forwarded-For handling; note its default trusted CIDRs already include
   `10.0.0.0/8`, so the obvious setting is not the answer.

Best path is probably to skip VictoriaLogs for Authentik entirely: Authentik
webhook notification transport → CrowdSec `http` datasource, which carries
the real IP and structured fields directly.

### Jellyseerr detection unverified

Its `/api/v1/auth/*` endpoints returned 500 under test without logging a
failed-login line. It authenticates against Jellyfin anyway, so that surface
is largely covered by the jellyfin scenarios.

## Todo / investigate later

- [ ] **Fix Authentik detection** (above). Highest-value gap — Authentik is the
      front door to everything.
- [ ] **Verify jellyseerr detection**, or confirm it is redundant.
- [ ] **AppSec / WAF.** Now unlocked because traefik sits in the request path;
      the bouncer plugin already speaks it (`crowdsecAppsecEnabled`). Blocks
      individual malicious requests (SQLi/XSS, CVE virtual patching) rather
      than just patterns.
- [ ] **Notifications.** CrowdSec notification plugins → the existing
      Alertmanager, so attacks surface without going and looking.
- [ ] **Cloudflare Worker bouncer.** Now largely redundant since the traefik
      plugin blocks the same traffic at origin; only adds edge bandwidth
      savings. Decided config if revisited: free plan, hard ban,
      `only_include_decisions_from: ["crowdsec","cscli"]` (blocklists would
      blow the 1k/day KV write quota). Needs a Cloudflare **user** API token.
- [ ] **OPNsense satellite.** Low value with no inbound forwards — visibility
      and shared telemetry only.
- [ ] **Audit other JSON-logging apps** for the flattening problem in
      "Known issues" — any app whose JSON message key is not in the
      collector's `msgField` list is silently invisible to both VL search and
      CrowdSec.
- [ ] **Watch LAPI PVC growth** (1Gi). Fine at ~26k decisions; revisit before
      subscribing more large blocklists.
