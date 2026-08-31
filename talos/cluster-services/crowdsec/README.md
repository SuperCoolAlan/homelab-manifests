# CrowdSec

Crowd-sourced intrusion detection and remediation. Detection runs here in the
cluster and on the Oracle VPS; both report to one LAPI, and every bouncer
enforces every decision regardless of which sensor raised it.

Deployed 2026-08-31. Phased plan and rationale: `docs/crowdsec-plan.md`.

## Topology

```
                        ┌──────────────────── cluster (ns: crowdsec) ────────┐
                        │                                                    │
  Oracle VPS            │   LAPI (crowdsec-lapi)                             │
  ├─ agent  ────────────┼──►  :8080, SQLite on fast-array PVC                │
  │  caddy + sshd       │      ▲              ▲                              │
  └─ nftables bouncer ◄─┼──────┘              │                              │
     (oracle-fw)        │                     │                              │
        via WireGuard   │   log processor (crowdsec-agent)                   │
        10.100.0.2:8080 │   VictoriaLogs datasource, 5 acquisition streams   │
                        │                     │                              │
                        │   traefik bouncer plugin ◄── enforces on tunnel    │
                        └────────────────────────────────────────────────────┘
```

The VPS reaches LAPI through the `lapi-forwarder` socat container in the
`jellyfin-tunnel` pod (`talos/jellyfin-tunnel/deployment.yaml`), which needs
the wg0 egress rule for port 8080 in the VPS's `/etc/nftables.conf`.

## What is deployed

| Component | Where | State |
|---|---|---|
| LAPI | this dir, `crowdsec-lapi` Deployment | live, enrolled in Console as `talos-ramhaus` |
| Log processor | this dir, `crowdsec-agent` Deployment | live, reads VictoriaLogs (no DaemonSet) |
| VPS agent | Oracle VPS, apt `crowdsec` 1.7.8 | live, machine `oracle-jellyfin-jumphost` |
| VPS bouncer | Oracle VPS, `crowdsec-firewall-bouncer-nftables` | live, bouncer `oracle-fw` |
| Traefik bouncer | `cluster-services/traefik` (plugin + Middleware) | live, bouncer `traefik-bouncer` |
| AppSec / WAF | — | not deployed |
| Cloudflare Worker bouncer | — | not deployed (see Todo) |
| OPNsense satellite | — | not deployed |

### Detection coverage

| Source | Acquisition | Verified working |
|---|---|---|
| Traefik access logs (all tunnel apps) | `type: traefik` | yes — HTTP probing / CVE / scanners |
| Caddy access logs (jellyfin) | file, on VPS | yes |
| sshd (VPS) | journald, on VPS | yes — catches real brute force daily |
| Jellyfin | `type: jellyfin` | yes — end-to-end, real client IP |
| Immich | `type: immich` | yes — logs real client IP natively |
| Jellyseerr | `type: jellyseerr` | **unverified** — local auth endpoints 500'd under test |
| Authentik | `type: authentik` | **broken** — see Known issues |

### Enforcement

- **Tunnel apps** (auth, photos, jellyseerr, status): traefik bouncer plugin.
- **jellyfin.asandov.com + VPS sshd**: nftables bouncer on the VPS.
- **Home WAN**: nothing — no inbound forwards, default-deny already covers it.

Decisions come from our own scenarios plus CAPI (community) and three
subscribed blocklists (FireHOL GreenSnow, FireHOL BotScout, OTX honeypot).
~26k enforced; roughly 24.5k are pre-emptive blocklist entries and a handful
are live local detections.

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

If a ban ever catches your own IP, it only affects the VPS and the tunnel
apps — never cluster access, which is Twingate → LAN and touches neither.
So the fix is always reachable:

```
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions delete --ip <ip>
```

Bouncers pick that up within their poll interval (~60s), no git round-trip.

Two allowlists guard against this, and they must be kept in sync by hand:

1. **LAPI centralized** `trusted-admin` (`cscli allowlists inspect trusted-admin`)
   — applies to all bouncers. Not GitOps-able; lives in the LAPI database.
2. **Parser whitelist** in `values.yaml` (`config.parsers.s02-enrich`) — GitOps,
   drops events before they can become alerts.

Home egress is **Starlink CGNAT and rotates**; re-add it when it changes:
`cscli allowlists add trusted-admin <ip> -d "home"`.

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
