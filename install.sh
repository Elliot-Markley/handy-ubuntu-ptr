#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Handy GNOME Wayland Setup
#
# Configures ydotool + /dev/uinput for use with Handy's
# External Script paste method on Ubuntu GNOME Wayland.
# ============================================================

# ---------- Formatting ----------

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

# ---------- Determine target user ----------

# Normally this script should be run without sudo.
# SUDO_USER provides a fallback if someone does run it with sudo.
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" ]]; then
    fail "Could not determine home directory for user '$TARGET_USER'."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HANDY_SCRIPT_SOURCE="$SCRIPT_DIR/handy-paste-wl-copy"
HANDY_SCRIPT_DEST="$TARGET_HOME/.local/bin/handy-paste-wl-copy"

info "Configuring Handy Wayland support for user: $TARGET_USER"
info "Home directory: $TARGET_HOME"

# ---------- Sanity checks ----------

if [[ ! -f "$HANDY_SCRIPT_SOURCE" ]]; then
    fail "Could not find handy-paste-wl-copy next to install.sh."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    fail "apt-get was not found. This installer is intended for Ubuntu/Debian-based systems."
fi

if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" ]]; then
    warn "This script appears to be running directly as root."
    warn "It is intended to be run from a normal user account."
fi

# ---------- Install ydotool ----------

info "Installing ydotool..."

sudo apt-get update
sudo apt-get install -y ydotool

if command -v ydotool >/dev/null 2>&1; then
    success "ydotool is installed: $(command -v ydotool)"
else
    fail "ydotool installation failed."
fi

# ---------- Configure uinput module ----------

info "Loading the uinput kernel module..."

sudo modprobe uinput

if [[ -e /dev/uinput ]]; then
    success "/dev/uinput exists."
else
    fail "/dev/uinput was not created after loading the uinput module."
fi

info "Configuring uinput to load automatically at boot..."

echo 'uinput' | sudo tee /etc/modules-load.d/uinput.conf >/dev/null

success "Created /etc/modules-load.d/uinput.conf"

# ---------- Configure udev permissions ----------

info "Creating udev rule for /dev/uinput..."

echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
    | sudo tee /etc/udev/rules.d/60-uinput.rules >/dev/null

sudo udevadm control --reload-rules
sudo udevadm trigger

success "Installed /etc/udev/rules.d/60-uinput.rules"

# ---------- Ensure input group exists ----------

if getent group input >/dev/null 2>&1; then
    success "input group exists."
else
    info "Creating input group..."
    sudo groupadd input
    success "Created input group."
fi

# ---------- Add user to input group ----------

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx input; then
    success "$TARGET_USER is already a member of the input group."
    GROUP_ADDED=false
else
    info "Adding $TARGET_USER to the input group..."

    sudo usermod -aG input "$TARGET_USER"

    success "Added $TARGET_USER to the input group."
    GROUP_ADDED=true
fi

# ---------- Install Handy helper ----------

info "Installing Handy external script..."

mkdir -p "$TARGET_HOME/.local/bin"

install -m 0755 \
    "$HANDY_SCRIPT_SOURCE" \
    "$HANDY_SCRIPT_DEST"

# Correct ownership in case the installer was launched through sudo.
if [[ $EUID -eq 0 ]]; then
    chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$HANDY_SCRIPT_DEST"
fi

success "Installed:"
echo "      $HANDY_SCRIPT_DEST"

# ---------- Verify uinput permissions ----------

info "Checking /dev/uinput permissions..."

UINPUT_INFO="$(ls -l /dev/uinput)"
echo "      $UINPUT_INFO"

UINPUT_GROUP="$(stat -c '%G' /dev/uinput)"
UINPUT_MODE="$(stat -c '%a' /dev/uinput)"

if [[ "$UINPUT_GROUP" == "input" ]]; then
    success "/dev/uinput belongs to the input group."
else
    warn "/dev/uinput group is '$UINPUT_GROUP' instead of 'input'."
fi

if [[ "$UINPUT_MODE" == "660" ]]; then
    success "/dev/uinput permissions are 0660."
else
    warn "/dev/uinput permissions are $UINPUT_MODE instead of 660."
fi

# ---------- Check Handy ----------

if command -v handy >/dev/null 2>&1; then
    success "Handy was detected: $(command -v handy)"
else
    warn "Handy was not found in PATH."
    warn "Install Handy separately before completing the GUI configuration."
fi

# ---------- Final instructions ----------

echo
echo "============================================================"
echo "                 Installation complete"
echo "============================================================"
echo
echo "Handy external script:"
echo
echo "  $HANDY_SCRIPT_DEST"
echo
echo "Configure Handy:"
echo
echo "  Paste Method:       External Script"
echo "  External Script:    $HANDY_SCRIPT_DEST"
echo "  Clipboard Handling: Don't Modify"
echo
echo "IMPORTANT:"
echo
echo "  Disable Handy's recording/transcription overlay."
echo
echo "  The overlay can steal focus under GNOME Wayland and prevent"
echo "  the transcript from being typed into the intended window."
echo

if [[ "$GROUP_ADDED" == true ]]; then
    warn "You MUST log out of Ubuntu and log back in before testing."
    echo
    echo "Your current desktop session does not yet have the new"
    echo "'input' group membership."
else
    echo "You can test ydotool with:"
    echo
    echo '  sleep 5; /usr/bin/ydotool type --key-delay 0 "manual-test"'
fi

echo
echo "After logging back in, verify with:"
echo
echo "  groups"
echo '  test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"'
echo
