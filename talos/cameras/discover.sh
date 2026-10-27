#!/bin/sh
# Camera discovery: who am I on the LAN, who else is there, and which of them
# look like cameras. Everything goes to stdout for VictoriaLogs.
#
# Result lines are single-line JSON with a "msg" key, so the log collector
# flattens them into queryable fields (ip, mac, vendor, ports, ...). Raw tool
# output is printed as plain lines prefixed "camscan |" for context.
#
# Env:
#   SCAN_CIDRS    override the auto-detected subnet(s), space separated
#   EXTRA_CIDRS   scanned in addition to the auto-detected one (e.g. an IoT VLAN)
#   CAMERA_PORTS  TCP ports probed on every live host
set -eu

CAMERA_PORTS=${CAMERA_PORTS:-80,443,554,1935,2020,8000,8080,8443,8554,9000,34567,37777}
# OUIs and names seen on consumer/prosumer cameras and the chips inside them.
VENDOR_RE='reolink|hikvision|dahua|amcrest|lorex|axis|uniview|foscam|wyze|tp-link|tapo|eufy|anker|ezviz|imou|hangzhou|shenzhen|espressif|ubiquiti|annke|swann|arlo|ring|nest|google'

say()  { printf 'camscan | %s\n' "$*"; }
dump() { sed 's/^/camscan | /'; }
esc()  { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit() { printf '%s\n' "$1"; }

say "installing tools"
apk add --no-cache nmap nmap-scripts iproute2 net-tools >/dev/null

# --- 1. Identity -----------------------------------------------------------
say "=== identity ==="
say "hostname: $(hostname)"
say "--- ip -4 addr ---";  ip -4 addr | dump
say "--- ip route ---";    ip route | dump
say "--- ifconfig ---";    ifconfig -a 2>/dev/null | dump || true
say "--- resolv.conf ---"; dump < /etc/resolv.conf

IFACE=$(ip route show default | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
SELF_CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
SELF_IP=${SELF_CIDR%/*}
GATEWAY=$(ip route show default | awk '{print $3; exit}')
SELF_MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo unknown)
emit "{\"msg\":\"self\",\"iface\":\"$IFACE\",\"ip\":\"$SELF_IP\",\"cidr\":\"$SELF_CIDR\",\"mac\":\"$SELF_MAC\",\"gateway\":\"$GATEWAY\",\"node\":\"$(hostname)\"}"

CIDRS=${SCAN_CIDRS:-$SELF_CIDR}
[ -n "${EXTRA_CIDRS:-}" ] && CIDRS="$CIDRS $EXTRA_CIDRS"
say "scan targets: $CIDRS"

# --- 2. Host sweep ---------------------------------------------------------
# On the local segment nmap uses ARP, which also yields MAC + vendor. Routed
# subnets fall back to ICMP/TCP pings (no MAC).
say "=== host sweep ==="
# shellcheck disable=SC2086
nmap -sn -n -T4 --max-retries 2 $CIDRS -oN /tmp/sweep.txt >/dev/null
dump < /tmp/sweep.txt

awk '
  /^Nmap scan report for / { if (ip != "") print ip "\t" mac "\t" vendor; ip=$NF; mac=""; vendor="" }
  /^MAC Address: /         { mac=$3; v=$0; sub(/^[^(]*\(/, "", v); sub(/\)$/, "", v); vendor=v }
  END                      { if (ip != "") print ip "\t" mac "\t" vendor }
' /tmp/sweep.txt > /tmp/hosts.tsv

cut -f1 /tmp/hosts.tsv > /tmp/hosts.txt
LIVE=$(wc -l < /tmp/hosts.txt | tr -d ' ')
emit "{\"msg\":\"sweep-summary\",\"targets\":\"$CIDRS\",\"live\":$LIVE}"

while IFS="$(printf '\t')" read -r ip mac vendor; do
  emit "{\"msg\":\"host\",\"ip\":\"$ip\",\"mac\":\"$mac\",\"vendor\":\"$(esc "$vendor")\"}"
done < /tmp/hosts.tsv

# --- 3. Multicast discovery ------------------------------------------------
# ONVIF cameras answer WS-Discovery; many also speak UPnP/SSDP.
say "=== WS-Discovery / UPnP broadcast ==="
nmap -n -e "$IFACE" --script broadcast-wsdd-discover,broadcast-upnp-info \
  --script-args broadcast-wsdd-discover.timeout=10s 2>&1 | dump || true

# --- 4. Camera port probe --------------------------------------------------
say "=== port probe ($CAMERA_PORTS) ==="
if [ "$LIVE" -gt 0 ]; then
  nmap -n -T4 -Pn -sS -sV --version-light --script http-title,rtsp-methods \
    -p "$CAMERA_PORTS" --open -iL /tmp/hosts.txt \
    -oN /tmp/ports.txt -oG /tmp/ports.gnmap >/dev/null 2>&1 || true
  dump < /tmp/ports.txt

  # Greppable line: "Host: 10.0.1.5 ()  Ports: 554/open/tcp//rtsp//.../, 9000/open/..."
  grep 'Ports:' /tmp/ports.gnmap | while read -r line; do
    ip=$(printf '%s' "$line" | awk '{print $2}')
    ports=$(printf '%s' "$line" | sed 's/.*Ports: //; s/\tIgnored.*//' \
      | tr ',' '\n' | awk -F/ '$2=="open"{gsub(/ /,"",$1); printf "%s%s", sep, $1; sep=","}')
    services=$(printf '%s' "$line" | sed 's/.*Ports: //; s/\tIgnored.*//' \
      | tr ',' '\n' | awk -F/ '$2=="open"{gsub(/^ +/,"",$1); printf "%s%s:%s %s", sep, $1, $5, $7; sep="; "}')
    hostrow=$(awk -F'\t' -v ip="$ip" '$1==ip' /tmp/hosts.tsv)
    mac=$(printf '%s' "$hostrow" | cut -f2)
    vendor=$(printf '%s' "$hostrow" | cut -f3)
    emit "{\"msg\":\"open-ports\",\"ip\":\"$ip\",\"mac\":\"$mac\",\"vendor\":\"$(esc "$vendor")\",\"ports\":\"$ports\",\"services\":\"$(esc "$services")\"}"
  done
fi

# --- 5. Verdict ------------------------------------------------------------
# A host is a candidate if its vendor looks like a camera maker, or it has an
# RTSP / Reolink-media port open.
say "=== camera candidates ==="
FOUND=0
while IFS="$(printf '\t')" read -r ip mac vendor; do
  ports=$(grep "Host: $ip " /tmp/ports.gnmap 2>/dev/null | sed 's/.*Ports: //' \
    | tr ',' '\n' | awk -F/ '$2=="open"{gsub(/ /,"",$1); printf "%s%s", sep, $1; sep=","}' || true)
  why=""
  printf '%s' "$vendor" | grep -Eiq "$VENDOR_RE" && why="vendor"
  printf ',%s,' "$ports" | grep -Eq ',(554|8554|9000|1935|34567|37777),' && why="${why:+$why+}ports"
  if [ -n "$why" ]; then
    FOUND=$((FOUND + 1))
    emit "{\"msg\":\"camera-candidate\",\"ip\":\"$ip\",\"mac\":\"$mac\",\"vendor\":\"$(esc "$vendor")\",\"ports\":\"$ports\",\"reason\":\"$why\"}"
  fi
done < /tmp/hosts.tsv

emit "{\"msg\":\"done\",\"live\":$LIVE,\"candidates\":$FOUND}"
