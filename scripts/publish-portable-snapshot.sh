#!/usr/bin/env bash
# Upload the encrypted snapshot as assets of a GitHub Release.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
snapshot=${1:-$project_dir/snapshots/waydroid-state.tar.zst.gpg}
checksum=$snapshot.sha256
repository=${SNAPSHOT_REPOSITORY:-nokaaaaa/waydroid_docker}
tag=${SNAPSHOT_TAG:-portable-state-v1}

command -v gh >/dev/null || { echo "ERROR: GitHub CLI (gh) is required." >&2; exit 1; }
[[ -r $snapshot && -r $checksum ]] || {
  echo "ERROR: snapshot or checksum is missing. Run scripts/create-portable-snapshot.sh first." >&2
  exit 1
}

if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  gh release upload "$tag" "$snapshot" "$checksum" --clobber --repo "$repository"
else
  gh release create "$tag" "$snapshot" "$checksum" \
    --repo "$repository" \
    --title "Encrypted Waydroid portable state v1" \
    --notes "Encrypted Waydroid state used by scripts/setup-portable-clone.sh. The decryption passphrase is not stored in this repository."
fi

echo "Encrypted snapshot published to release $tag."

