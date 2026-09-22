# Keyboard

Bar widget for the keyboard backlight on a Sager / Clevo P870DM-G.

The keyboard has three lighting zones plus the light bar along the front edge. Click the keyboard icon to set the color, brightness, and firmware effect. Scroll the icon to change brightness. Right-click it to turn the lights off.

## Install

```sh
omarchy plugin add https://github.com/wouldja/omarchy-keyboard.git --enable
```

The lights are not a USB device. The panel talks to a small kernel module, `sager_kbd`, which is included under `driver/` and is not loaded by the plugin itself. Install that module once, after the plugin is on disk:

```sh
pkexec ~/.config/omarchy/plugins/io.github.wouldja.keyboard/driver/install.sh
```

That script needs root. It builds the module with DKMS, loads it, and adds it to `/etc/modules-load.d/sager_kbd.conf` so it comes back after a reboot. It does not edit Hyprland or Omarchy config. DKMS and the headers for the running kernel (`linux-omarchy-headers` on Omarchy) have to be installed first.

The widget lands on the right of the bar. If it does not appear immediately:

```sh
omarchy-shell shell rescanPlugins
```

The last chosen color is stored in `~/.config/sager-keyboard/state.json` and applied again when the shell starts, and after resume.

## Remove

```sh
omarchy plugin remove io.github.wouldja.keyboard
```

That drops the widget and leaves `~/.config/sager-keyboard/` in place. The driver stays installed until:

```sh
sudo dkms remove -m sager-kbd -v 1.1.0 --all
sudo rmmod sager_kbd
sudo rm /etc/modules-load.d/sager_kbd.conf
```

The Fans plugin uses the same module. Remove the module only when both plugins are gone.

## License and dependencies

The shell plugin is MIT. See [LICENSE](LICENSE). The kernel module in `driver/` is GPL-2.0-only, which the kernel requires.

Needs Omarchy (Quickshell) and Python 3. The backlight also needs the `sager_kbd` module built from this repository. No network calls.
