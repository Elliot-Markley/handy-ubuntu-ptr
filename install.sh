#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Handy GNOME Wayland Installer
# ============================================================

info()    { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$1"; }
success() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
fail()    { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this installer with sudo. Run it as your normal user: ./install.sh"
fi

TARGET_USER="${USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
PRIMARY_GROUP="$(id -gn "$TARGET_USER")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

[[ -n "$TARGET_HOME" ]] || fail "Could not determine home directory for $TARGET_USER."

BIN_DIR="$TARGET_HOME/.local/bin"
PASTE_DEST="$BIN_DIR/handy-paste-wl-copy"
PTT_DEST="$BIN_DIR/handy-ptt"
CONFIG_DIR="$TARGET_HOME/.config/handy-ptt"
CONFIG_FILE="$CONFIG_DIR/config.json"
SYSTEMD_DIR="$TARGET_HOME/.config/systemd/user"
SYSTEMD_SERVICE="$SYSTEMD_DIR/handy-ptt.service"
HANDY_BIN="/usr/bin/handy"
CHORD_WINDOW="0.50"

info "Configuring Handy for user: $TARGET_USER"
info "Home directory: $TARGET_HOME"

info "Installing required packages..."
sudo apt-get update
sudo apt-get install -y ydotool python3-evdev
success "Required packages installed."

info "Configuring uinput..."
sudo modprobe uinput
[[ -e /dev/uinput ]] || fail "/dev/uinput was not created."
echo 'uinput' | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
    | sudo tee /etc/udev/rules.d/60-uinput.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger
success "uinput configured."

if ! getent group input >/dev/null 2>&1; then
    info "Creating input group..."
    sudo groupadd input
fi

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx input; then
    success "$TARGET_USER is already a member of input."
else
    info "Adding $TARGET_USER to input group..."
    sudo usermod -aG input "$TARGET_USER"
    success "$TARGET_USER added to input group."
fi

for dir in "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR"; do
    if [[ -e "$dir" && ! -w "$dir" ]]; then
        warn "$dir is not writable by $TARGET_USER; repairing ownership."
        sudo chown -R "$TARGET_USER:$PRIMARY_GROUP" "$dir"
    fi
    mkdir -p "$dir"
done

info "Installing Handy external paste script..."
rm -f "$PASTE_DEST" 2>/dev/null || sudo rm -f "$PASTE_DEST"
cat > "$PASTE_DEST" <<'__PASTE__'
#!/usr/bin/env bash
set -u
TEXT="${1:-}"
[[ -z "$TEXT" ]] && exit 0

env -i \
    HOME="${HOME}" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG="${LANG:-en_US.UTF-8}" \
    /usr/bin/ydotool type --key-delay 0 "$TEXT" >/dev/null 2>&1
__PASTE__
chmod 0755 "$PASTE_DEST"
bash -n "$PASTE_DEST" || fail "Generated paste script failed syntax check."
success "Installed: $PASTE_DEST"

info "Configuring Push-to-Talk keybind."
echo
echo "Press and HOLD the key combination you want to use for Push-to-Talk."
echo "Release all keys once the full combination is held."
echo "Example: Ctrl + Shift + Space"
echo
read -rp "Press Enter when ready..."

capture_keybind() {
    sudo python3 <<PY
from evdev import InputDevice, ecodes, list_devices
import selectors, pathlib, os, json, sys

devices = []
for path in list_devices():
    try:
        device = InputDevice(path)
        if ecodes.EV_KEY in device.capabilities():
            devices.append(device)
    except Exception:
        pass

if not devices:
    print("ERROR:NO_INPUT_DEVICES")
    sys.exit(1)

selector = selectors.DefaultSelector()
for device in devices:
    try:
        selector.register(device, selectors.EVENT_READ)
    except Exception:
        pass

print("\nPress and HOLD your desired Push-to-Talk combination...", file=sys.stderr)
print("Release all keys when the full combination is held.\n", file=sys.stderr)

active_device = None
pressed = set()
captured = []

while True:
    for key, _ in selector.select():
        device = key.fileobj
        try:
            events = device.read()
        except Exception:
            continue

        for event in events:
            if event.type != ecodes.EV_KEY or event.value == 2:
                continue

            if active_device is None and event.value == 1:
                active_device = device
                print(f"Detected device: {device.name}", file=sys.stderr)

            if active_device is None or device.path != active_device.path:
                continue

            if event.value == 1:
                pressed.add(event.code)
                if event.code not in captured:
                    captured.append(event.code)

            elif event.value == 0:
                pressed.discard(event.code)
                if captured and not pressed:
                    event_path = active_device.path
                    real_event = os.path.realpath(event_path)
                    stable_path = None

                    by_id = pathlib.Path("/dev/input/by-id")
                    if by_id.exists():
                        candidates = []
                        for item in by_id.iterdir():
                            try:
                                if os.path.realpath(item) == real_event:
                                    candidates.append(str(item))
                            except Exception:
                                pass
                        stable_path = next((p for p in candidates if "event-kbd" in p), candidates[0] if candidates else None)

                    if stable_path is None:
                        by_path = pathlib.Path("/dev/input/by-path")
                        if by_path.exists():
                            candidates = []
                            for item in by_path.iterdir():
                                try:
                                    if os.path.realpath(item) == real_event:
                                        candidates.append(str(item))
                                except Exception:
                                    pass
                            stable_path = next((p for p in candidates if "event-kbd" in p), candidates[0] if candidates else None)

                    if stable_path is None:
                        stable_path = event_path

                    names = []
                    for code in captured:
                        name = ecodes.KEY.get(code, str(code))
                        if isinstance(name, list):
                            name = name[0]
                        names.append(name)

                    print(json.dumps({
                        "device": stable_path,
                        "device_name": active_device.name,
                        "keys": captured,
                        "key_names": names,
                        "chord_window": $CHORD_WINDOW,
                        "handy_bin": "$HANDY_BIN"
                    }))
                    sys.exit(0)
PY
}

OLD_STTY="$(stty -g 2>/dev/null || true)"
restore_tty() {
    [[ -n "${OLD_STTY:-}" ]] && stty "$OLD_STTY" 2>/dev/null || true
}
trap restore_tty EXIT

while true; do
    [[ -n "$OLD_STTY" ]] && stty -echo -echoctl 2>/dev/null || true

    CAPTURE_JSON="$(capture_keybind)"

    # Flush any characters/escape sequences the captured shortcut
    # also sent to the terminal, such as F-keys or Ctrl combinations.
    python3 - <<'PY'
import os
import termios

try:
    fd = os.open("/dev/tty", os.O_RDONLY | os.O_NONBLOCK)
    termios.tcflush(fd, termios.TCIFLUSH)
    os.close(fd)
except Exception:
    pass
PY

    restore_tty

    [[ "$CAPTURE_JSON" != ERROR:* ]] || fail "Could not detect keyboard input devices."

    DEVICE_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["device_name"])' <<< "$CAPTURE_JSON")"
    DEVICE_PATH="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["device"])' <<< "$CAPTURE_JSON")"
    KEY_NAMES="$(python3 -c 'import json,sys; print(" + ".join(json.load(sys.stdin)["key_names"]))' <<< "$CAPTURE_JSON")"

    echo
    echo "Detected keyboard:"
    echo "  $DEVICE_NAME"
    echo
    echo "Detected Push-to-Talk shortcut:"
    echo "  $KEY_NAMES"
    echo
    echo "Device path:"
    echo "  $DEVICE_PATH"
    echo

    # Give any terminal escape sequence from the captured shortcut time to arrive.
sleep 0.1

# Flush anything the shortcut left in the terminal input buffer.
python3 - <<'PY'
import os
import termios

try:
    fd = os.open("/dev/tty", os.O_RDONLY | os.O_NONBLOCK)
    termios.tcflush(fd, termios.TCIFLUSH)
    os.close(fd)
except Exception:
    pass
PY

read -rp "Use this configuration? [Y/n]: " CONFIRM

# Strip control characters / escape-sequence debris.
CONFIRM="$(printf '%s' "$CONFIRM" | tr -cd '[:alpha:]')"
CONFIRM="${CONFIRM:-Y}"

case "${CONFIRM,,}" in
    y|yes)
        break
        ;;
    n|no)
        ;;
    *)
        echo "Please enter Y or N."
        continue
        ;;
