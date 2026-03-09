#!/usr/bin/env bash

set -euo pipefail

WC_PY="$HOME/contained_apps/uv/wayclick/.venv/bin/python"

if [[ -x "$WC_PY" ]] && "$WC_PY" -c "import evdev" &>/dev/null; then
    PYTHON="$WC_PY"
elif command -v python3 &>/dev/null && python3 -c "import evdev" &>/dev/null; then
    PYTHON="python3"
else
    printf "\033[1;31m[ERROR]\033[0m evdev module not found.\n"
    printf "  Option 1: \033[1;36m./wayclick.sh --setup\033[0m  (builds native evdev)\n"
    printf "  Option 2: \033[1;36msudo pacman -S python-evdev\033[0m\n"
    exit 1
fi

exec "$PYTHON" -OO - << 'PYTHON_EOF'
import evdev
import os
import sys

GREEN  = "\033[1;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[1;36m"
RED    = "\033[1;31m"
BLUE   = "\033[1;34m"
DIM    = "\033[2m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

EV_KEY = 1
EV_REL = 2
EV_ABS = 3

REL_X  = 0
REL_Y  = 1

ABS_MT_POSITION_X = 0x35   # 53  — multitouch X axis (touchpads, touchscreens)

BTN_LEFT        = 0x110    # 272 — primary mouse/touchpad button
BTN_GAMEPAD     = 0x130    # 304 — start of gamepad button range
BTN_TOOL_FINGER = 0x145    # 325 — "finger on surface" (touchpads)

# Standard keyboard keycodes: KEY_ESC(1) through KEY_KPDOT(83) + F11/F12
# Any device reporting 20+ of these is a real keyboard.
KEYBOARD_KEYS = set(range(1, 84)) | {87, 88}

# WayClick's default EXCLUDED_KEYWORDS (must match wayclick.sh for accurate prediction)
WC_KEYWORDS = ("touchpad", "trackpad", "glidepoint", "magic trackpad", "clickpad")

def classify(dev):
    caps = dev.capabilities(absinfo=False)
    keys = set(caps.get(EV_KEY, []))
    rels = set(caps.get(EV_REL, []))
    abss = set(caps.get(EV_ABS, []))

    is_touchpad = ABS_MT_POSITION_X in abss or BTN_TOOL_FINGER in keys
    is_mouse    = REL_X in rels and REL_Y in rels and not is_touchpad
    is_keyboard = len(keys & KEYBOARD_KEYS) >= 20
    is_gamepad  = any(c in keys for c in range(BTN_GAMEPAD, BTN_GAMEPAD + 16))
    has_ev_key  = EV_KEY in caps

    # --- Type string (multi-function devices get combined labels) ---
    parts = []
    if is_touchpad: parts.append("TOUCHPAD")
    if is_keyboard: parts.append("KEYBOARD")
    if is_mouse:    parts.append("MOUSE")
    if is_gamepad:  parts.append("GAMEPAD")

    if not parts:
        if BTN_LEFT in keys:  parts.append("BUTTONS")
        elif keys:            parts.append("SYSTEM")
        elif abss:            parts.append("SENSOR")
        else:                 parts.append("OTHER")

    dev_type = " + ".join(parts)

    # --- Color (priority: touchpad > keyboard > mouse > dim) ---
    if   is_touchpad: color = YELLOW
    elif is_keyboard: color = GREEN
    elif is_mouse:    color = CYAN
    else:             color = DIM

    # --- WayClick behavior prediction ---
    # Replicates WayClick's exact filtering logic:
    #   1. No EV_KEY → ignored entirely (never monitored)
    #   2. Name matches EXCLUDED_KEYWORDS → filtered
    #   3. Auto-detect: ABS_MT_POSITION_X or BTN_TOOL_FINGER → filtered
    #   4. Otherwise → connected (plays sounds)
    if not has_ev_key:
        wc_cat = "ignored"
        wc_display = f"{DIM}\u2014 no EV_KEY{RESET}"
    else:
        name_lower = dev.name.lower()
        matched_kw = next((k for k in WC_KEYWORDS if k in name_lower), None)

        if matched_kw:
            wc_cat = "filtered"
            wc_display = f"{YELLOW}\u2717 keyword: \"{matched_kw}\"{RESET}"
        elif is_touchpad:
            wc_cat = "filtered"
            wc_display = f"{YELLOW}\u2717 auto-detect{RESET}"
        else:
            wc_cat = "active"
            wc_display = f"{GREEN}\u25b6 active{RESET}"

    return dev_type, color, wc_display, wc_cat

devices = []
for path in evdev.list_devices():
    try:
        devices.append(evdev.InputDevice(path))
    except (OSError, IOError):
        pass

if not devices:
    import pwd
    user = pwd.getpwuid(os.getuid()).pw_name
    print(f"\n{RED}No readable input devices found.{RESET}")
    print(f"User '{user}' is likely not in the 'input' group.")
    print(f"  {CYAN}sudo usermod -aG input {user}{RESET}")
    print("Then log out and log back in.")
    sys.exit(1)

# Sort by event number
devices.sort(key=lambda d: int(os.path.basename(d.path).replace("event", "")))

W_NAME = 42
W_PATH = 8
W_TYPE = 20
LINE_W = 95

py_ver = sys.version.split()[0]
ev_ver = evdev.__version__ if hasattr(evdev, "__version__") else "?"

print(f"\n{BLUE}{'─' * LINE_W}{RESET}")
print(f" {BOLD}WAYCLICK DEVICE INSPECTOR{RESET}                         "
      f"{DIM}Python {py_ver} │ evdev {ev_ver}{RESET}")
print(f"{BLUE}{'─' * LINE_W}{RESET}")
print(f" {BOLD}{'DEVICE':<{W_NAME}}{RESET} │ {BOLD}{'PATH':<{W_PATH}}{RESET} "
      f"│ {BOLD}{'TYPE':<{W_TYPE}}{RESET} │ {BOLD}WAYCLICK{RESET}")
print(f"{BLUE}{'─' * LINE_W}{RESET}")

type_counts = {}
wc_counts = {"active": 0, "filtered": 0, "ignored": 0}

for dev in devices:
    dev_type, color, wc_display, wc_cat = classify(dev)
    event_name = os.path.basename(dev.path)
    name = dev.name[:W_NAME]

    print(f" {color}{name:<{W_NAME}}{RESET} │ {event_name:<{W_PATH}} "
          f"│ {color}{dev_type:<{W_TYPE}}{RESET} │ {wc_display}")

    primary = dev_type.split(" + ")[0]
    type_counts[primary] = type_counts.get(primary, 0) + 1
    wc_counts[wc_cat] += 1

    dev.close()

print(f"{BLUE}{'─' * LINE_W}{RESET}")

type_str = " \u2502 ".join(f"{t}: {c}" for t, c in sorted(type_counts.items()))
print(f" {DIM}{type_str}{RESET}")

a, f, i = wc_counts["active"], wc_counts["filtered"], wc_counts["ignored"]
print(f" {DIM}WayClick prediction: {a} active, {f} filtered, {i} ignored "
      f"({len(devices)} total){RESET}")
print()
PYTHON_EOF
