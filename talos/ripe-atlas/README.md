# ripe-atlas

[RIPE Atlas](https://atlas.ripe.net/) software probe: runs measurements for RIPE NCC and the Atlas community from our Starlink connection. Outbound-only (it dials RIPE's controller), a few kbit/s.

Image: [`jamesits/ripe-atlas`](https://github.com/Jamesits/docker-ripe-atlas) — there is no official container or Helm chart.

## Registering

1. `kubectl -n ripe-atlas exec deploy/ripe-atlas -- cat /etc/ripe-atlas/probe_key.pub`
2. Apply at <https://atlas.ripe.net/apply/swprobe/> with that key (RIPE NCC Access account; approval is manual).
3. After approval the probe connects on its own.

## Notes

- The key in `/etc/ripe-atlas` (PVC `ripe-atlas-etc`) is the probe's identity. Back it up; a new key needs a new registration.
- IPv4 only: the cluster runs Cilium without IPv6.
- If the probe stays disconnected with no errors, clear its runtime state by restarting the pod (spool and run are `emptyDir`).
