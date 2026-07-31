#!/usr/bin/env bash
# Start all required services and launch the restored Aiphone app.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=WAYDROID_USER bash "$0" "$@"
fi

operator=${WAYDROID_USER:-${SUDO_USER:-}}
if [[ -z $operator || $operator == root ]] || ! id "$operator" >/dev/null 2>&1; then
  echo "ERROR: set WAYDROID_USER to the non-root Waydroid account." >&2
  exit 1
fi

systemctl start waydroid-container.service
systemctl restart waydroid-same-lan.service
systemctl start waydroid-docker.service

for _ in $(seq 1 90); do
  if runuser -u "$operator" -- waydroid status 2>/dev/null | grep -q $'Session:\tRUNNING'; then
    break
  fi
  sleep 1
done
runuser -u "$operator" -- waydroid status | grep -q $'Session:\tRUNNING' || {
  echo "ERROR: Waydroid session did not become ready." >&2
  exit 1
}

systemctl restart waydroid-aiphone-relay.service
runuser -u "$operator" -- waydroid app launch jp.co.aiphone.refine
echo "Aiphone app launched; discovery relay is running."

