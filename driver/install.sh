#!/bin/bash
# Install the P870DM-G keyboard driver so it rebuilds on kernel updates.
# Root-owned DKMS trees are replaced only when they are an unmodified copy
# shipped by this plugin. Anything else is left in place.
set -euo pipefail

ver=1.2.0
plugin_id=io.github.wouldja.keyboard
marker_name=OMARCHY-KEYBOARD
src="$(cd "$(dirname "$0")" && pwd)"
sys_src=/usr/src
dkms_lib=/var/lib/dkms
session_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
modprobe_conf="/etc/modprobe.d/omarchy-sager-kbd.conf"
modules_conf="/etc/modules-load.d/sager_kbd.conf"

# sha256 of sager_kbd.c, Makefile, and dkms.conf from this repository.
# 1.1.0 is 843ae64..eac0821. 1.2.0 is edad56b.
known_source_releases() {
  cat <<'EOF'
1.1.0 fe78b967eda9a0776546b5499fc874af18d7a694f8ee17595687177f1e112035 8eac8c74bfe3efe35282862c4ebc8f06128b619c64f65be8e70097bb89854462 305c772922c50f24a958bffabe169d77de1278e39f58c0587d14a6e68ece92fc
1.2.0 8bac265362dae0705ceef8c5c05be5d465064739dc1f74f48bf55eb7c2e6c4f4 8eac8c74bfe3efe35282862c4ebc8f06128b619c64f65be8e70097bb89854462 3f1abba05153d690562e6a5c776462fa5b1baa87b39c582a94c49b190c47c19c
EOF
}

file_hash() {
  sha256sum "$1" | awk '{print $1}'
}

tree_has_unexpected_entries() {
  local dir="$1" entry base
  shopt -s nullglob dotglob
  for entry in "$dir"/*; do
    base="${entry##*/}"
    case "$base" in
      sager_kbd.c|Makefile|dkms.conf|"$marker_name") ;;
      *)
        shopt -u nullglob dotglob
        return 0
        ;;
    esac
  done
  shopt -u nullglob dotglob
  return 1
}

marker_matches() {
  local dir="$1" marker="$dir/$marker_name" f hash
  [[ -f "$marker" ]] || return 1
  [[ "$(sed -n '1p' "$marker")" == "# Managed by ${plugin_id}" ]] || return 1
  for f in sager_kbd.c Makefile dkms.conf; do
    [[ -f "$dir/$f" ]] || return 1
    hash="$(file_hash "$dir/$f")"
    grep -qx -- "$f $hash" "$marker" || return 1
  done
}

known_release_matches() {
  local dir="$1" line rel_ver rel_c rel_make rel_dkms hash_c hash_make hash_dkms
  [[ -f "$dir/sager_kbd.c" && -f "$dir/Makefile" && -f "$dir/dkms.conf" ]] || return 1
  hash_c="$(file_hash "$dir/sager_kbd.c")"
  hash_make="$(file_hash "$dir/Makefile")"
  hash_dkms="$(file_hash "$dir/dkms.conf")"
  while read -r line; do
    [[ -n "$line" ]] || continue
    read -r rel_ver rel_c rel_make rel_dkms <<<"$line"
    if [[ "$hash_c" == "$rel_c" && "$hash_make" == "$rel_make" && "$hash_dkms" == "$rel_dkms" ]]; then
      return 0
    fi
  done < <(known_source_releases)
  return 1
}

# absent: nothing is installed at this path.
# ours: unmodified sources from this plugin.
# foreign: another driver, or a local edit of ours.
classify_tree() {
  local dir="$1"
  if [[ ! -e "$dir" ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ ! -d "$dir" ]] || tree_has_unexpected_entries "$dir"; then
    printf 'foreign\n'
    return 0
  fi
  if marker_matches "$dir" || known_release_matches "$dir"; then
    printf 'ours\n'
    return 0
  fi
  printf 'foreign\n'
}

# none: DKMS has no registration for this version.
# at-tree: the registration's source symlink is this version's /usr/src tree.
# elsewhere: registered, but the source is not that tree.
registration_state() {
  local ver_name="$1"
  local dir="$sys_src/sager-kbd-${ver_name}"
  local link="$dkms_lib/sager-kbd/${ver_name}/source"
  local out target
  out="$(dkms status -m sager-kbd -v "$ver_name" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    printf 'none\n'
    return 0
  fi
  if [[ -L "$link" ]]; then
    target="$(readlink -f "$link" || readlink "$link" || true)"
    if [[ "$target" == "$dir" ]]; then
      printf 'at-tree\n'
      return 0
    fi
  fi
  printf 'elsewhere\n'
}

ensure_safe() {
  local ver_name dir state reg
  for ver_name in 1.0.0 1.1.0 "$ver"; do
    dir="$sys_src/sager-kbd-${ver_name}"
    state="$(classify_tree "$dir")"
    reg="$(registration_state "$ver_name")"
    if [[ "$state" == foreign ]]; then
      echo "$dir is not an unmodified driver from ${plugin_id}; leaving it in place" >&2
      return 1
    fi
    if [[ "$reg" == elsewhere ]]; then
      echo "DKMS registration sager-kbd ${ver_name} does not point at a driver from ${plugin_id}; leaving it in place" >&2
      return 1
    fi
    if [[ "$state" == absent && "$reg" == at-tree ]]; then
      echo "DKMS registration sager-kbd ${ver_name} has no plugin-owned source tree; leaving it in place" >&2
      return 1
    fi
  done
}

write_marker() {
  local dir="$1" tmp f hash
  tmp="$(mktemp "$dir/.${marker_name}.tmp.XXXXXX")"
  {
    printf '# Managed by %s\n' "$plugin_id"
    for f in sager_kbd.c Makefile dkms.conf; do
      hash="$(file_hash "$dir/$f")"
      printf '%s %s\n' "$f" "$hash"
    done
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$dir/$marker_name"
}

retire_owned_version() {
  local ver_name="$1"
  local dir="$sys_src/sager-kbd-${ver_name}"
  local state reg
  state="$(classify_tree "$dir")"
  reg="$(registration_state "$ver_name")"
  [[ "$state" == ours ]] || return 0
  if [[ "$reg" == at-tree ]]; then
    dkms remove -m sager-kbd -v "$ver_name" --all
  fi
  rm -f "$dir/sager_kbd.c" "$dir/Makefile" "$dir/dkms.conf" "$dir/$marker_name"
  rmdir "$dir" 2>/dev/null || true
}

install_current_sources() {
  local dir="$sys_src/sager-kbd-${ver}"
  local state reg
  state="$(classify_tree "$dir")"
  reg="$(registration_state "$ver")"
  if [[ "$state" == ours && "$reg" == at-tree ]]; then
    dkms remove -m sager-kbd -v "$ver" --all
  fi
  mkdir -p "$dir"
  cp "$src/sager_kbd.c" "$src/Makefile" "$src/dkms.conf" "$dir/"
  write_marker "$dir"
}

main() {
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

  ensure_safe

  retire_owned_version 1.0.0
  retire_owned_version 1.1.0
  install_current_sources

  dkms add -m sager-kbd -v "$ver"
  dkms install -m sager-kbd -v "$ver"

  if [[ ! -e "$modules_conf" ]]; then
    printf 'sager_kbd\n' >"$modules_conf"
    chmod 0644 "$modules_conf"
  fi
  local tmp_conf
  tmp_conf="$(mktemp "${modprobe_conf}.tmp.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_conf'" EXIT
  printf '# Managed by omarchy-keyboard\noptions sager_kbd session_uid=%s\n' "$session_uid" >"$tmp_conf"
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
