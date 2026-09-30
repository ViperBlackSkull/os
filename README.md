# os

A minimal Arch Linux that fits in one repo. Kernel, WiFi, git, neovim, zsh,
opencode — nothing else. Everything after that is built through opencode,
on the machine, by its owner. Resets are free forever.

## First install (once, from a USB stick with the Arch ISO)

1. Boot the Arch ISO (F12 → USB)
2. Connect: `iwctl station wlan0 connect 'YourSSID'`
3. Install:
   ```
   curl -fsSL https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | bash
   ```
4. Remove the USB when told, reboot, log in, run `opencode auth login`.

## Reset (no USB, any time)

```
sudo os-reset
```

Reboots into a RAM-resident Arch live environment hosted on this machine's
own ESP. Connect WiFi, then run the installer — in the live env the ESP is
mounted at `/run/archiso/bootmnt`, so the offline copy is:

```
iwctl station wlan0 connect 'YourSSID'
bash /run/archiso/bootmnt/install.sh
```

It wipes the disk and reinstalls `os` from scratch. The reset entry re-lays
itself on every install.

## Grow the OS

Edit `OS_PACKAGES` in `install.sh` (or the dotfiles it writes), push, and
`sudo os-reset` to replay. The repo is the OS.

## Notes

- No secrets live here. WiFi joins happen per-machine via `iwctl` and are
  carried RAM→disk by the installer, never committed.
- If `opencode` didn't pre-install (offline first boot), run:
  `curl -fsSL https://opencode.ai/install | sh`
