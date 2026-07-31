#!/usr/bin/env bash
# Collect reproducible Waydroid/ADB/LAN/discovery evidence.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
env_file=${NETWORK_ENV:-$project_dir/config/network.env}
[[ -r $env_file ]] || env_file=$project_dir/config/network.env.example
# shellcheck disable=SC1090
source "$env_file"

usage() {
  cat <<'EOF'
Usage:
  test-network.sh all
  test-network.sh listen <port>
  test-network.sh send-broadcast <broadcast-ip> <port> [message]
  test-network.sh send-multicast <group> <port> [message]
  test-network.sh capture [seconds]

Run listen/send on different LAN machines for a genuine bidirectional test.
EOF
}

header() { printf '\n===== %s =====\n' "$*"; }
try() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@" || echo "WARN: command failed ($?)"; }
android_shell() {
  if [[ ${EUID} -eq 0 ]]; then
    waydroid shell -- "$@"
  else
    sudo waydroid shell -- "$@"
  fi
}

all_tests() {
  header 'Waydroid state'
  try waydroid status
  try timeout 30 waydroid session start
  try android_shell getprop ro.build.version.release

  header 'ADB'
  try adb devices -l
  try adb shell getprop

  header 'Host IP and routes'
  try ip -br addr
  try ip route
  header 'Android IP and routes'
  try android_shell ip addr
  try android_shell ip route

  header 'LAN unicast from host'
  [[ -n ${ROUTER_IP:-} ]] && try ping -c 3 -W 2 "$ROUTER_IP"
  [[ -n ${INTERCOM_IP:-} ]] && try ping -c 3 -W 2 "$INTERCOM_IP"
  header 'LAN unicast from Android'
  [[ -n ${ROUTER_IP:-} ]] && try android_shell ping -c 3 -W 2 "$ROUTER_IP"
  [[ -n ${INTERCOM_IP:-} ]] && try android_shell ping -c 3 -W 2 "$INTERCOM_IP"

  header 'Android framework network view'
  try android_shell dumpsys connectivity
  try android_shell cmd wifi status
  try android_shell dumpsys wifi
  try android_shell getprop dhcp.eth0.ipaddress
  echo "NOTE: <unknown ssid>/no Wi-Fi state is expected for Waydroid's veth/Ethernet transport."
  try android_shell sh -c 'dumpsys wifi | grep -i multicast'
  echo "NOTE: dumpsys can list locks but cannot acquire one. MulticastLock acquisition/receive must be"
  echo "      exercised by an APK declaring CHANGE_WIFI_MULTICAST_STATE; do not report it as tested here."

  header 'IGMP/multicast membership'
  try cat /proc/net/igmp
  try ip maddr show
  try android_shell cat /proc/net/igmp
  try android_shell ip maddr

  header 'mDNS and SSDP visibility'
  try avahi-browse --all --terminate
  if [[ ${EUID} -eq 0 ]]; then
    try timeout 5 tcpdump -ni "${HOST_LAN_IF}" 'udp port 5353 or udp port 1900'
    try timeout 5 tcpdump -ni "${WAYDROID_IF}" 'udp port 5353 or udp port 1900'
  else
    echo "INFO: packet capture skipped without root; run '$0 capture 30' separately."
  fi

  cat <<EOF

UDP proof requires two peers; this report does not label silence as success.
Receiver: $0 listen 37020
Sender:   $0 send-broadcast <LAN-broadcast-address> 37020
Repeat in the opposite direction and capture both ${HOST_LAN_IF}/${WAYDROID_IF}.
For Android-originated traffic, use an app that sends broadcast/multicast (and acquires
WifiManager.MulticastLock where required), while running '$0 capture 30'.
EOF
}

mode=${1:-all}
case "$mode" in
  all)
    all_tests
    ;;
  listen)
    [[ ${2:-} =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
    echo "Listening for UDP/$2; Ctrl-C to stop"
    exec socat -v "UDP4-RECVFROM:$2,fork,reuseaddr" STDOUT
    ;;
  send-broadcast)
    [[ $# -ge 3 && $3 =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
    printf '%s\n' "${4:-waydroid-broadcast-$(date +%s)}" | \
      socat - "UDP4-DATAGRAM:$2:$3,broadcast"
    ;;
  send-multicast)
    [[ $# -ge 3 && $3 =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
    lan_addr=$(ip -4 -o addr show dev "$HOST_LAN_IF" scope global | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')
    [[ -n $lan_addr ]] || { echo "ERROR: ${HOST_LAN_IF} has no global IPv4 address." >&2; exit 1; }
    printf '%s\n' "${4:-waydroid-multicast-$(date +%s)}" | \
      socat - "UDP4-DATAGRAM:$2:$3,ip-multicast-if=${lan_addr}"
    ;;
  capture)
    seconds=${2:-30}
    [[ $seconds =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
    if [[ ${EUID} -ne 0 ]]; then
      exec sudo NETWORK_ENV="$env_file" bash "$0" capture "$seconds"
    fi
    capture_filter='udp or igmp'
    [[ -z ${INTERCOM_IP:-} ]] || capture_filter="host ${INTERCOM_IP} or ${capture_filter}"
    timeout "$seconds" tcpdump -nni any -vv "$capture_filter"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
