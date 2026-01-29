# Oracle WireGuard Jumphost for Jellyfin

## Overview

Jellyfin is exposed to the internet via an Oracle Cloud VPS acting as a WireGuard jumphost. This setup bypasses Cloudflare proxy (which violates their ToS for video streaming) while keeping the home network secure.

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────┐
│  Oracle Cloud VPS                   │
│  163.192.195.190 (us-chicago-1)     │
│                                     │
│  ┌─────────────┐   ┌─────────────┐  │
│  │   Caddy     │──▶│  WireGuard  │  │
│  │  :443/:80   │   │   wg0       │  │
│  └─────────────┘   └──────┬──────┘  │
│                           │         │
└───────────────────────────┼─────────┘
                            │ WireGuard tunnel
                            │ 10.100.0.1 ◄─► 10.100.0.2
                            ▼
┌─────────────────────────────────────┐
│  TrueNAS (Home)                     │
│  10.100.0.2 (WireGuard)             │
│  Jellyfin :30013                    │
└─────────────────────────────────────┘
```

## Components

### Oracle VPS (163.192.195.190)

**Instance:** VM.Standard.A1.Flex (ARM, Always Free tier)
**Region:** us-chicago-1
**OS:** Ubuntu

#### WireGuard Server (`/etc/wireguard/wg0.conf`)
```ini
[Interface]
PrivateKey = <redacted>
Address = 10.100.0.1/32
ListenPort = 51820

[Peer]
PublicKey = l0ZdmMOQ+cK8tFg8AkKjNnfcjLohBkxizct6DL4i1lo=
AllowedIPs = 10.100.0.2/32
```

#### Caddy Reverse Proxy (`/etc/caddy/Caddyfile`)
```
jellyfin.asandov.com {
    reverse_proxy 10.100.0.2:30013 {
        transport http {
            read_timeout 0
            write_timeout 0
        }
        flush_interval -1
    }
}
```

#### Firewall Rules (nftables)

The VPS is locked down to only allow Jellyfin traffic through the tunnel:

```
table ip wg_restrict {
    chain output {
        type filter hook output priority filter; policy accept;
        oifname "wg0" tcp dport 30013 accept
        oifname "wg0" icmp type echo-request accept
        oifname "wg0" ct state established,related accept
        oifname "wg0" counter drop
    }
}
```

This ensures that if the Oracle VPS is compromised, the attacker cannot use the WireGuard tunnel to access anything other than Jellyfin on port 30013.

### TrueNAS (Home)

**WireGuard IP:** 10.100.0.2
**Jellyfin Port:** 30013 (DNAT to container port 8096)

The WireGuard client on TrueNAS connects outbound to Oracle on port 51820.

#### Firewall Rules (nftables)

Rules added to Docker's DOCKER-USER chain to restrict WireGuard traffic:

```bash
# Note: Must use container port 8096 (post-DNAT), not external port 30013
sudo nft add rule ip filter DOCKER-USER iifname "wg0" tcp dport 8096 accept
sudo nft add rule ip filter DOCKER-USER iifname "wg0" ct state established,related accept
sudo nft add rule ip filter DOCKER-USER iifname "wg0" counter drop
```

**Persistence:** Create `/usr/local/bin/wg-firewall.sh`:
```bash
#!/bin/bash
# Wait for Docker to initialize the chain
sleep 10
nft add rule ip filter DOCKER-USER iifname "wg0" tcp dport 8096 accept
nft add rule ip filter DOCKER-USER iifname "wg0" ct state established,related accept
nft add rule ip filter DOCKER-USER iifname "wg0" counter drop
```

Then add to crontab: `@reboot /usr/local/bin/wg-firewall.sh`

## DNS

`jellyfin.asandov.com` is configured in Cloudflare as **DNS Only** (not proxied), pointing to `163.192.195.190`.

## Security Considerations

1. **Oracle VPS firewall:** Only allows outbound traffic to TrueNAS on port 30013 via WireGuard
2. **WireGuard AllowedIPs:** Both sides use /32 to prevent routing to other IPs
3. **TrueNAS firewall:** Restricts incoming WireGuard traffic to only Jellyfin (port 8096 post-DNAT)
4. **No home IP exposure:** Home network's public IP is not exposed; Oracle VPS is the public endpoint
5. **Defense in depth:** Both endpoints have firewall rules - if Oracle is compromised, TrueNAS blocks lateral movement

## Maintenance

### SSH Access to Oracle VPS
```bash
ssh ubuntu@163.192.195.190
```

### Check WireGuard Status
```bash
# On Oracle
sudo wg show

# Check if tunnel is active (look for recent handshake)
```

### View Caddy Logs
```bash
sudo journalctl -u caddy -f
```

### Restart Services
```bash
sudo systemctl restart wg-quick@wg0
sudo systemctl restart caddy
```

## OCI CLI Access

Config file: `~/.oci/config`
API key: `~/.ssh/oci_api_key.pem`

```bash
# List instances
oci compute instance list --compartment-id <your-tenancy-ocid> --output table
```
