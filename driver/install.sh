#!/bin/bash
# Install the P870DM-G keyboard driver so it rebuilds on kernel updates.
set -euo pipefail

ver=1.2.0
src="$(cd "$(dirname "$0")" && pwd)"
dest="/usr/src/sager-kbd-${ver}"
session_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
modprobe_conf="/etc/modprobe.d/omarchy-sager-kbd.conf"
modules_conf="/etc/modules-load.d/sager_kbd.conf"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if [[ ! "$session_uid" =~ ^[0-9]+$ ]] || [[ "$session_uid" -eq 0 ]]; then
  echo "run this installer with pkexec from the desktop session that should control the device" >&2
  exit 1
fi

if [[ -e "$modprobe_conf" ]] && ! grep -q '^# Managed by omarchy-keyboard$' "$modprobe_conf"; then
  echo "$modprobe_conf already exists and is not managed by omarchy-keyboard; refusing to overwrite it" >&2
  exit 1
fi
if [[ -e "$modules_conf" ]] && [[ "$(cat "$modules_conf")" != "sager_kbd" ]]; then
  echo "$modules_conf already contains other content; refusing to overwrite it" >&2
  exit 1
fi

mkdir -p "$dest"
cp "$src/sager_kbd.c" "$src/Makefile" "$src/dkms.conf" "$dest/"

dkms remove -m sager-kbd -v 1.0.0 --all >/dev/null 2>&1 || true
dkms remove -m sager-kbd -v 1.1.0 --all >/dev/null 2>&1 || true
if dkms status -m sager-kbd -v "$ver" 2>/dev/null | grep -q .; then
  dkms remove -m sager-kbd -v "$ver" --all || true
fi

dkms add -m sager-kbd -v "$ver"
dkms install -m sager-kbd -v "$ver"

if [[ ! -e "$modules_conf" ]]; then
  printf 'sager_kbd\n' > "$modules_conf"
  chmod 0644 "$modules_conf"
fi
tmp_conf="$(mktemp "${modprobe_conf}.tmp.XXXXXX")"
trap 'rm -f "$tmp_conf"' EXIT
printf '# Managed by omarchy-keyboard\noptions sager_kbd session_uid=%s\n' "$session_uid" > "$tmp_conf"
chmod 0644 "$tmp_conf"
mv "$tmp_conf" "$modprobe_conf"

if lsmod | grep -q '^sager_kbd '; then
  rmmod sager_kbd
fi
modprobe sager_kbd

if [[ ! -e /sys/devices/platform/sager_kbd/apply ]]; then
  echo "sager_kbd loaded but the sysfs device is missing" >&2
  exit 1
fi

echo "sager_kbd installed"
