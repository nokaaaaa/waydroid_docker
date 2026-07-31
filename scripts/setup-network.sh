#!/usr/bin/env bash
# Configure the supported Wi-Fi-host topology: routed/NAT Waydroid plus optional relays.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
env_file=${1:-$project_dir/config/network.env}
if [[ ! -r $env_file ]]; then
  echo "ERROR: copy config/network.env.example to config/network.env and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$env_file"

: "${HOST_LAN_IF:?HOST_LAN_IF is required}"
: "${WAYDROID_IF:=waydroid0}"
[[ $HOST_LAN_IF =~ ^[a-zA-Z0-9_.:-]+$ && $WAYDROID_IF =~ ^[a-zA-Z0-9_.:-]+$ ]] || {
  echo "ERROR: invalid interface name." >&2
  exit 1
}
ip link show "$HOST_LAN_IF" >/dev/null

install -m 0644 /dev/null /etc/sysctl.d/90-waydroid-network.conf
printf '%s\n' \
  'net.ipv4.ip_forward=1' \
  "net.ipv4.conf.${HOST_LAN_IF}.rp_filter=2" \
  "net.ipv4.conf.${WAYDROID_IF}.rp_filter=2" \
  > /etc/sysctl.d/90-waydroid-network.conf
sysctl --system >/dev/null

echo "Configured routed/NAT forwarding. Waydroid's own waydroid-net.sh owns NAT and dnsmasq rules."
echo "No macvlan/bridge was created on ${HOST_LAN_IF}; managed Wi-Fi usually cannot carry extra client MACs."

if [[ ${ENABLE_MDNS_REFLECTOR:-no} == yes ]]; then
  avahi_cfg=/etc/avahi/avahi-daemon.conf
  backup=${avahi_cfg}.pre-waydroid
  [[ -e $backup ]] || cp -a "$avahi_cfg" "$backup"
  # Ubuntu's stock file already contains these keys commented in their proper sections.
  sed -Ei \
    -e "s|^[#[:space:]]*allow-interfaces=.*|allow-interfaces=${HOST_LAN_IF},${WAYDROID_IF}|" \
    -e 's|^[#[:space:]]*enable-reflector=.*|enable-reflector=yes|' \
    -e 's|^[#[:space:]]*reflect-ipv=.*|reflect-ipv=no|' \
    "$avahi_cfg"
  grep -q '^enable-reflector=yes$' "$avahi_cfg" || {
    echo "ERROR: could not safely enable Avahi reflector; restore $backup and edit manually." >&2
    exit 1
  }
  systemctl enable --now avahi-daemon
  systemctl restart avahi-daemon
  echo "Enabled mDNS reflection only between ${HOST_LAN_IF} and ${WAYDROID_IF}. Avoid a second reflector loop."
fi

relay_bin=$(command -v udp-broadcast-relay-redux || true)
if [[ ${ENABLE_SSDP_RELAY:-no} == yes || ${ENABLE_BROADCAST_RELAY:-no} == yes ]]; then
  if [[ -z $relay_bin ]]; then
    echo "ERROR: relay requested but udp-broadcast-relay-redux is not installed." >&2
    echo "Build it from https://github.com/udp-redux/udp-broadcast-relay-redux after reviewing its source." >&2
    exit 1
  fi
fi

install_relay_unit() {
  local name=$1 id=$2 port=$3 multicast=${4:-}
  local unit=/etc/systemd/system/${name}.service
  {
    echo '[Unit]'
    echo "Description=Waydroid UDP relay (${port})"
    echo 'After=network-online.target waydroid-container.service'
    echo 'Wants=network-online.target'
    echo '[Service]'
    printf 'ExecStart=%s --id %s --port %s --dev %s --dev %s' \
      "$relay_bin" "$id" "$port" "$HOST_LAN_IF" "$WAYDROID_IF"
    [[ -n $multicast ]] && printf ' --multicast %s' "$multicast"
    printf '\nRestart=on-failure\nRestartSec=3\n'
    echo '[Install]'
    echo 'WantedBy=multi-user.target'
  } > "$unit"
  systemctl daemon-reload
  systemctl enable --now "$name.service"
}

if [[ ${ENABLE_SSDP_RELAY:-no} == yes ]]; then
  install_relay_unit waydroid-ssdp-relay 1900 1900 239.255.255.250
fi

if [[ ${ENABLE_BROADCAST_RELAY:-no} == yes ]]; then
  IFS=',' read -r -a ports <<< "${BROADCAST_PORTS:-}"
  [[ ${#ports[@]} -gt 0 && -n ${ports[0]} ]] || {
    echo "ERROR: ENABLE_BROADCAST_RELAY=yes requires device-specific BROADCAST_PORTS." >&2
    exit 1
  }
  id=2000
  for port in "${ports[@]}"; do
    [[ $port =~ ^[0-9]+$ && $port -le 65535 ]] || { echo "ERROR: invalid UDP port: $port" >&2; exit 1; }
    install_relay_unit "waydroid-udp-${port}-relay" "$id" "$port"
    ((id+=1))
  done
fi

echo "Network setup complete. Relay processes are experiments until packet capture proves both directions."
