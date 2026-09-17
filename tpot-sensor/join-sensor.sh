#!/usr/bin/env bash
# Join a T-Pot sensor to the hive without tpotce/deploy.sh, which needs a tty for
# Ansible's become prompt and reboots the sensor mid-run.
#
#   ./join-sensor.sh <name> <sensor-tunnel-ip> [hive-ssh-alias]
#
# Reads nothing from the sensor, writes both sides, restarts both.
set -euo pipefail

NAME="${1:?usage: join-sensor.sh <name> <sensor-tunnel-ip> [hive-alias]}"
SENSOR_IP="${2:?usage: join-sensor.sh <name> <sensor-tunnel-ip> [hive-alias]}"
HIVE="${3:-tpot}"
HIVE_TUNNEL_IP="10.101.0.2"
USER_NAME="sensor-${NAME}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

sensor() { ssh "${SSH_OPTS[@]}" -J "$HIVE" -p 64295 "alan@${SENSOR_IP}" "$@"; }
hive() { ssh "${SSH_OPTS[@]}" "$HIVE" "$@"; }

# No pipeline: head closing it would SIGPIPE tr, and pipefail+set -e would kill the script silently.
PW="$(openssl rand -hex 16)"
CRED_B64="$(printf '%s:%s' "$USER_NAME" "$PW" | base64 | tr -d '\n')"

echo "==> hive: adding ${USER_NAME} to LS_WEB_USER"
hive "cd ~/tpotce
  hb=\$(htpasswd -b -n '${USER_NAME}' '${PW}' | base64 -w0)
  cur=\$(grep '^LS_WEB_USER=' .env | sed 's/^LS_WEB_USER=//; s/\"//g')
  new=\$(echo \"\$cur \$hb\" | sed 's/^ *//; s/  */ /g')
  sudo sed -i \"s|^LS_WEB_USER=.*|LS_WEB_USER=\\\"\$new\\\"|\" .env"

echo "==> sensor: .env + hive certificate"
# logstash verifies the hive cert against data/hive.crt; without it the http output never starts.
hive 'sudo cat ~/tpotce/data/nginx/cert/nginx.crt' |
  sensor "sudo install -o tpot -g tpot -m644 /dev/stdin ~/tpotce/data/hive.crt"
sensor "cd ~/tpotce
  sudo sed -i 's|^TPOT_TYPE=.*|TPOT_TYPE=SENSOR|; \
              s|^TPOT_HIVE_IP=.*|TPOT_HIVE_IP=${HIVE_TUNNEL_IP}|; \
              s|^TPOT_HIVE_USER=.*|TPOT_HIVE_USER=${CRED_B64}|' .env"

echo "==> restarting both"
hive 'sudo systemctl restart tpot'
sensor 'sudo systemctl restart tpot'

# Keep the credential: rebuilding the hive's LS_WEB_USER later needs every sensor's password.
CRED_DIR="${CRED_DIR:-$HOME/.tpot-sensor-creds}"
mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
printf '%s:%s' "$USER_NAME" "$PW" > "${CRED_DIR}/${NAME}.cred"
chmod 600 "${CRED_DIR}/${NAME}.cred"

echo "==> joined ${USER_NAME} (${SENSOR_IP}); credential saved to ${CRED_DIR}/${NAME}.cred"