esac

    echo
    read -rp "Press Enter to capture another shortcut..."
done

restore_tty
trap - EXIT

info "Saving Push-to-Talk configuration..."
rm -f "$CONFIG_FILE" 2>/dev/null || sudo rm -f "$CONFIG_FILE"
printf '%s\n' "$CAPTURE_JSON" > "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"
success "Configuration saved: $CONFIG_FILE"

info "Installing Push-to-Talk listener..."
rm -f "$PTT_DEST" 2>/dev/null || sudo rm -f "$PTT_DEST"
cat > "$PTT_DEST" <<'__PTT__'
#!/usr/bin/env python3

import json
import os
import subprocess
import time
from evdev import InputDevice, ecodes

CONFIG_FILE = os.path.expanduser("~/.config/handy-ptt/config.json")

with open(CONFIG_FILE, "r") as f:
    config = json.load(f)

DEVICE = config["device"]
TARGET_KEYS = set(config["keys"])
CHORD_WINDOW = float(config.get("chord_window", 0.50))
HANDY_BIN = config.get("handy_bin", "/usr/bin/handy")

device = InputDevice(DEVICE)
pressed = set()
press_times = {}
recording = False


def toggle_handy():
    subprocess.run(
        [HANDY_BIN, "--toggle-transcription"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


for event in device.read_loop():
    if event.type != ecodes.EV_KEY or event.value == 2:
        continue

    if event.code not in TARGET_KEYS:
        continue

    if event.value == 1:
        pressed.add(event.code)
        press_times[event.code] = time.monotonic()

        if not recording and TARGET_KEYS.issubset(pressed):
            times = [press_times[key] for key in TARGET_KEYS]
            spread = max(times) - min(times)

            if spread <= CHORD_WINDOW:
                toggle_handy()
                recording = True

    elif event.value == 0:
        pressed.discard(event.code)

        if recording and not pressed:
            time.sleep(0.05)
            toggle_handy()
            recording = False
            press_times.clear()
__PTT__
chmod 0755 "$PTT_DEST"
python3 -m py_compile "$PTT_DEST" || fail "Generated PTT listener failed Python syntax check."
success "Installed: $PTT_DEST"

info "Installing Push-to-Talk user service..."
rm -f "$SYSTEMD_SERVICE" 2>/dev/null || sudo rm -f "$SYSTEMD_SERVICE"
cat > "$SYSTEMD_SERVICE" <<__SERVICE__
[Unit]
Description=Handy Push-to-Talk Listener
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PTT_DEST
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
__SERVICE__

systemctl --user daemon-reload
systemctl --user enable handy-ptt.service
success "handy-ptt.service enabled."

info "Checking /dev/uinput..."
ls -l /dev/uinput

UINPUT_GROUP="$(stat -c '%G' /dev/uinput)"
UINPUT_MODE="$(stat -c '%a' /dev/uinput)"
[[ "$UINPUT_GROUP" == "input" ]] && success "/dev/uinput belongs to input." || warn "/dev/uinput group is '$UINPUT_GROUP' instead of input."
[[ "$UINPUT_MODE" == "660" ]] && success "/dev/uinput permissions are 0660." || warn "/dev/uinput permissions are $UINPUT_MODE instead of 660."

if [[ -x "$HANDY_BIN" ]]; then
    success "Handy detected: $HANDY_BIN"
else
    warn "Handy was not found at $HANDY_BIN."
fi

# ------------------------------------------------------------
# Install post-reboot verification
# ------------------------------------------------------------

info "Installing post-reboot verification..."

POSTINSTALL_SOURCE="$SCRIPT_DIR/handy-postinstall-check"
POSTINSTALL_DEST="$TARGET_HOME/.local/bin/handy-postinstall-check"

AUTOSTART_DIR="$TARGET_HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/handy-postinstall.desktop"

if [[ ! -f "$POSTINSTALL_SOURCE" ]]; then
    fail "Could not find handy-postinstall-check next to install.sh."
fi

mkdir -p "$AUTOSTART_DIR"

rm -f "$POSTINSTALL_DEST" 2>/dev/null || sudo rm -f "$POSTINSTALL_DEST"

install -m 0755 \
    "$POSTINSTALL_SOURCE" \
    "$POSTINSTALL_DEST"

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Handy Post-Install Check
Comment=Verify Handy Push-to-Talk setup
Exec=/usr/bin/gnome-terminal -- $POSTINSTALL_DEST
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

success "Post-reboot verification installed."

echo
echo "============================================================"
echo "                  Installation complete"
echo "============================================================"
echo
echo "Push-to-Talk shortcut:"
echo "  $KEY_NAMES"
echo
echo "Configure Handy:"
echo "  Paste Method: External Script"
echo "  External Script Path: $PASTE_DEST"
echo "  Clipboard Handling: Don't Modify"
echo "  Recording/Transcription Overlay: Disabled"
echo
echo "Remove any GNOME custom shortcut using the same PTT chord."
echo "Reboot before testing so input-group membership is active."
echo
echo "After reboot:"
echo "  groups"
echo '  test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"'
echo "  systemctl --user status handy-ptt"
echo

