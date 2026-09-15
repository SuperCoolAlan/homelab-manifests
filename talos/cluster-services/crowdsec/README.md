# CrowdSec

Crowd-sourced intrusion detection and remediation, split across five engines
(LAPIs): this cluster's, and one on each Oracle VPS (monero-jumphost,
jelly-jumphost, snowflake-jumphost and signal-proxy), because their exposure differs. Bans are not shared between
engines; each gets CAPI plus its own Console blocklist subscriptions.

Deployed 2026-08-31. Phased plan and rationale: `docs/crowdsec-plan.md`.

## Topology

```
  cluster (ns: crowdsec)                   Oracle VCN 10.67.0.0/24
  ┌──────────────────────────────────┐     ┌─────────────────────────────────────┐
  │ LAPI (crowdsec-lapi) :8080       │     │ monero-jumphost 10.67.0.60          │
  │   SQLite on fast-array PVC       │     │   LAPI 127.0.0.1:8080               │
  │   ▲                              │     │   ├─ agent (sshd)                   │
  │   ├─ log processor               │     │   └─ nftables bouncer               │
  │   │  (VictoriaLogs, 5 streams)   │     ├─────────────────────────────────────┤
  │   └─ traefik bouncer plugin      │     │ jelly-jumphost 10.67.0.152          │
  │      enforces on tunnel apps     │     │   LAPI 127.0.0.1:8080               │
  └──────────────────────────────────┘     │   ├─ agent (caddy + sshd)           │
                                           │   └─ nftables bouncer (oracle-fw)   │
                                           └─────────────────────────────────────┘
```

Each Oracle engine is self-contained and binds to localhost only; nothing
CrowdSec-related crosses the VCN or the WireGuard tunnels. Box-level details:
`docs/oracle-wireguard-jumphost.md`.

## What is deployed

| Component | Where | State |
|---|---|---|
| LAPI | this dir, `crowdsec-lapi` Deployment | live, enrolled in Console as `talos-ramhaus` |
| Log processor | this dir, `crowdsec-agent` Deployment | live, reads VictoriaLogs (no DaemonSet) |
| monero engine | monero-jumphost, apt `crowdsec` 1.7.8 + `crowdsec-firewall-bouncer-nftables` 0.0.36 (held) | live, Console `oracle-monero-jumphost`, bouncer `cs-firewall-bouncer-monero` |
| jelly engine | jelly-jumphost, same packages (held) | live since 2026-09-14, Console `oracle-jellyfin-jumphost`, bouncer `oracle-fw` |
| snowflake engine | snowflake-jumphost, same packages (held) | live since 2026-09-15, Console `oracle-snowflake-jumphost`, bouncer `cs-firewall-bouncer-1789489309` |
| signal engine | signal-proxy, same packages (held) | live since 2026-09-15, Console `oracle-signal-proxy`, bouncer `cs-firewall-bouncer-1789492027` |
| Traefik bouncer | `cluster-services/traefik` (plugin + Middleware) | live, bouncer `traefik-bouncer` |
| Web UI | this dir, `web-ui.yaml` (crowdsec-web-ui) | `crowdsec.local.asandov.com`, machine `crowdsec-web-ui` on all five LAPIs |
| LAPI tunnel peers | `talos/crowdsec-lapi-tunnel` | WG peers `10.100.0.5` (jelly) / `10.100.0.6` (monero) / `10.100.0.11` (snowflake) / `10.100.0.13` (signal); only path into the Oracle LAPIs |
| AppSec / WAF | — | not deployed |
| Cloudflare Worker bouncer | — | not deployed (see Todo) |
| OPNsense satellite | — | not deployed |

### Detection coverage

| Source | Acquisition | Verified working |
|---|---|---|
| Traefik access logs (all tunnel apps) | `type: traefik` | yes — HTTP probing / CVE / scanners |
| Caddy access logs (jellyfin) | file, jelly engine | yes |
| sshd (jelly-jumphost) | journald, jelly engine | yes — catches real brute force daily |
| sshd (monero-jumphost) | journald, monero engine | **unverified** |
| Jellyfin | `type: jellyfin` | yes — end-to-end, real client IP |
| Immich | `type: immich` | yes — logs real client IP natively |
| Jellyseerr | `type: jellyseerr` | **unverified** — local auth endpoints 500'd under test |
| Authentik | `type: authentik` | **broken** — see Known issues |

### Enforcement

- **Tunnel apps** (auth, photos, jellyseerr, status): traefik bouncer plugin.
- **jellyfin.asandov.com + VPS sshd**: nftables bouncer on each Oracle VPS,
  fed by that VPS's own LAPI. monero-jumphost's bouncer also drops banned IPs
  on the forwarded monerod P2P path (18080).
- **Home WAN**: nothing — no inbound forwards, default-deny already covers it.

Cluster LAPI decisions come from our own scenarios plus CAPI (community) and
three subscribed blocklists (FireHOL GreenSnow, FireHOL BotScout, OTX
honeypot). ~26k enforced; roughly 24.5k are pre-emptive blocklist entries and
a handful are live local detections. Each Oracle engine gets CAPI plus whatever
it is subscribed to in the Console; subscriptions are per engine, so nothing
carries over between the three.

## Operating it

**crowdsec-web-ui** at `crowdsec.local.asandov.com` and `crowdsec.asandov.com`
shows all three engines in one place (authentik forward-auth, then OIDC via
auth.asandov.com; "ArgoCD Admins" get admin). The public host's forward-auth
comes from the authentik-managed `public-proxy` outpost (provider
`crowdsec-public`, deployment `ak-outpost-public-proxy`, not in git) because
the embedded outpost redirects browsers to auth.local.asandov.com. It
reaches the Oracle LAPIs through `talos/crowdsec-lapi-tunnel`: one WireGuard
peer pod per VPS, a NetworkPolicy that admits only the web-ui pod, and a VPS
INPUT rule that accepts 8080 only from that peer. The Oracle LAPIs listen on
`0.0.0.0:8080`; the host firewall and the OCI security list (no 8080 rule) are
what keep them off the internet. Alert deletion from the UI is intentionally
unavailable (no `trusted_ips` entry); decisions work.

Visibility also comes from:

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
ssh oracle-monero-jumphost sudo cscli decisions delete --ip <ip>                   # monero VPS
ssh oracle-jellyfin-jumphost sudo cscli decisions delete --ip <ip>                 # jellyfin VPS
```

Bouncers pick that up within their poll interval (~60s), no git round-trip. If
a ban blocks SSH to a VPS, use the OCI Console's instance console connection on
that VPS (or SSH from the other one over the VCN).

Three LAPI allowlists guard against this, kept in sync by hand. Admin IPs are
never committed to git — they live only in each LAPI's database:

1. **Cluster LAPI** `trusted-admin` (`cscli allowlists inspect trusted-admin`
   in the LAPI pod) — applies to the traefik bouncer. Lives in the LAPI database.
2. **monero engine** `trusted-admin`
   (`ssh oracle-monero-jumphost sudo cscli allowlists inspect trusted-admin`).
3. **jelly engine** `trusted-admin`
   (`ssh oracle-jellyfin-jumphost sudo cscli allowlists inspect trusted-admin`).

Home egress is **Starlink CGNAT and rotates**; re-add it on **every** engine
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
- **`cscli bouncers delete <name>` also deletes every `<name>@<ip>` row**, which
  revokes the key for the live bouncer too. Delete stale `@ip` rows by full name.

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
