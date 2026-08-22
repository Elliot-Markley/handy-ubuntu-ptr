#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Handy GNOME Wayland Setup
#
# Configures:
#   - ydotool
#   - /dev/uinput permissions
#   - input group membership
#   - Handy external paste script
#   - Push-to-Talk using python3-evdev
#   - Automatic keyboard/keybind detection
#   - systemd user service for Push-to-Talk
#
# Run this script as your NORMAL USER, not with sudo.
# ============================================================


# ------------------------------------------------------------
# Formatting
# ------------------------------------------------------------

info() {
    printf '\n\033[1;34m[INFO]\033[0m %s\n' "$1"
}

success() {
    printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$1"
}

fail() {
    printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"
    exit 1
}


# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this installer with sudo. Run: ./install.sh"
fi

TARGET_USER="${USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" ]]; then
    fail "Could not determine home directory for $TARGET_USER."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PASTE_SOURCE="$SCRIPT_DIR/handy-paste-wl-copy"
PASTE_DEST="$TARGET_HOME/.local/bin/handy-paste-wl-copy"

PTT_DEST="$TARGET_HOME/.local/bin/handy-ptt"

CONFIG_DIR="$TARGET_HOME/.config/handy-ptt"
CONFIG_FILE="$CONFIG_DIR/config.json"

SYSTEMD_DIR="$TARGET_HOME/.config/systemd/user"
SYSTEMD_SERVICE="$SYSTEMD_DIR/handy-ptt.service"

info "Configuring Handy for user: $TARGET_USER"
info "Home directory: $TARGET_HOME"


# ------------------------------------------------------------
# Check required repo files
# ------------------------------------------------------------

if [[ ! -f "$PASTE_SOURCE" ]]; then
    fail "Could not find handy-paste-wl-copy next to install.sh."
fi


# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

info "Installing required packages..."

sudo apt-get update

sudo apt-get install -y \
    ydotool \
    python3-evdev

success "Required packages installed."


# ------------------------------------------------------------
# Configure uinput
# ------------------------------------------------------------

info "Loading uinput kernel module..."

sudo modprobe uinput

if [[ ! -e /dev/uinput ]]; then
    fail "/dev/uinput was not created."
fi

success "/dev/uinput exists."


info "Configuring uinput to load automatically..."

echo 'uinput' \
    | sudo tee /etc/modules-load.d/uinput.conf >/dev/null

success "uinput will load automatically at boot."


# ------------------------------------------------------------
# Configure /dev/uinput permissions
# ------------------------------------------------------------

info "Creating udev rule for /dev/uinput..."

echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
    | sudo tee /etc/udev/rules.d/60-uinput.rules >/dev/null

sudo udevadm control --reload-rules
sudo udevadm trigger

success "udev rule installed."


# ------------------------------------------------------------
# Ensure input group exists
# ------------------------------------------------------------

if ! getent group input >/dev/null 2>&1; then
    info "Creating input group..."
    sudo groupadd input
fi

success "input group exists."


# ------------------------------------------------------------
# Add user to input group
# ------------------------------------------------------------

GROUP_ADDED=false

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx input; then
    success "$TARGET_USER is already a member of input."
else
    info "Adding $TARGET_USER to input group..."

    sudo usermod -aG input "$TARGET_USER"

    GROUP_ADDED=true

    success "$TARGET_USER added to input group."
fi


# ------------------------------------------------------------
# Install Handy external paste script
# ------------------------------------------------------------

info "Installing Handy external paste script..."

mkdir -p "$TARGET_HOME/.local/bin"

install -m 0755 \
    "$PASTE_SOURCE" \
    "$PASTE_DEST"

success "Installed:"
echo "      $PASTE_DEST"


# ------------------------------------------------------------
# Push-to-Talk keybind capture
# ------------------------------------------------------------

info "Configuring Push-to-Talk keybind."

echo
echo "You will now choose your Push-to-Talk shortcut."
echo
echo "When prompted:"
echo
echo "  1. Press and HOLD all keys in your desired shortcut."
echo "  2. Once all keys are held, release them."
echo
echo "Example:"
echo
echo "  Ctrl + Shift + Space"
echo
read -rp "Press Enter when ready..."


