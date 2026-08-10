# unifi-controller — migration off TrueNAS

Two-phase. **Phase 1 is live now**; Phase 2 is the actual move.

Estate is a **single U6+ AP at 10.0.1.11**, which makes the usual "strand every
device" risk small — worst case is one `ssh ubnt@10.0.1.11` to re-point it.

---

## Phase 1 — DNS only ✅ deployed

`kustomization.yaml` currently lists only `namespace.yaml` and `dns.yaml`, so this
app manages one A record and nothing else:

```
unifi.asandov.local  →  10.0.1.14   (TrueNAS, where the controller still runs)
```

**Then, in the controller UI:** Settings → System → Advanced →
**Override Inform Host** → `unifi.asandov.local`.

The AP picks that up on its next inform cycle. From then on it is chasing a
*name*, so the move is a DNS change rather than a device reconfiguration.

Verify before going further:

```sh
dig +short unifi.asandov.local          # 10.0.1.14

CTRL=https://truenas.asandov.local:8443
curl -sk -c /tmp/unifi.jar -X POST $CTRL/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"ADMIN","password":"PASSWORD"}'
curl -sk -b /tmp/unifi.jar $CTRL/api/s/default/stat/device \
  | jq -r '.data[] | "\(.name)\t\(.ip)\t\(.state)\tinform=\(.inform_url)"'
```

`state: 1` = Connected. **Do not start Phase 2 until `inform_url` contains
`unifi.asandov.local`.**

---

## Phase 2 — the move

### 1. Back up, the supported way

Controller UI → Settings → System → Backup → **Download** a `.unf`.

Use this, **not** a copy of `/usr/lib/unifi/data`. That directory is a live
MongoDB store; every other migration in this project was a filesystem copy with
md5 verification, which worked because those payloads were plain files. A running
Mongo is not. `.unf` restore is the supported path and handles schema properly.

### 2. Enable the workload

Uncomment the four resources in `kustomization.yaml`:

```yaml
  - pvc.yaml
  - service.yaml
  - deployment.yaml
  - ingress.yaml
```

Push. The new controller starts empty at `10.0.7.202`, UI at
`https://unifi.local.asandov.com`.

### 3. Restore

Browse to the UI, choose **Restore from backup**, upload the `.unf`. Version is
pinned to `goofball222/unifi:9.3.43` to match TrueNAS exactly — UniFi has no
downgrade path, and a backup restores cleanly only into the same or newer
version.

### 4. Stop the old controller

Disable the TrueNAS `unifi-controller` app. **Two controllers must not run
against one AP.** Do this before flipping DNS.

### 5. Flip DNS

In `dns.yaml`, change the target:

```yaml
      targets:
        - 10.0.7.202     # was 10.0.1.14
```

Push. The AP follows on its next inform cycle.

### 6. Verify

```sh
dig +short unifi.asandov.local          # 10.0.7.202
kubectl get svc unifi -n unifi          # EXTERNAL-IP 10.0.7.202
curl -sk -o /dev/null -w '%{http_code}\n' https://unifi.local.asandov.com/
```

Then confirm the AP shows **Connected** in the new controller. If it does not
within ~10 minutes:

```sh
ssh ubnt@10.0.1.11
set-inform http://unifi.asandov.local:8080/inform
```

---

## Design notes

**Why a LoadBalancer and an Ingress.** Devices need 8080/tcp plus UDP 3478 and
10001. Traefik listens on 80, 443 and 389 only, so it cannot carry any of that —
hence the LoadBalancer. The browser UI is layered on top as an ingress pointing
at port 8443 of the same Service, so it still gets a proper cert-manager cert
like every other local service.

**Why the IP is pinned.** `ldap-dns.yaml` hardcodes `10.0.7.201` describing it as
traefik, but traefik is `.200` — MetalLB later gave `.201` to piper, so that
record resolves to the wrong service. Here the Service pins `.202` via
`metallb.io/loadBalancerIPs` and `dns.yaml` hardcodes the same value, so the two
cannot drift.

**Why `external-dns.alpha.kubernetes.io/exclude` on the Service.** external-dns
has `sources: [ingress, service, crd]` and would otherwise publish a record from
the Service too, competing with `dns.yaml`. `dns.yaml` owns it, because the
record must exist and point at TrueNAS before this Service does.

**Why HTTPS to the backend.** UniFi's UI is HTTPS-only with a self-signed cert,
so the ingress needs `serversscheme: https` plus a `ServersTransport` with
`insecureSkipVerify`. The repo had no HTTPS-backend example before this — argocd
uses `h2c`, which is the cleartext-h2 case.
