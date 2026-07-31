#!/usr/bin/env bash
# Stop this project. Add --purge-data for irreversible Waydroid/data removal.
set -Eeuo pipefail

purge=no
[[ ${1:-} == --purge-data ]] && purge=yes
if [[ $# -gt 1 || ( $# -eq 1 && $purge != yes ) ]]; then
  echo "Usage: $0 [--purge-data]" >&2
  exit 2
fi
if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

systemctl disable --now waydroid-docker.service 2>/dev/null || true
waydroid session stop 2>/dev/null || true
waydroid container stop 2>/dev/null || true
systemctl stop 'waydroid-*-relay.service' 2>/dev/null || true

if [[ $purge == no ]]; then
  echo "Stopped services. Waydroid images/data and Docker volumes were preserved."
  exit 0
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
read -r -p "Type PURGE-WAYDROID to delete /var/lib/waydroid and project Docker volumes: " answer
[[ $answer == PURGE-WAYDROID ]] || { echo "Cancelled; no data deleted."; exit 1; }

apt-get remove -y waydroid
rm -rf -- /var/lib/waydroid
docker compose --project-directory "$project_dir" down --volumes --remove-orphans 2>/dev/null || true
rm -f -- /etc/systemd/system/waydroid-docker.service /etc/default/waydroid-headless
rm -rf -- /usr/local/libexec/waydroid-docker
systemctl daemon-reload
echo "Removed Waydroid package/data, this unit, helper installation, and project Docker volumes."
echo "Source files and the Avahi backup/configuration were retained for manual review."
