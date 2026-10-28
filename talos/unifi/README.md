# unifi-controller

Estate is a **single U6+ AP at 10.0.1.11**; SSH to it works (`ssh ubnt@10.0.1.11`).
Controller at `10.0.7.202`, UI at `https://unifi.local.asandov.com`.

## Inform

Devices inform to `http://unifi-inform.local.asandov.com:8080/inform`.

- **Not a `.local` name.** `.local` is reserved for mDNS/Bonjour and the AP's
  resolver sends it to multicast, so a `.local` inform host reports `Unable to
  resolve` even when OPNsense answers it. `local.asandov.com` is a real unicast zone.
- **Override Inform Host does not set the port.** The port comes from the
  controller, so a device informing anywhere other than `:8080` needs a manual
  `set-inform http://unifi-inform.local.asandov.com:8080/inform`. It is idempotent;
  some firmware wants it twice.

## Backups and upgrades

Back up from Settings → System → Backup (a `.unf`), never by copying
`/usr/lib/unifi/data`: that is a live MongoDB store. UniFi has no downgrade path
and a `.unf` restores only into the same or a newer version, so take one before
every image bump.

## Verify

```sh
dig +short unifi-inform.local.asandov.com   # 10.0.7.202
kubectl get svc unifi -n unifi              # EXTERNAL-IP 10.0.7.202
curl -sk -o /dev/null -w '%{http_code}\n' https://unifi.local.asandov.com/
ssh ubnt@10.0.1.11 "mca-cli-op info"        # Status: Connected
```

## Design notes

**Why a LoadBalancer and an Ingress.** Devices need 8080/tcp plus UDP 3478 and
10001. Traefik listens on 80, 443 and 389 only, so it cannot carry any of that —
hence the LoadBalancer. The browser UI is layered on top as an ingress pointing
at port 8443 of the same Service, so it still gets a proper cert-manager cert
like every other local service.

**Why the IP is pinned.** The Service pins `.202` via
`metallb.io/loadBalancerIPs` and `dns.yaml` hardcodes the same value, so the two
cannot drift.

**Why `external-dns.alpha.kubernetes.io/exclude` on the Service.** external-dns
has `sources: [ingress, service, crd]` and would otherwise publish a record from
the Service too, competing with `dns.yaml`, which owns the record.

**Why HTTPS to the backend.** UniFi's UI is HTTPS-only with a self-signed cert,
so the ingress needs `serversscheme: https` plus a `ServersTransport` with
`insecureSkipVerify`.
