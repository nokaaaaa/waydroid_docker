#!/usr/bin/env bash
# Install one APK into the host-native Waydroid instance.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/app.apk" >&2
  exit 2
fi
apk=$(realpath -e -- "$1")
[[ -f $apk && $apk == *.apk ]] || { echo "ERROR: not an .apk file: $apk" >&2; exit 1; }

waydroid status || { echo "ERROR: Waydroid is not running." >&2; exit 1; }
waydroid app install "$apk"
echo "Installed: $apk"
echo "Packages matching the APK filename are not inferred; use 'waydroid app list' to verify."
