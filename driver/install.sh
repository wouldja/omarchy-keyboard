#!/bin/bash
# Install the P870DM-G keyboard driver so it rebuilds on kernel updates.
set -euo pipefail

ver=1.1.0
src="$(cd "$(dirname "$0")" && pwd)"
dest="/usr/src/sager-kbd-${ver}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

mkdir -p "$dest"
cp "$src/sager_kbd.c" "$src/Makefile" "$src/dkms.conf" "$dest/"

dkms remove -m sager-kbd -v 1.0.0 --all >/dev/null 2>&1 || true
if dkms status -m sager-kbd -v "$ver" 2>/dev/null | grep -q .; then
  dkms remove -m sager-kbd -v "$ver" --all || true
fi

dkms add -m sager-kbd -v "$ver"
dkms install -m sager-kbd -v "$ver"

printf 'sager_kbd\n' > /etc/modules-load.d/sager_kbd.conf

if lsmod | grep -q '^sager_kbd '; then
  rmmod sager_kbd
fi
modprobe sager_kbd

if [[ ! -e /sys/devices/platform/sager_kbd/apply ]]; then
  echo "sager_kbd loaded but the sysfs device is missing" >&2
  exit 1
fi

echo "sager_kbd installed"
