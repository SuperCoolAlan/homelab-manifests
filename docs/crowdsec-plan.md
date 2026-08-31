# CrowdSec assessment and rollout plan

Written 2026-08-31, researched against CrowdSec v1.7.8 / helm chart 0.24.0.
Status: assessment — nothing deployed yet.

## What we're protecting

| Surface | Path | Real client IP visible? | Directly attackable? |
|---|---|---|---|
| auth.asandov.com (Authentik) | CF Tunnel → Service | via `CF-Connecting-IP` header | edge only |
| photos.asandov.com (Immich) | CF Tunnel → Service | via header | edge only |
| jellyseerr.asandov.com | CF Tunnel → Service | via header | edge only |
| status.asandov.com (Gatus) | CF Tunnel → Service | via header | edge only |
| jellyfin.asandov.com | Oracle VPS Caddy → WG → socat → k8s | yes, at Caddy | **yes — VPS fully exposed** |
| Oracle VPS sshd :22 | direct | yes | **yes** |
| Home WAN (OPNsense) | no inbound forwards | n/a | no |

The Oracle VPS is the only thing on the internet without Cloudflare in front
of it, and it also exposes sshd. It is the highest-value target for both
detection and blocking.

## How the pieces fit (CrowdSec architecture)

CrowdSec = **log processors** (parse logs, run scenarios, raise alerts)
→ **LAPI** (central decision store) → **remediation components / bouncers**
(enforce bans wherever traffic can actually be stopped). All components can
be distributed; one LAPI can serve many machines and bouncers, and a ban
raised by any log processor is enforced by every bouncer.

## Recommended architecture

```
                    ┌────────────────────────────────────────────┐
                    │ k8s (monitoring/crowdsec ns)               │
  Oracle VPS        │  ┌──────────┐   ┌───────────────────────┐  │
  agent (caddy,     │  │  LAPI    │◄──│ log processor (1 pod) │  │
  sshd logs) ──────►│  │ :8080    │   │ VictoriaLogs datasource│ │
  fw bouncer ◄──────│  └──▲───┬───┘   │ jellyfin/authentik/    │ │
  (nftables)        │     │   │       │ immich/jellyseerr      │ │
   via WG tunnel    │     │   │       └───────────────────────┘  │
                    └─────┼───┼──────────────────────────────────┘
     OPNsense ────────────┘   └───────► Cloudflare Worker bouncer
     satellite (optional)               (edge blocking, optional)
```

### 1. Central LAPI + VictoriaLogs log processor in k8s (phase 1)

Official helm chart (`crowdsecurity/crowdsec` 0.24.0):

- LAPI as a Deployment, ClusterIP :8080.
- Agent as a **single-replica Deployment** (`agent.isDeployment: true`,
  `agent.hostVarLog: false`) — no hostPath DaemonSet. CrowdSec ≥1.6.5 has a
  native **victorialogs datasource**; we point acquisition entries at
  `http://victoria-logs-victoria-logs-single-server.monitoring.svc:9428`
  with one LogsQL filter + `labels.type` per app. This rides the log
  pipeline fixed 2026-08-31 — detection is only as good as that pipeline.
- Hub collections: `LePresidente/jellyfin` (+ `crowdsecurity/jellyfin-whitelist`),
  `firix/authentik`, `gauth-fr/immich`, `LePresidente/jellyseerr`
  (+ `crowdsecurity/jellyseerr-whitelist`; jellyseerr/overseerr hub entries
  are being merged into "seerr" — expect renames).
- Enroll in the CrowdSec Console (free tier: 3 blocklists, community list,
  2-month retention) — this is what earns the community blocklist.
- Run **detection-only** first; watch alerts for false positives before
  adding any bouncer.

Caveats (from research):
- One `labels.type` per acquisition entry; the type must match the hub
  parser's expected program name.
- VL tail starts at "now" — no replay across processor restarts.
- Open bug crowdsec#3653: the processor exits if VL is down longer than
  `max_failure_duration` — raise it and let k8s restart the pod.
- Apps behind cloudflared must log the **forwarded** client IP
  (`CF-Connecting-IP`/XFF with cloudflared as trusted proxy), or scenarios
  see only pod IPs — which the default `crowdsecurity/whitelists` (private
  ranges) will silently discard. Verify per app before trusting detection.

### 2. Oracle VPS: agent + firewall bouncer (phase 2 — highest value)

