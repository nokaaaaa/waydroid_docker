#!/usr/bin/env bash
# systemd wrapper for the device-specific discovery relay.
set -Eeuo pipefail

env_file=${1:-/etc/waydroid-same-lan.env}
[[ -r $env_file ]] || { echo "ERROR: cannot read $env_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

: "${HOST_LAN_IF:?HOST_LAN_IF is required}"
: "${WAYDROID_IF:=waydroid0}"
: "${ANDROID_LAN_IP:?ANDROID_LAN_IP is required}"
: "${LAN_PREFIX_LENGTH:?LAN_PREFIX_LENGTH is required}"

IFS=. read -r a b c d <<< "$ANDROID_LAN_IP"
ip_value=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
mask=$(( (0xffffffff << (32 - LAN_PREFIX_LENGTH)) & 0xffffffff ))
broadcast=$(( (ip_value & mask) | ((~mask) & 0xffffffff) ))
printf -v broadcast_ip '%d.%d.%d.%d' \
  $(( (broadcast >> 24) & 255 )) $(( (broadcast >> 16) & 255 )) \
  $(( (broadcast >> 8) & 255 )) $(( broadcast & 255 ))

exec /usr/local/libexec/waydroid-docker/aiphone-discovery-relay.py \
  --inside "$WAYDROID_IF" \
  --outside "$HOST_LAN_IF" \
  --source-ip "$ANDROID_LAN_IP" \
  --broadcast-ip "$broadcast_ip" \
  --port 51711 \
  --response-port 51712

