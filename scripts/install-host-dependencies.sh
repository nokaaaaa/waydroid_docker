#!/usr/bin/env bash
# Install host-native Waydroid and the packages used by the headless/test setup.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=WAYDROID_USER bash "$0" "$@"
fi

# Fixed OS-provided path.
# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != ubuntu || ! ${VERSION_CODENAME:-} =~ ^(jammy|noble)$ ]]; then
  echo "ERROR: Ubuntu 22.04 (jammy) or 24.04 (noble) is required; found ${PRETTY_NAME:-unknown}." >&2
  exit 1
fi

operator=${WAYDROID_USER:-${SUDO_USER:-}}
if [[ -z $operator || $operator == root ]] || ! id "$operator" >/dev/null 2>&1; then
  echo "ERROR: set WAYDROID_USER to the non-root account that will own the Waydroid session." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  android-sdk-platform-tools avahi-daemon avahi-utils ca-certificates curl \
  dbus-user-session dnsmasq-base iproute2 iputils-ping iw jq lxc nftables \
  network-manager openssl socat tcpdump weston

# Ubuntu's generic kernels normally contain binder_linux. modules-extra is
# useful on minimal server installs, but is not published for every kernel.
apt-get install -y "linux-modules-extra-$(uname -r)" || \
  echo "WARN: linux-modules-extra for the running kernel was unavailable; binder checks follow."

repo_script=$(mktemp)
trap 'rm -f "$repo_script"' EXIT
curl --fail --show-error --silent --location https://repo.waydro.id -o "$repo_script"
bash "$repo_script"
apt-get update
apt-get install -y waydroid

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
install -d -m 0755 /usr/local/libexec/waydroid-docker
install -m 0755 "$project_dir/scripts/start-waydroid.sh" /usr/local/libexec/waydroid-docker/start-waydroid.sh
install -m 0644 "$project_dir/systemd/waydroid-docker.service" /etc/systemd/system/waydroid-docker.service
install -m 0644 /dev/null /etc/default/waydroid-headless
printf 'WAYDROID_USER=%q\n' "$operator" > /etc/default/waydroid-headless

loginctl enable-linger "$operator"
systemctl daemon-reload
"$project_dir/scripts/setup-binder.sh"

echo "Host packages are ready. Next initialize explicitly: sudo waydroid init -s VANILLA"
echo "Use '-s GAPPS' instead only if Google services are required. Do not run both."
