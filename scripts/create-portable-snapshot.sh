#!/usr/bin/env bash
# Create an encrypted, consistent snapshot of this machine's Waydroid state.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=SNAPSHOT_OUTPUT bash "$0" "$@"
fi

operator=${SUDO_USER:-}
if [[ -z $operator || $operator == root ]]; then
  echo "ERROR: run this script from the non-root Waydroid account with sudo." >&2
  exit 1
fi
[[ $(id -u "$operator") -eq 1000 ]] || {
  echo "ERROR: the portable snapshot currently requires the Waydroid account to have UID 1000." >&2
  exit 1
}

command -v gpg >/dev/null || { echo "ERROR: gpg is required." >&2; exit 1; }
command -v zstd >/dev/null || { echo "ERROR: zstd is required." >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
operator_home=$(getent passwd "$operator" | cut -d: -f6)
data_dir=$operator_home/.local/share/waydroid/data
output=${SNAPSHOT_OUTPUT:-$project_dir/snapshots/waydroid-state.tar.zst.gpg}
checksum=$output.sha256

[[ -d $data_dir && -f /var/lib/waydroid/waydroid.cfg ]] || {
  echo "ERROR: initialized Waydroid data was not found for $operator." >&2
  exit 1
}
install -d -m 0700 -o "$operator" -g "$(id -gn "$operator")" "$(dirname -- "$output")"

echo "Stopping Waydroid to take a consistent snapshot..."
systemctl stop waydroid-docker.service 2>/dev/null || true
runuser -u "$operator" -- waydroid session stop 2>/dev/null || true
systemctl stop waydroid-container.service 2>/dev/null || true

tmp_output=$output.partial
trap 'rm -f -- "$tmp_output"' EXIT
rm -f -- "$tmp_output"

echo "Creating encrypted snapshot. Enter a strong passphrase when GnuPG asks."
tar --create --numeric-owner --acls --xattrs --one-file-system \
  --exclude='data/waydroid_tmp/*' \
  --exclude='data/tombstones/*' \
  --exclude='data/anr/*' \
  -C "$operator_home/.local/share/waydroid" data \
  -C /var/lib/waydroid \
    images overlay overlay_rw waydroid.cfg waydroid.prop waydroid_base.prop \
  | zstd -T0 -10 \
  | gpg --symmetric --cipher-algo AES256 --output "$tmp_output"

mv -- "$tmp_output" "$output"
sha256sum "$output" > "$checksum"
chown "$operator:$(id -gn "$operator")" "$output" "$checksum"
chmod 0600 "$output" "$checksum"
trap - EXIT

echo "Snapshot created: $output"
echo "Checksum created: $checksum"
echo "The passphrase is not stored anywhere. Keep it separately."

