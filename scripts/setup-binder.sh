#!/usr/bin/env bash
# Load binder_linux and mount binderfs. Waydroid allocates its three nodes.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if ! grep -qw binder /proc/filesystems; then
  modprobe binder_linux devices=anbox-binder,anbox-hwbinder,anbox-vndbinder || {
    echo "ERROR: binder_linux could not be loaded. Check CONFIG_ANDROID_BINDER_IPC and modules-extra." >&2
    exit 1
  }
fi

install -d -m 0755 /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi

# The mount must survive reboot; x-systemd.automount avoids ordering races.
fstab_line='binder /dev/binderfs binder nofail,x-systemd.automount 0 0'
if ! grep -Eq '^[^#]+[[:space:]]+/dev/binderfs[[:space:]]+binder' /etc/fstab; then
  printf '%s\n' "$fstab_line" >> /etc/fstab
fi

if [[ ! -e /dev/binderfs/binder-control ]]; then
  echo "ERROR: binderfs is mounted but binder-control is absent." >&2
  exit 1
fi

echo "binderfs: OK"
ls -la /dev/binderfs
if [[ ! -e /dev/anbox-binder && ! -e /dev/binder ]]; then
  echo "INFO: Android binder nodes are allocated by Waydroid when the container starts."
fi

if [[ -e /dev/ashmem ]]; then
  echo "ashmem: legacy device present"
else
  echo "ashmem: absent; current Waydroid sets sys.use_memfd=true (expected on modern Ubuntu kernels)"
fi
