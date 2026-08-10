# unifi-controller — migration off TrueNAS

Estate is a **single U6+ AP at 10.0.1.11** (firmware 6.7.54.15663), and SSH to it
works — so the usual "strand every device" risk is one command, not an afternoon.

## What the Override Inform Host attempt taught us

The original plan was to point devices at a DNS name while the old controller was
still serving, then flip the record. It did not survive contact:

1. **`.local` does not resolve on the AP.** Set to `unifi.asandov.local`, the U6+
   reported `Status: Unable to resolve`. `.local` is reserved for mDNS/Bonjour and
   the AP's resolver sends it to multicast instead of unicast DNS. OPNsense answered
   the record correctly the whole time (`dig @10.0.1.1` returned it) — the device
   just would not ask that way. macOS tolerates this; the AP does not. Hence
   `unifi-inform.local.asandov.com`, in a real unicast zone.

2. **Override Inform Host does not set the port.** TrueNAS serves inform on
   NodePort **30073**; this Deployment serves **8080**. Overriding only the host
   leaves the AP chasing `:30073` against a pod that is not listening there, so a
   manual `set-inform` at cutover is unavoidable regardless of DNS.

The override is now disabled and the AP is back on the controller default. The DNS
name is still worth having for any device added later — it just is not the
migration mechanism it was meant to be.

---

---

## The move

### 1. Back up, the supported way ✅ done

Controller UI → Settings → System → Backup → **Download** a `.unf`.

Use this, **not** a copy of `/usr/lib/unifi/data`. That directory is a live
MongoDB store; every other migration in this project was a filesystem copy with
md5 verification, which worked because those payloads were plain files. A running
Mongo is not. `.unf` restore is the supported path and handles schema properly.

Relevant: TrueNAS refuses its own v2 app upgrade with *"Upgrading to v2 is not
supported, due to incompatible embedded mongodb version… newer mongo requires AVX…
export the UniFi configuration, reinstall the app fresh and import"* — which is
this procedure. ramhaus has `avx` and `avx2`, so the constraint that blocked the
upgrade there does not apply here, and UniFi can be upgraded in-cluster afterwards.

### 2. Deploy ✅ done

All resources are live. The new controller starts empty at `10.0.7.202`, UI at
`https://unifi.local.asandov.com`.

Safe to run alongside the old one while it is still empty — the AP is still
informing to TrueNAS, so nothing is contested until step 5.

### 3. Restore

Browse to the UI, choose **Restore from backup**, upload the `.unf`. Version is
pinned to `goofball222/unifi:9.3.43` to match TrueNAS exactly — UniFi has no
downgrade path, and a backup restores cleanly only into the same or newer
version.

### 4. Stop the old controller

Disable the TrueNAS `unifi-controller` app. **Two controllers must not run
against one AP.** Do this before flipping DNS.

### 5. Re-point the AP

```sh
ssh ubnt@10.0.1.11
set-inform http://unifi-inform.local.asandov.com:8080/inform
```

The port change (30073 → 8080) is why this is manual rather than a DNS flip.

### 6. Verify

```sh
dig +short unifi-inform.local.asandov.com   # 10.0.7.202
kubectl get svc unifi -n unifi              # EXTERNAL-IP 10.0.7.202
curl -sk -o /dev/null -w '%{http_code}\n' https://unifi.local.asandov.com/
ssh ubnt@10.0.1.11 "mca-cli-op info"        # Status: Connected
```

If the AP does not appear, re-run `set-inform` — it is idempotent and some
firmware wants it twice.

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
