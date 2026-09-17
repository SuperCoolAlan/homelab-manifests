# T-Pot sensor

The exposed half of the [T-Pot deployment](tpot-honeypot.md): a public cloud VM
running the honeypots, shipping every event to the hive VM at home. Attackers
only ever touch the sensor.

**Status (2026-09-17):** not deployed. Template and runbook only; the host is an
AWS Free plan instance being created (credits self-terminate the account, so the
sensor is disposable by design — everything needed to rebuild it is here).

## Why the tunnel is dialed from home

The sensor has to reach the hive on tcp/64294, but home is behind Starlink CGNAT
and cannot accept inbound connections. So the **sensor listens** for WireGuard
and the **hive dials out** and keeps the tunnel alive. Once up, the tunnel is
symmetric and the sensor pushes to the hive's tunnel address.

```
scanners, bots, attackers
    │ all ports
    ▼
┌───────────────────────────────┐
│ sensor (cloud, public IPv4)   │
│   honeypots + logstash        │
│   wg0 10.101.0.1  :51820 ◄────┼──── hive dials out, PersistentKeepalive
└───────────────┬───────────────┘
                │ logstash → 10.101.0.2:64294 (HTTPS via hive nginx)
                ▼
┌───────────────────────────────┐
│ hive VM (talos-ramhaus)       │
│   wg0 10.101.0.2              │
│   elasticsearch, kibana       │
└───────────────────────────────┘
```

`10.101.0.0/30` is the sensor tunnel. The Oracle jumphost mesh owns
`10.100.0.0/24` — do not overlap it.

Nothing in the cluster gains an ingress rule: the inner traffic arrives on the
hive's own `wg0` inside the guest, so Cilium only ever sees the encrypted UDP
flow the hive itself opened. The hive's egress policy already permits it (a
public IP is outside the excluded RFC1918 ranges).

## Host requirements

T-Pot's README asks for 8 GB RAM / 128 GB disk for a sensor, but that figure is
for the standard install. A sensor runs no Elasticsearch, Kibana, attack map or
spiderfoot; logstash's JVM is the largest process. **2 GB is the floor, 4 GB is
comfortable, 20–40 GB of disk is enough** — events live on the hive, only
captured samples and pcaps accumulate locally (`~/tpotce/data`, 30-day
retention).

Architecture is free: T-Pot's images are multi-arch (amd64 + arm64), so ARM
instances are fine and usually cheaper.

## Provisioning

1. **Instance:** Debian 13, 2–4 GB RAM, 30–40 GB disk, public IPv4.
2. **Fill in the template.** Copy `tpot-sensor/cloud-init.yaml`, replace every
   `PLACEHOLDER_` value, and paste it as user-data. Keys:
   ```bash
   wg genkey | tee sensor.key | wg pubkey > sensor.pub   # sensor's own keypair
   wg genkey | tee hive.key   | wg pubkey > hive.pub     # hive's keypair
   ```
   The filled copy holds the web password and a private key, so keep it out of
   git — encrypt it to `tpot-sensor/secrets/` if you want it kept:
   ```bash
   sops --encrypt --pgp 9D032060B05603F790D340F98B60D1C1CF8E1A50 \
     cloud-init.filled.yaml > tpot-sensor/secrets/tpot-sensor-cloud-init.enc.yaml
   ```
3. **Firewall / security group.** The point of a honeypot is to be reachable, so
   nearly everything is open — but management stays private:

   | Port | Source | Why |
   |---|---|---|
   | tcp/1–64000, udp/1–64000 | `0.0.0.0/0` | the honeypots; this is the bait |
   | udp/51820 | `0.0.0.0/0` | WireGuard. Home is CGNAT with a changing address, so it cannot be narrowed |
   | tcp/64294, 64295, 64297 | `10.101.0.2/32` only | management: log ingest, SSH, web UI — never public |

   T-Pot moves sshd to 64295 during install, so after the first reboot the only
   way in is through the tunnel. Keep the provider's serial console handy.
4. **Outbound.** Default-deny except the hive, package repos and DNS. A sensor
   that cannot make outbound connections cannot generate a *genuine* abuse
   complaint, which is what gets accounts terminated — inbound scanning is not.

