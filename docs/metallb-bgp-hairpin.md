# MetalLB BGP & the LAN hairpin

Why traffic from the LAN to a LoadBalancer IP takes an asymmetric path, why
that broke long-lived connections, and the OPNsense-side fix applied
2026-08-10. Read this before blaming BGP for connection drops.

## Topology

MetalLB advertises each LoadBalancer VIP as a `/32` over iBGP (AS 65000) to
OPNsense at `10.0.1.1`. The pool is `10.0.7.200-10.0.7.210`; the next-hops are
the Talos nodes, which live on `10.0.1.0/24`.

| Thing | Address |
|---|---|
| OPNsense (BGP peer, LAN gateway) | `10.0.1.1` on `em1` |
| talos-ramhaus | `10.0.1.12` |
| talos-blackbox | `10.0.1.47` |
| MetalLB pool | `10.0.7.200-10.0.7.210` |
| `.200` traefik / `.201` wyoming-piper / `.202` unifi | ETP `Cluster` / `Cluster` / `Local` |

The critical detail: **the VIP subnet's next-hops sit on the same L2 segment as
the LAN clients.** So a client at `10.0.1.x` talking to `10.0.7.x` produces:

```
client 10.0.1.21 ──► OPNsense 10.0.1.1 (em1) ──► node 10.0.1.12 (back out em1)
                                                        │
       ◄────────────── reply, direct on-link ───────────┘   (never re-crosses pf)
```

The request hairpins through the firewall; the reply does not. This is
**structural**, not a misconfiguration — no BGP change can fix it, because both
ends of the conversation are on one broadcast domain.

## The failure it caused

Symptoms: page loads dropping intermittently, large uploads to
`*.local.asandov.com` failing partway, jellyfin WebSockets disconnecting and
reconnecting in a loop.

pf only ever saw one direction, so state never reached ESTABLISHED. It therefore
aged on `tcp.first = 120s` instead of `tcp.established = 86400s`. At roughly two
minutes pf reaped the state; the next packet in the flow was a non-SYN with no
matching state, and got dropped. Short requests finished inside the window and
survived — long-lived or idle-ish ones did not, which is why it read as random.

Diagnostic signature in `pfctl -s state`:

```
tcp 10.0.7.202:8080 <- 10.0.1.11:42658    CLOSED:CLOSING      ← one-directional
udp 10.0.7.202:5514 <- 10.0.1.11:514      NO_TRAFFIC:SINGLE   ← ditto
```

`NO_TRAFFIC` / `CLOSED` on the peer half, and `N:0` packet counters, both mean
pf has seen zero return traffic.

## The fix

On OPNsense, the LAN rule covering the VIP range is set to **State Type =
sloppy** (`Firewall → Rules → LAN`, Advanced). Sloppy state drops the sequence
and window validation that requires observing both directions, so a one-sided
view still reaches `ESTABLISHED:ESTABLISHED` and ages on the 24-hour timer.

Healthy state now looks like:

```
tcp 10.0.7.200:443 <- 10.0.1.21:52929   ESTABLISHED:ESTABLISHED
   age 00:02:48, expires in 23:59:58, 3368:0 pkts, rule 108, sloppy
```

The `3368:0` is expected and permanent — the asymmetry is still there, pf just
tolerates it now.

The same rule's destination was widened from `10.0.7.200/29` to the
`Kubernetes_LoadBalancers` alias. A `/29` is only `.200-.207`, so the last three
addresses in the pool would have been silently unreachable from the LAN once
MetalLB got that far. **If the pool in `metallb-config.yaml` ever grows, update
that alias to match.**

Tradeoff: sloppy state weakens injection detection for these flows. Scoped to
LAN sources reaching an internal VIP range, which is an acceptable trade here.

### Gotcha: existing states are not converted

Changing the rule does **not** retroactively apply to states that already exist.
Connections opened under the old strict rule keep dying at 120s until they age
out, so things break one more time after the change before settling. Do not read
that as the fix having failed.

## Also fixed at the same time

OPNsense had a BGP neighbor `10.0.1.49` described as "talos-flyer". The real
second node is **talos-blackbox at `10.0.1.47`**, so that session had been in
`Active` (never established) for about 17 weeks and every VIP had exactly one
usable next-hop — a silent single point of failure. Corrected, and a bogus
`network 10.0.7.0/24` statement removed (OPNsense has no such connected route,
and `bgp network import-check` is on, so it sat invalid in the table).

**`configctl quagga restart` does not necessarily restart bgpd.** After the
config change, `frr.conf` on disk was correct but bgpd had 122 days of uptime and
had only *reloaded* — it picked up the new neighbor while keeping the stale one.
Removing it required applying `no neighbor 10.0.1.49` live via `vtysh`. Prefer
live `vtysh` edits over a bgpd restart anyway: a restart flaps the working
session and briefly withdraws every VIP route.

## Known limitation: no ECMP

`net.route.multipath = 0` on OPNsense, and the FRR plugin exposes no
`maximum-paths ibgp` field, so the kernel FIB installs one next-hop at a time
even though zebra holds both:

```
Routing entry for 10.0.7.200/32
  * 10.0.1.12, via em1, weight 1
  * 10.0.1.47, via em1, weight 1
```

**Failover works** (if the best path's peer drops, the other takes over).
Per-flow load balancing does not. Enabling multipath needs a tunable plus a
reboot, and would risk breaking flows for ETP `Cluster` services whenever the
next-hop changes mid-connection, since each node SNATs independently. Left off
deliberately.

## Do not use per-client static routes

A static `10.0.7.0/24 → 10.0.1.12` on a client bypasses the hairpin and was used
as a workaround before this fix. Don't. It pins every VIP to a single node, so
that client loses all LoadBalancer services when that node reboots, and it can't
be applied to appliances (the U6+ AP, for instance). The sloppy-state fix works
for every LAN device without touching them.

## The real long-term fix

Move the Talos nodes onto their own VLAN so client → VIP → node is genuinely
inter-subnet. The reply would then have to return via its gateway, pf would see
both directions, and strict state tracking could come back.

Deferred: it means re-IPing both nodes, and TrueNAS NFS exports are
host-restricted, so it's entangled with the TrueNAS migration work. Worth
folding in if the nodes are ever re-addressed for other reasons.
