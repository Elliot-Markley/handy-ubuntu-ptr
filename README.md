# Handy on Ubuntu GNOME Wayland

Automated setup for using [Handy](https://github.com/cjpais/Handy) dictation with GNOME Wayland on Ubuntu.

This configuration uses `ydotool` and Linux's `/dev/uinput` interface to type Handy transcriptions directly into the currently focused application.

## Why This Is Needed

GNOME Wayland restricts applications from programmatically injecting keyboard input using many of the methods that work under X11.

`ydotool` works around this by emulating keyboard input through Linux's `/dev/uinput` device.

The resulting path is:

```text
Handy
  ↓
External Script
  ↓
ydotool
  ↓
/dev/uinput
  ↓
Focused Application
```

No clipboard emulation is required.

## Installation

Clone the repository:

```bash
git clone https://github.com/Elliot-Markley/handy-ubuntu-ptr.git
cd handy-ubuntu-ptr
```

Make the installer executable:

```bash
chmod +x install.sh
```

Run it as your **normal user**:

```bash
./install.sh
```

Do **not** run:

```bash
sudo ./install.sh
```

The installer will request sudo access when it needs to make system-level changes.

## What the Installer Does

The installer:

* Installs `ydotool`
* Loads the `uinput` kernel module
* Configures `uinput` to load automatically during boot
* Creates the required udev rule
* Gives the `input` group read/write access to `/dev/uinput`
* Adds your user account to the `input` group
* Installs the Handy helper script to:

```text
~/.local/bin/handy-paste-wl-copy
```

* Performs basic diagnostics
* Detects whether Handy is installed
* Prints the remaining Handy configuration steps

## Log Out After Installation

If the installer adds your account to the `input` group, you must **log completely out of Ubuntu and log back in**.

Opening another terminal is not sufficient.

After logging back in, verify:

```bash
groups
```

`input` should appear in the list.

Then verify access to `/dev/uinput`:

```bash
test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"
```

Expected result:

```text
uinput OK
```

## Test ydotool

Before configuring Handy, test keyboard injection directly.

Open GNOME Text Editor.

Then run:

```bash
sleep 5; /usr/bin/ydotool type --key-delay 0 "manual-test"
```

Switch back to Text Editor before the five seconds expire.

You should see:

```text
manual-test
```

typed into the editor.

You may see:

```text
ydotool: notice: ydotoold backend unavailable (may have latency+delay issues)
```

This is expected with the Ubuntu `ydotool` configuration used here.

`ydotoold` is not required for this setup.

## Test the Handy Helper

Next test the external script directly:

```bash
sleep 5; ~/.local/bin/handy-paste-wl-copy "script-test"
```

Switch to Text Editor.

You should see:

```text
script-test
```

If both tests work, the Linux side of the setup is working.

## Configure Handy

Open Handy's advanced settings.

Set:

```text
Paste Method:
External Script
```

Set the external script path to the complete path printed by the installer.

For example:

```text
/home/elliot/.local/bin/handy-paste-wl-copy
```

Do not use:

```text
~/.local/bin/handy-paste-wl-copy
```

Use the complete absolute path.

If available, set:

```text
Clipboard Handling:
Don't Modify
```

## IMPORTANT: Disable Handy's Overlay

Disable Handy's recording/transcription overlay.

This is essential for this setup under GNOME Wayland.

The overlay can become the focused Wayland surface while Handy is recording or transcribing. `ydotool` then sends its simulated keyboard input to the wrong surface instead of the application you were originally using.

This can result in the confusing situation where:

```text
Handy records successfully
        ↓
Handy transcribes successfully
        ↓
External script runs successfully
        ↓
ydotool exits successfully
        ↓
Nothing appears
```

If everything works manually but Handy doesn't type the transcription, **check the overlay first**.

## Troubleshooting

### Check `/dev/uinput`

Run:

```bash
ls -l /dev/uinput
```

Expected permissions should look approximately like:

```text
crw-rw---- 1 root input ... /dev/uinput
```

The important values are:

```text
Owner: root
Group: input
Mode:  0660
```

### Check Your Groups

Run:

```bash
groups
```

You should see:

```text
input
```

### Check Write Access

Run:

```bash
test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"
```

### `failed to open uinput device`

If you receive:

```text
failed to open uinput device
Aborted (core dumped)
```

check:

```bash
ls -l /dev/uinput
groups
```

If you were recently added to the `input` group, log completely out and back in.

### `ydotoold backend unavailable`

The warning:

```text
ydotoold backend unavailable
```

does not by itself indicate a problem.

If:

```bash
ydotool type --key-delay 0 "test"
```

successfully types text, the warning can be ignored.

### Check Handy's Log

Watch the Handy log:

```bash
tail -f ~/.local/share/com.pais.handy/logs/handy.log
```

Perform a transcription.

You should see something similar to:

```text
Using paste method: ExternalScript
Pasting via external script: /home/YOUR-USER/.local/bin/handy-paste-wl-copy
Text pasted successfully
```

### Manual ydotool Works but Handy Doesn't

If this works:

```bash
sleep 5; ydotool type --key-delay 0 "manual-test"
```

and this works:

```bash
sleep 5; ~/.local/bin/handy-paste-wl-copy "script-test"
```

but Handy still doesn't type transcriptions:

**Disable Handy's overlay.**

That is likely a window-focus issue rather than a `ydotool` or `/dev/uinput` issue.

## Updating

Pull the newest version:

```bash
cd handy-ubuntu-wayland
git pull
```

Then rerun:

```bash
./install.sh
```

The installer is designed to be safe to run again.

## Files Installed

System configuration:

```text
/etc/modules-load.d/uinput.conf
/etc/udev/rules.d/60-uinput.rules
```

User script:

```text
~/.local/bin/handy-paste-wl-copy
```

## Tested Configuration

This setup is intended for:

```text
Ubuntu
GNOME
Wayland
Handy
ydotool 0.1.8
```

Newer versions of `ydotool` may behave differently, particularly regarding the optional `ydotoold` daemon.
