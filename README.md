# Handy on Ubuntu GNOME Wayland

Quick setup for getting **Handy dictation working on Ubuntu GNOME Wayland** using `ydotool`.

The installer configures `/dev/uinput`, installs `ydotool`, adds your user to the required `input` group, and installs the external typing script.

## 1. Clone and Run the Installer

Open Terminal:

```bash
git clone https://github.com/Elliot-Markley/handy-ubuntu-ptr.git
cd handy-ubuntu-ptr
chmod +x install.sh
./install.sh
```

Run the installer as your **normal user**, not with `sudo`.

Enter your password when the installer requests sudo access.

## 2. Reboot

After installation:

```bash
sudo reboot
```

A reboot is required for the new `input` group membership to take effect reliably.

After logging back in, you can verify everything is ready with:

```bash
groups
test -w /dev/uinput && echo "uinput OK" || echo "uinput DENIED"
```

`input` should appear in your groups and the second command should return:

```text
uinput OK
```

## 3. Configure Handy

Open **Handy → Settings → Advanced**.

Set:

**Paste Method**

```text
External Script
```

**External Script Path**

Use your own home directory:

```text
/home/YOUR_USERNAME/.local/bin/handy-paste-wl-copy
```

For example, if your username is `ptr`:

```text
/home/ptr/.local/bin/handy-paste-wl-copy
```

Do **not** copy another machine's username into this path.

You can find the correct path with:

```bash
echo "$HOME/.local/bin/handy-paste-wl-copy"
```

**Clipboard Handling**

```text
Don't Modify
```

## 4. Disable Handy's Overlay

In Handy's settings, disable the recording/transcription **overlay**.

This is important on GNOME Wayland. The overlay can steal focus from the application you're typing into, causing the transcription to disappear instead of being typed into the focused window.

## 5. Create an Ubuntu Keyboard Shortcut

Handy's built-in global keybind may not work correctly under GNOME Wayland, so use a GNOME custom keyboard shortcut instead.

First verify Handy's command works:

```bash
/usr/bin/handy --toggle-transcription
```

Running it once should start recording. Running it again should stop recording and transcribe.

Then open:

**Ubuntu Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**

Create a new shortcut:

**Name**

```text
Handy Transcription
```

**Command**

```text
/usr/bin/handy --toggle-transcription
```

Assign whatever keyboard shortcut you want to use for dictation.

For example:

```text
Ctrl + Space
```

## 6. Test It

Open Text Editor or any application containing a text field and place the cursor where you want the transcription.

Press your new Handy keyboard shortcut.

Speak normally.

Press the shortcut again.

After Handy finishes transcribing, the text should automatically be typed into the focused application.

## Finished

The working chain should now be:

```text
Ubuntu Custom Shortcut
        ↓
Handy
        ↓
Speech Transcription
        ↓
External Script
        ↓
ydotool
        ↓
/dev/uinput
        ↓
Focused Application
```

You should now be able to use the custom shortcut to dictate into browsers, text editors, terminals, chat applications, and most other applications under GNOME Wayland.