capture_keybind() {

sudo python3 <<'PY'
from evdev import InputDevice, ecodes, list_devices
import selectors
import pathlib
import os
import json
import sys

devices = []

for path in list_devices():
    try:
        device = InputDevice(path)
        caps = device.capabilities()

        if ecodes.EV_KEY in caps:
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

print(
    "\nPress and HOLD your desired Push-to-Talk combination...",
    file=sys.stderr
)
print(
    "Release all keys when the complete combination is held.\n",
    file=sys.stderr
)

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

            if event.type != ecodes.EV_KEY:
                continue

            # Ignore autorepeat.
            if event.value == 2:
                continue

            # First key pressed chooses the keyboard device.
            if active_device is None and event.value == 1:
                active_device = device

                print(
                    f"Detected device: {device.name}",
                    file=sys.stderr
                )

            if active_device is None:
                continue

            if device.path != active_device.path:
                continue

            # Key pressed.
            if event.value == 1:

                pressed.add(event.code)

                if event.code not in captured:
                    captured.append(event.code)

            # Key released.
            elif event.value == 0:

                pressed.discard(event.code)

                # Capture completes after all keys involved in the
                # chord have been released.
                if captured and not pressed:

                    event_path = active_device.path
                    real_event = os.path.realpath(event_path)

                    stable_path = None

                    # Prefer /dev/input/by-id
                    by_id = pathlib.Path("/dev/input/by-id")

                    if by_id.exists():

                        candidates = []

                        for item in by_id.iterdir():

                            try:
                                if os.path.realpath(item) == real_event:
                                    candidates.append(str(item))
                            except Exception:
                                pass

                        # Prefer the keyboard-specific symlink.
                        for candidate in candidates:
                            if "event-kbd" in candidate:
                                stable_path = candidate
                                break

                        if stable_path is None and candidates:
                            stable_path = candidates[0]

                    # Fall back to /dev/input/by-path
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

                            for candidate in candidates:
                                if "event-kbd" in candidate:
                                    stable_path = candidate
                                    break

                            if stable_path is None and candidates:
                                stable_path = candidates[0]

                    # Last resort: raw event number.
                    if stable_path is None:
                        stable_path = event_path

                    names = []

                    for code in captured:

                        name = ecodes.KEY.get(code, str(code))

                        if isinstance(name, list):
                            name = name[0]

                        names.append(name)

                    result = {
                        "device": stable_path,
                        "device_name": active_device.name,
                        "keys": captured,
                        "key_names": names,
                        "chord_window": 0.30
                    }

                    print(json.dumps(result))
                    sys.exit(0)
PY

}


while true; do

    CAPTURE_JSON="$(capture_keybind)"

    if [[ "$CAPTURE_JSON" == ERROR:* ]]; then
        fail "Could not detect keyboard input devices."
    fi

    DEVICE_NAME="$(
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["device_name"])' \
        <<< "$CAPTURE_JSON"
    )"

    DEVICE_PATH="$(
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["device"])' \
        <<< "$CAPTURE_JSON"
    )"

    KEY_NAMES="$(
        python3 -c \
        'import json,sys; print(" + ".join(json.load(sys.stdin)["key_names"]))' \
        <<< "$CAPTURE_JSON"
    )"

    echo
    echo "Detected keyboard:"
    echo
    echo "  $DEVICE_NAME"
    echo
    echo "Detected Push-to-Talk shortcut:"
    echo
    echo "  $KEY_NAMES"
    echo
    echo "Device path:"
    echo
    echo "  $DEVICE_PATH"
    echo

    read -rp "Use this configuration? [Y/n]: " CONFIRM

    CONFIRM="${CONFIRM:-Y}"

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        break
    fi

    echo
    echo "Let's try again."
    echo
    read -rp "Press Enter when ready..."

done


# ------------------------------------------------------------
# Save PTT configuration
# ------------------------------------------------------------

info "Saving Push-to-Talk configuration..."

mkdir -p "$CONFIG_DIR"

printf '%s\n' "$CAPTURE_JSON" > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

success "Configuration saved:"
echo "      $CONFIG_FILE"



# ------------------------------------------------------------
# Install Push-to-Talk listener
# ------------------------------------------------------------

info "Installing Push-to-Talk listener..."

# If a previous install created the file as root or another user,
# repair ownership before attempting to overwrite it.
if [[ -e "$PTT_DEST" ]]; then

    CURRENT_OWNER="$(stat -c '%U' "$PTT_DEST")"
    CURRENT_GROUP="$(stat -c '%G' "$PTT_DEST")"

    if [[ "$CURRENT_OWNER" != "$TARGET_USER" ]]; then

        warn "Existing handy-ptt is owned by $CURRENT_OWNER:$CURRENT_GROUP."
        info "Repairing ownership..."

        sudo chown \
            "$TARGET_USER":"$(id -gn "$TARGET_USER")" \
            "$PTT_DEST"

        success "Ownership repaired."

    fi

fi

cat > "$PTT_DEST" <<'PYTHON'
#!/usr/bin/env python3

import json
import os
import subprocess
import time

