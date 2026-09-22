#!/usr/bin/env python3
"""Apply keyboard lighting through the sager_kbd sysfs device."""

import json
import os
import sys

SYSFS = "/sys/devices/platform/sager_kbd"
STATE_PATH = os.path.expanduser("~/.config/sager-keyboard/state.json")
ZONES = ("left", "center", "right", "lightbar")
MODES = ("static", "breathe", "cycle", "dance", "flash", "random", "tempo", "wave")
DEFAULT_COLOR = [40, 120, 255]


def clamp_channel(value):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, min(255, number))


def clamp_rgb(value):
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        return list(DEFAULT_COLOR)
    return [clamp_channel(channel) for channel in value]


def normalize(raw):
    state = {
        "enabled": True,
        "brightness": 160,
        "mode": "static",
        "linked": True,
        "activeZone": "left",
        "zones": {zone: list(DEFAULT_COLOR) for zone in ZONES},
    }
    if not isinstance(raw, dict):
        return state

    state["enabled"] = bool(raw.get("enabled", True))
    state["brightness"] = clamp_channel(raw.get("brightness", 160))
    mode = raw.get("mode", "static")
    state["mode"] = mode if mode in MODES else "static"
    state["linked"] = bool(raw.get("linked", True))
    active = raw.get("activeZone", "left")
    state["activeZone"] = active if active in ZONES else "left"

    incoming = raw.get("zones") if isinstance(raw.get("zones"), dict) else {}
    for zone in ZONES:
        state["zones"][zone] = clamp_rgb(incoming.get(zone, state["zones"][zone]))
    if state["linked"]:
        shared = list(state["zones"]["left"])
        for zone in ZONES:
            state["zones"][zone] = list(shared)
    return state


def load_saved():
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            return normalize(json.load(handle))
    except (OSError, json.JSONDecodeError):
        return normalize(None)


def save(state):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    temporary = STATE_PATH + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, STATE_PATH)


def driver_ready():
    return os.access(os.path.join(SYSFS, "apply"), os.W_OK)


def write_text(name, text):
    with open(os.path.join(SYSFS, name), "w", encoding="utf-8") as handle:
        handle.write(text)


def push(state):
    if not driver_ready():
        return False
    try:
        for zone in ZONES:
            red, green, blue = state["zones"][zone]
            write_text(zone, f"{red} {green} {blue}\n")
        write_text("brightness", f"{state['brightness']}\n")
        write_text("mode", state["mode"] + "\n")
        write_text("enabled", "1\n" if state["enabled"] else "0\n")
        write_text("apply", "1\n")
    except OSError:
        return False
    return True


def emit(state, applied=None):
    payload = dict(state)
    payload["available"] = driver_ready()
    if applied is not None:
        payload["applied"] = applied
    sys.stdout.write(json.dumps(payload) + "\n")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "get"
    if command == "get":
        emit(load_saved())
        return 0
    if command == "restore":
        state = load_saved()
        save(state)
        applied = push(state)
        emit(state, applied)
        return 0 if applied or not driver_ready() else 1
    if command == "set":
        try:
            raw = json.loads(sys.argv[2] if len(sys.argv) > 2 else "{}")
        except json.JSONDecodeError:
            sys.stderr.write("set expects a JSON object\n")
            return 2
        state = normalize(raw)
        save(state)
        applied = push(state)
        emit(state, applied)
        return 0 if applied or not driver_ready() else 1
    sys.stderr.write("usage: apply.py get|restore|set [json]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
