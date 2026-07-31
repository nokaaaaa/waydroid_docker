#!/usr/bin/env bash
# Give Waydroid a secondary address from the host LAN through routed proxy ARP.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: this helper must run as root." >&2
  exit 1
fi

env_file=${1:-/etc/waydroid-same-lan.env}
[[ -r $env_file ]] || { echo "ERROR: cannot read $env_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

: "${HOST_LAN_IF:?HOST_LAN_IF is required}"
: "${WAYDROID_IF:=waydroid0}"
: "${ANDROID_LAN_IP:?ANDROID_LAN_IP is required}"
: "${LAN_PREFIX_LENGTH:?LAN_PREFIX_LENGTH is required}"
: "${ANDROID_WIFI_COMPAT_IF:=wlan0}"

[[ $HOST_LAN_IF =~ ^[a-zA-Z0-9_.:-]+$ && $WAYDROID_IF =~ ^[a-zA-Z0-9_.:-]+$ ]] || {
  echo "ERROR: invalid interface name." >&2
  exit 1
}
[[ $ANDROID_WIFI_COMPAT_IF =~ ^[a-zA-Z0-9_.:-]+$ ]] || {
  echo "ERROR: invalid ANDROID_WIFI_COMPAT_IF." >&2
  exit 1
}
[[ $ANDROID_LAN_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "ERROR: invalid ANDROID_LAN_IP." >&2
  exit 1
}
[[ $LAN_PREFIX_LENGTH =~ ^([1-9]|[12][0-9]|3[01])$ ]] || {
  echo "ERROR: LAN_PREFIX_LENGTH must be between 1 and 31." >&2
  exit 1
}

IFS=. read -r ip_a ip_b ip_c ip_d <<< "$ANDROID_LAN_IP"
for octet_text in "$ip_a" "$ip_b" "$ip_c" "$ip_d"; do
  ((10#$octet_text >= 0 && 10#$octet_text <= 255)) || {
    echo "ERROR: invalid ANDROID_LAN_IP." >&2
    exit 1
  }
done
ip_a=$((10#$ip_a)); ip_b=$((10#$ip_b)); ip_c=$((10#$ip_c)); ip_d=$((10#$ip_d))
ip_value=$(( (ip_a << 24) | (ip_b << 16) | (ip_c << 8) | ip_d ))
network_mask=$(( (0xffffffff << (32 - LAN_PREFIX_LENGTH)) & 0xffffffff ))
network_value=$(( ip_value & network_mask ))
printf -v lan_network '%d.%d.%d.%d/%d' \
  $(( (network_value >> 24) & 255 )) \
  $(( (network_value >> 16) & 255 )) \
  $(( (network_value >> 8) & 255 )) \
  $(( network_value & 255 )) \
  "$LAN_PREFIX_LENGTH"

ip link show "$HOST_LAN_IF" >/dev/null

pid=
for _ in $(seq 1 60); do
  pid=$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH 2>/dev/null || true)
  if [[ $pid =~ ^[0-9]+$ ]] && ip link show "$WAYDROID_IF" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ $pid =~ ^[0-9]+$ ]] || { echo "ERROR: Waydroid container is not running." >&2; exit 1; }
ip link show "$WAYDROID_IF" >/dev/null || {
  echo "ERROR: Waydroid interface $WAYDROID_IF was not created." >&2
  exit 1
}

ip route replace "$ANDROID_LAN_IP/32" dev "$WAYDROID_IF"
sysctl -qw "net.ipv4.conf.${HOST_LAN_IF}.proxy_arp=1"
sysctl -qw "net.ipv4.conf.${WAYDROID_IF}.proxy_arp=1"
sysctl -qw "net.ipv4.conf.${HOST_LAN_IF}.rp_filter=2"
sysctl -qw "net.ipv4.conf.${WAYDROID_IF}.rp_filter=2"

# Preserve Waydroid's DHCP/NAT address for Internet access. This address is
# selected automatically for destinations in the physical LAN prefix.
nsenter -t "$pid" -n -- ip address replace \
  "$ANDROID_LAN_IP/$LAN_PREFIX_LENGTH" dev eth0 label eth0:lan

# Some Android LAN apps both check for Wi-Fi transport and hard-code the Linux
# interface name "wlan0" in an IPv6 scoped address. FakeWifi satisfies the
# Android transport check, while this dummy link makes that scope name valid.
# IPv4 LAN traffic continues to use eth0 and the routed/proxy-ARP address.
if [[ ${ENABLE_ANDROID_WLAN0_COMPAT:-no} == yes ]]; then
  if ! nsenter -t "$pid" -n -- ip link show "$ANDROID_WIFI_COMPAT_IF" >/dev/null 2>&1; then
    nsenter -t "$pid" -n -- ip link add "$ANDROID_WIFI_COMPAT_IF" type dummy
  fi
  nsenter -t "$pid" -n -- ip link set "$ANDROID_WIFI_COMPAT_IF" up
fi

# Android netd uses per-interface policy tables. Discover the selected table
# numerically and set the preferred source there; otherwise it keeps choosing
# Waydroid's primary 192.168.240.x address even for physical-LAN destinations.
route_probe=${INTERCOM_IP:-${ROUTER_IP:-$ANDROID_LAN_IP}}
route_result=$(nsenter -t "$pid" -n -- ip route get "$route_probe")
route_table=$(awk '{ for (i=1; i<=NF; i++) if ($i == "table") { print $(i+1); exit } }' <<< "$route_result")
route_table=${route_table:-254}
[[ $route_table =~ ^[0-9]+$ ]] || {
  echo "ERROR: could not determine Android numeric route table from: $route_result" >&2
  exit 1
}
nsenter -t "$pid" -n -- ip route replace "$lan_network" \
  dev eth0 src "$ANDROID_LAN_IP" table "$route_table"

echo "Waydroid LAN address applied: $ANDROID_LAN_IP/$LAN_PREFIX_LENGTH via $HOST_LAN_IF (table $route_table)"