> **Status 2026-08-31 (later): PHASE 2 COMPLETE — bouncer live.**
> crowdsec-firewall-bouncer-nftables 0.0.36 registered as `oracle-fw`
> against the central LAPI (same 10.100.0.2:8080 path), enforcing ~15k
> decisions (3 Console blocklists + community list + local bans).
> Lockout protection: LAPI centralized allowlist `trusted-admin` holds
> home + office egress IPs (home is Starlink CGNAT and rotates — refresh
> with `cscli allowlists add trusted-admin <ip>` when it changes), and the
> k8s log processor carries a matching GitOps parser whitelist in
> crowdsec/values.yaml. Verified: test decision propagated to the VPS
> nftables set in ~15s; allowlisted IPs filtered from bouncer streams.
> Recovery path if banned anyway: Twingate → kubectl exec →
> `cscli decisions delete --ip <ip>` (VPS bans never affect cluster access).
>
> Original notes (agent): crowdsec 1.7.8 (pinned
> to LAPI version) registered as `oracle-jellyfin-jumphost` via
> 10.100.0.2:8080 (lapi-forwarder socat in the jellyfin-tunnel pod; wg0
> egress rule for 8080 added live + in /etc/nftables.conf). Local API
> disabled via config.yaml.local. Caddy upgraded 2.6.2 → 2.11.4 from the
> official repo because the hub parser needs the `client_ip` log field
> (2.7+); JSON access log enabled in the Caddyfile. Collections: linux,
> caddy, http-cve (+ sshd, base-http-scenarios via deps). Verified: probe
> burst raised http-probing/sensitive-files/admin-interface-probing alerts
> on the central LAPI with true client IPs; ssh-bf already tracking live
> internet noise. Also found and fixed: apt update hung since April holding
> the lock — 4 months of security updates applied; **kernel update pending
> reboot**.

- Enable Caddy **JSON access logs** (default encoder — the
  `crowdsecurity/caddy` parser breaks on custom formats).
- Install crowdsec (log processor only) + `crowdsecurity/caddy`,
  `crowdsecurity/sshd`, `crowdsecurity/base-http-scenarios`,
  `crowdsecurity/http-cve` — this covers ssh brute force and HTTP
  probing/CVE scans with true client IPs (no CF in the way).
- Install `crowdsec-firewall-bouncer` in nftables mode — bans enforced at
  the VPS edge, where the only unprotected exposure lives.
- Register both against the central LAPI. Network path: the existing
  WireGuard tunnel — add a second socat forward in the jellyfin-tunnel pod
  (`:8080 → crowdsec-lapi.monitoring.svc`) so the VPS reaches LAPI at
  `10.100.0.2:8080`. Port must be opened in the VPS nftables egress rules
  for wg0 (same load-bearing rule set as 30013). Fallback if we dislike the
  coupling: run the VPS fully standalone (own LAPI) and lose shared bans.

### 3. Cloudflare edge blocking (phase 3 — optional)

The tunnel apps can only be *blocked* at Cloudflare's edge or by inserting
a proxy in-cluster:

- **Option A — cs-cloudflare-worker-bouncer** (the maintained one; the old
  API bouncer is deprecated): Worker + KV checks every request, supports
  Turnstile challenges. Free-plan quotas are marginal (100k req/day,
  **1,000 KV writes/day** — subscribing blocklists blows through it);
  CrowdSec recommends the $5/mo Workers plan. Start with local decisions
  only (no extra blocklists synced to CF) if staying free.
- **Option B — route tunnel ingresses through Traefik** (cloudflared →
  Traefik → Service) and use the Traefik bouncer plugin, which also unlocks
  the **AppSec/WAF** component (virtual patching, SQLi/XSS rules). Bigger
  refactor of the cloudflare-tunnel-ingress-controller setup; revisit after
  phases 1–2 prove out.

### 4. OPNsense satellite (phase 4 — optional, low value here)

The official `os-crowdsec` plugin (log processor + pf firewall bouncer) has
GUI-supported "Manual LAPI configuration" for pointing at our central LAPI.
With zero inbound port forwards its protective value is mostly visibility
(WAN scan detection, GUI/ssh brute-force on the admin plane) — default-deny
already drops what the bouncer would drop. Worth doing eventually for the
shared-decision telemetry; not first. Gotchas: FreeBSD package lags upstream
(keep central LAPI ≥ agent version), and Overview tab shows wrong
machine/bouncer lists in satellite mode (cosmetic).

## What CrowdSec does NOT give us here

- No blocking for CF-tunnel apps without phase 3 (detection still works and
  feeds bans enforced elsewhere, e.g. the VPS).
- No AppSec/WAF without a reverse proxy in the request path (cloudflared
  has no hooks).
- Nothing meaningful for egress/lateral movement — it is an inbound tool.

## Suggested order

1. Helm chart in-cluster (LAPI + VL log processor), console enrollment,
   detection-only. Validate each app's parser fires (test with a couple of
   deliberate failed logins) and that real client IPs appear in alerts.
2. Oracle VPS: Caddy access logs + agent + nftables bouncer + LAPI-over-WG.
3. Decide on Cloudflare edge blocking (worker bouncer vs Traefik insert)
   based on what phase 1 alerts actually show.
4. OPNsense satellite if we still want it.