from evdev import InputDevice, ecodes


CONFIG_FILE = os.path.expanduser(
    "~/.config/handy-ptt/config.json"
)


with open(CONFIG_FILE, "r") as f:
    config = json.load(f)


DEVICE = config["device"]
TARGET_KEYS = set(config["keys"])
CHORD_WINDOW = float(
    config.get("chord_window", 0.30)
)


device = InputDevice(DEVICE)

pressed = set()
press_times = {}

recording = False


def toggle_handy():

    subprocess.Popen(
        [
            "/usr/bin/handy",
            "--toggle-transcription"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def combo_down():

    return TARGET_KEYS.issubset(pressed)


def combo_within_window():

    if not combo_down():
        return False

    times = [
        press_times[key]
        for key in TARGET_KEYS
        if key in press_times
    ]

    if len(times) != len(TARGET_KEYS):
        return False

    return (
        max(times) - min(times)
        <= CHORD_WINDOW
    )



for event in device.read_loop():

    if event.type != ecodes.EV_KEY:
        continue

    # Ignore keyboard autorepeat.
    if event.value == 2:
        continue

    # Key press
    if event.value == 1:

        pressed.add(event.code)

        if event.code in TARGET_KEYS:
            press_times[event.code] = time.monotonic()

        if (
            not recording
            and combo_down()
            and combo_within_window()
        ):
            toggle_handy()
            recording = True

    # Key release
    elif event.value == 0:

        pressed.discard(event.code)

        if (
            recording
            and not (TARGET_KEYS & pressed)
        ):

            # Let GNOME process all modifier releases before
            # Handy finishes and ydotool starts typing.
            time.sleep(0.05)

            toggle_handy()

            recording = False
            press_times.clear()


PYTHON

chmod 0755 "$PTT_DEST"

# Ensure the finished file belongs to the intended user even if
# something unusual happened during a previous installation.
sudo chown \
    "$TARGET_USER":"$(id -gn "$TARGET_USER")" \
    "$PTT_DEST"

success "Installed:"
echo "      $PTT_DEST"




# ------------------------------------------------------------
# Install systemd user service
# ------------------------------------------------------------

info "Installing Push-to-Talk user service..."

mkdir -p "$SYSTEMD_DIR"

cat > "$SYSTEMD_SERVICE" <<EOF
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
EOF

systemctl --user daemon-reload

systemctl --user enable handy-ptt.service

success "handy-ptt.service enabled."


# ------------------------------------------------------------
# Verify /dev/uinput
# ------------------------------------------------------------

info "Checking /dev/uinput..."

ls -l /dev/uinput

UINPUT_GROUP="$(stat -c '%G' /dev/uinput)"
UINPUT_MODE="$(stat -c '%a' /dev/uinput)"

if [[ "$UINPUT_GROUP" == "input" ]]; then
    success "/dev/uinput belongs to input."
else
    warn "/dev/uinput group is '$UINPUT_GROUP' instead of input."
fi

if [[ "$UINPUT_MODE" == "660" ]]; then
    success "/dev/uinput permissions are 0660."
else
    warn "/dev/uinput permissions are $UINPUT_MODE instead of 660."
fi


# ------------------------------------------------------------
# Check Handy
# ------------------------------------------------------------

if command -v handy >/dev/null 2>&1; then

    success "Handy detected:"
    echo "      $(command -v handy)"

else

    warn "Handy was not found in PATH."

fi


# ------------------------------------------------------------
# Finished
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                  Installation complete"
echo "============================================================"
echo
echo "Push-to-Talk shortcut:"
echo
echo "  $KEY_NAMES"
echo
echo "Handy paste script:"
echo
echo "  $PASTE_DEST"
echo
echo
echo "Configure Handy:"
echo
echo "  Paste Method:"
echo "      External Script"
echo
echo "  External Script Path:"
echo "      $PASTE_DEST"
echo
echo "  Clipboard Handling:"
echo "      Don't Modify"
echo
echo "  Recording/Transcription Overlay:"
echo "      Disabled"
echo
echo
echo "IMPORTANT:"
echo
echo "  Remove any GNOME custom keyboard shortcut that uses the"
echo "  same Push-to-Talk combination."
echo
echo "  The handy-ptt service now handles the shortcut directly."
echo
echo
echo "A reboot is recommended before testing."
echo
echo "After reboot, verify:"
echo
echo "  groups"
echo
echo '  test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"'
echo
echo "Check the Push-to-Talk service with:"
echo
echo "  systemctl --user status handy-ptt"
echo
echo "To watch the service log:"
echo
echo "  journalctl --user -u handy-ptt -f"
echo

