#!/usr/bin/env bash
# Restore the encrypted snapshot and configure a fresh Ubuntu host in one command.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=SNAPSHOT_FILE,WAYDROID_USER,HOST_LAN_IF,ROUTER_IP,INTERCOM_IP,ANDROID_LAN_IP bash "$0" "$@"
fi

operator=${WAYDROID_USER:-${SUDO_USER:-}}
if [[ -z $operator || $operator == root ]] || ! id "$operator" >/dev/null 2>&1; then
  echo "ERROR: set WAYDROID_USER to the non-root account that will run Waydroid." >&2
  exit 1
fi
[[ $(id -u "$operator") -eq 1000 ]] || {
  echo "ERROR: exact Android ownership restoration requires $operator to have UID 1000." >&2
  exit 1
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
operator_home=$(getent passwd "$operator" | cut -d: -f6)
snapshot=${SNAPSHOT_FILE:-$project_dir/snapshots/waydroid-state.tar.zst.gpg}
checksum=$snapshot.sha256
release_base=https://github.com/nokaaaaa/waydroid_docker/releases/download/portable-state-v1

if [[ ! -r $snapshot ]]; then
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl
  download_dir=$(mktemp -d)
  trap 'rm -rf -- "$download_dir"' EXIT
  snapshot=$download_dir/waydroid-state.tar.zst.gpg
  checksum=$snapshot.sha256
  echo "Downloading encrypted Waydroid snapshot..."
  curl --fail --location --show-error \
    --output "$snapshot" "$release_base/waydroid-state.tar.zst.gpg"
  curl --fail --location --show-error \
    --output "$checksum" "$release_base/waydroid-state.tar.zst.gpg.sha256"
fi

if [[ -r $checksum ]]; then
  expected=$(awk 'NR == 1 { print $1 }' "$checksum")
  actual=$(sha256sum "$snapshot" | awk '{ print $1 }')
  [[ $actual == "$expected" ]] || { echo "ERROR: snapshot checksum mismatch." >&2; exit 1; }
fi

WAYDROID_USER=$operator "$project_dir/scripts/install-host-dependencies.sh"
apt-get install -y --no-install-recommends gnupg zstd

restore_dir=$(mktemp -d /var/tmp/waydroid-restore.XXXXXX)
trap 'rm -rf -- "$restore_dir" ${download_dir:-}' EXIT
echo "Decrypting snapshot. Enter its GnuPG passphrase."
gpg --decrypt "$snapshot" | zstd -d | tar --extract --numeric-owner --acls --xattrs -C "$restore_dir"
[[ -f $restore_dir/waydroid.cfg && -d $restore_dir/images && -d $restore_dir/data ]] || {
  echo "ERROR: snapshot is incomplete." >&2
  exit 1
}

if [[ -e $operator_home/.local/share/waydroid/data || -e /var/lib/waydroid/waydroid.cfg ]]; then
  echo "ERROR: this installer only restores onto a fresh host; existing Waydroid data was found." >&2
  echo "Remove it explicitly after backing it up, then rerun this command." >&2
  exit 1
fi

systemctl stop waydroid-docker.service waydroid-container.service 2>/dev/null || true
install -d -m 0755 /var/lib/waydroid
cp -a "$restore_dir/images" "$restore_dir/overlay" "$restore_dir/overlay_rw" /var/lib/waydroid/
cp -a "$restore_dir/waydroid.cfg" "$restore_dir/waydroid.prop" \
  "$restore_dir/waydroid_base.prop" /var/lib/waydroid/
install -d -m 0755 -o "$operator" -g "$(id -gn "$operator")" "$operator_home/.local/share/waydroid"
cp -a "$restore_dir/data" "$operator_home/.local/share/waydroid/data"

# Generate host-specific LXC files around the restored images and properties.
waydroid init -s GAPPS

detected_if=${HOST_LAN_IF:-$(ip -4 route show default | awk 'NR == 1 { print $5 }')}
detected_router=${ROUTER_IP:-$(ip -4 route show default | awk 'NR == 1 { print $3 }')}
[[ -n $detected_if && -n $detected_router ]] || {
  echo "ERROR: could not detect the default LAN interface and router." >&2
  exit 1
}

network_env=/etc/waydroid-portable-network.env
cp "$project_dir/config/network.env" "$network_env"
sed -Ei \
  -e "s|^HOST_LAN_IF=.*|HOST_LAN_IF=$detected_if|" \
  -e "s|^ROUTER_IP=.*|ROUTER_IP=$detected_router|" \
  "$network_env"
[[ -z ${INTERCOM_IP:-} ]] || sed -Ei "s|^INTERCOM_IP=.*|INTERCOM_IP=$INTERCOM_IP|" "$network_env"
[[ -z ${ANDROID_LAN_IP:-} ]] || sed -Ei "s|^ANDROID_LAN_IP=.*|ANDROID_LAN_IP=$ANDROID_LAN_IP|" "$network_env"
chmod 0600 "$network_env"

install -m 0755 "$project_dir/scripts/aiphone-discovery-relay.py" \
  /usr/local/libexec/waydroid-docker/aiphone-discovery-relay.py
install -m 0755 "$project_dir/scripts/run-aiphone-relay.sh" \
  /usr/local/libexec/waydroid-docker/run-aiphone-relay.sh
install -m 0644 "$project_dir/systemd/waydroid-aiphone-relay.service" \
  /etc/systemd/system/waydroid-aiphone-relay.service

systemctl daemon-reload
systemctl enable --now waydroid-container.service waydroid-docker.service
for _ in $(seq 1 90); do
  if runuser -u "$operator" -- waydroid status 2>/dev/null | grep -q $'Session:\tRUNNING'; then
    break
  fi
  sleep 1
done
runuser -u "$operator" -- waydroid status | grep -q $'Session:\tRUNNING' || {
  echo "ERROR: restored Waydroid session did not become ready." >&2
  exit 1
}

"$project_dir/scripts/setup-network.sh" "$network_env"
systemctl daemon-reload
systemctl enable waydroid-docker.service waydroid-aiphone-relay.service

echo "Portable Waydroid setup complete."
echo "Launch the app with: ./scripts/launch-aiphone.sh"