## Joining the sensor to the hive

Use `tpot-sensor/join-sensor.sh <name> <sensor-tunnel-ip>`. It does what
`deploy.sh` does, minus the parts that make `deploy.sh` unusable non-interactively:
Ansible's become prompt needs a real tty, and its playbook reboots the sensor
mid-run, killing the SSH session that drives it.

Three things the join must get right; each one silently produces no events:

| Requirement | Symptom when wrong |
|---|---|
| `data/hive.crt` on the sensor (the hive's nginx cert) | logstash: `File does not exist /data/hive.crt`, http_output pipeline never starts |
| One entry per user in the hive's `LS_WEB_USER` | nginx matches the first duplicate, sensor gets 401 |
| `TPOT_TYPE=SENSOR` before starting T-Pot | a sensor still labelled HIVE will not start at all |

The manual equivalent, if you need it:

1. **Bring up the hive's tunnel end.** `/etc/wireguard/wg0.conf` in the hive VM:
   ```ini
   [Interface]
   Address = 10.101.0.2/30
   PrivateKey = <hive.key>

   [Peer]
   PublicKey = <sensor.pub>
   Endpoint = <sensor public IP>:51820
   AllowedIPs = 10.101.0.1/32
   PersistentKeepalive = 25
   ```
   `PersistentKeepalive` is load-bearing: without it the CGNAT mapping expires
   and the sensor can no longer reach the hive.
   ```bash
   sudo systemctl enable --now wg-quick@wg0
   ping -c3 10.101.0.1
   ```
2. **Reissue the hive certificate with the tunnel IP as a SAN.** logstash on the
   sensor verifies the hive's certificate chain including SANs
   (`LS_SSL_VERIFICATION=full` by default), so the hive's cert must name
   `10.101.0.2`:
   ```bash
   sudo openssl req -nodes -x509 -sha512 -newkey rsa:8192 \
     -keyout "$HOME/tpotce/data/nginx/cert/nginx.key" \
     -out "$HOME/tpotce/data/nginx/cert/nginx.crt" \
     -days 3650 -subj '/C=US/O=asandov/CN=tpot-hive' \
     -addext "subjectAltName = IP:10.101.0.2, DNS:tpot.local.asandov.com"
   ```
   Traefik already skips verification of this cert (`serversTransport
   tpot-insecure`), so the web UI is unaffected. Restart T-Pot afterwards.
3. **Run the join.** `deploy.sh` reaches the sensor over SSH on 64295 — use the
   tunnel address, not the public IP, so 64295 stays closed to the internet:
   ```bash
   ssh-keygen                                   # empty passphrase, if no key yet
   ssh-copy-id -p 64295 alan@10.101.0.1
   cd ~/tpotce && ./deploy.sh
   ```
   It writes `TPOT_TYPE=SENSOR`, `TPOT_HIVE_IP` and a base64 `TPOT_HIVE_USER`
   into the sensor's `.env`, and the matching `LS_WEB_USER` on the hive. Each
   sensor gets its own user, so a second sensor is another run.

## Verify

```bash
ssh tpot 'ping -c3 10.101.0.1 && sudo wg show'
ssh -J tpot -p 64295 alan@10.101.0.1 'sudo docker ps --format "{{.Names}} {{.Status}}"'
# hive: events arriving from the sensor
curl -sk https://127.0.0.1:64297/es/_cat/indices?v          # run on the hive
```
Then watch Kibana at `https://tpot.local.asandov.com` — sensor events land in the
same indices, tagged by sensor.

## When the AWS credits run out

The account closes itself, so the sensor disappears with it. Nothing at home
breaks: the hive keeps every event already ingested, and the tunnel simply stops
handshaking. To move to another host, provision a new box with the same
user-data and re-run `deploy.sh`; only the `Endpoint` line in the hive's
`wg0.conf` changes.

## Not available in 24.04

Community data submission (ewsposter, Sicherheitstacho, HPFEEDS opt-in) does not
exist at this T-Pot version — there are no such variables in `.env` and no
`hpfeeds_optin.sh` in the tree. Sharing with an aggregator would mean adding a
logstash output or a separate hpfeeds client.
