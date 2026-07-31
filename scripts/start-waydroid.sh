#!/usr/bin/env bash
# Start Waydroid with a headless Weston compositor from a system service.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=WAYDROID_USER bash "$0" "$@"
fi

session_user=${WAYDROID_USER:-}
if [[ -z $session_user || $session_user == root ]] || ! id "$session_user" >/dev/null 2>&1; then
  echo "ERROR: WAYDROID_USER must name an existing non-root account." >&2
  exit 1
fi
[[ -f /var/lib/waydroid/waydroid.cfg ]] || {
  echo "ERROR: Waydroid is not initialized. Run: sudo waydroid init -s VANILLA (or GAPPS)" >&2
  exit 1
}

uid=$(id -u "$session_user")
runtime_dir=/run/user/$uid
home_dir=$(getent passwd "$session_user" | cut -d: -f6)

if [[ ${1:-start} == stop ]]; then
  exec runuser -u "$session_user" -- env \
    HOME="$home_dir" XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=waydroid-0 \
    waydroid session stop
fi
[[ ${1:-start} == start ]] || { echo "Usage: $0 [start|stop]" >&2; exit 2; }

if systemctl cat waydroid-container.service >/dev/null 2>&1; then
  systemctl start waydroid-container.service
else
  waydroid container start
fi

install -d -m 0700 -o "$session_user" -g "$(id -gn "$session_user")" "$runtime_dir"
log_file=$home_dir/waydroid-headless.log

# The single-quoted program is intentionally expanded by the inner bash.
# shellcheck disable=SC2016
exec runuser -u "$session_user" -- env \
  HOME="$home_dir" XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=waydroid-0 \
  dbus-run-session -- bash -Eeuo pipefail -c '
    weston --backend=headless-backend.so --use-pixman --socket=waydroid-0 --idle-time=0 \
      --width=1280 --height=720 >>"$1" 2>&1 &
    weston_pid=$!
    trap '\''waydroid session stop >/dev/null 2>&1 || true; kill "$weston_pid" >/dev/null 2>&1 || true'\'' EXIT INT TERM
    for _ in {1..50}; do
      [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
      kill -0 "$weston_pid" 2>/dev/null || { echo "Weston exited" >&2; exit 1; }
      sleep 0.2
    done
    [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || { echo "Wayland socket was not created" >&2; exit 1; }
    waydroid session start
  ' bash "$log_file"
