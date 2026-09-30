# `os` — minimal Arch reset

**Date:** 2026-09-30 · **Status:** design approved in conversation, pending spec review

## What this is

A public GitHub repo (`ViperBlackSkull/os`) that *is* the OS, Omarchy-style.
The reset ritual replays it onto bare metal from the vanilla Arch ISO:

> 1. F12 → boot the existing `ARCH_202608` USB
> 2. `iwctl` → connect `EscapeTwogether`
> 3. `curl -fsSL https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | bash`
> 4. Reboot → TTY login as `viper` → `opencode auth login` → build the rest

v1 installs almost nothing on purpose: kernel, WiFi, an editor, git, zsh, a
user, and opencode on first boot. The OS grows by editing this repo; every
reset is a fresh replay. No display server, no WM, TTY only — the desktop
becomes whatever `opencode` helps build later.

## Decisions (recorded)

| Decision | Choice | Why |
|---|---|---|
| Reset medium | Vanilla Arch ISO, unmodified | Zero build pipeline; ISO already ships git/curl/pacstrap |
| Installer hosting | Public repo, `curl \| bash` | No credentials needed to fetch; nothing sensitive in repo |
| Data | **Full nuke** — all partitions incl. `/home` | User confirmed; backups live in git (idlevorn-backup et al.) |
| Secrets | Never in repo | WiFi joined via `iwctl` before the script runs; opencode auth is a manual `opencode auth login` after first boot |
| Filesystem | ext4, 1G ESP at `/boot` + rest `/` | Matches current XPS topology and systemd-boot |
| Name | `os` | User: minimalist, doesn't care |

## Repo layout

```
os/
├── install.sh        # the one command (run as root from the ISO)
├── firstboot.sh      # systemd oneshot, runs once on first boot
├── packages.txt      # the curated OS — the file the user grows over time
├── rootfs/           # copied verbatim onto the new root (iwd config, motd…)
├── home/             # copied verbatim into /home/viper (zshrc…)
└── README.md         # the reset ritual
```

## install.sh — flow

Run as root from the ISO's live environment:

1. **Preflight** — must be root, must be on archiso (`[ -d /run/archiso ]`),
   network reachable (else print the `iwctl` one-liner and exit 1).
   Nothing destructive happens before the network check passes.
2. **Safety gate** — print `lsblk`; prompt for target disk (default
   `nvme0n1`); require typing `YES` to proceed.
3. **Wipe** — `sgdisk --zap-all` on the target.
4. **Partition** — 1G EFI vfat labeled ESP, rest ext4; mount ESP at `/boot`,
   root at `/mnt`.
5. **pacstrap** — `packages.txt`. v1 contents, in full:
   `base linux linux-firmware intel-ucode iwd sudo git neovim zsh`
6. **Configure** — hostname `os`; locale `en_US.UTF-8`; timezone prompted
   with default `America/Vancouver`; root account locked (`passwd -l`);
   user `viper` (wheel group, zsh login shell) with password set
   interactively during install.
7. **Services + WiFi hand-off** — enable `iwd`, `systemd-networkd`,
   `systemd-resolved`; copy the live env's `/var/lib/iwd/` profiles into the
   new root so the fresh system auto-joins the same network (the user already
   authenticated in the ISO's RAM via `iwctl`; the password transits
   RAM→disk, never the repo). A `wlan.network` DHCP config and a sudoers
   `wheel` drop-in ship via `rootfs/`. If no iwd profile exists at install
   time, the script warns and `firstboot.sh` degrades to manual re-run after
   a post-boot `iwctl` connect.
8. **Bootloader** — `bootctl install`; loader entry for
   `vmlinuz-linux` + `intel-ucode` initrd + root by UUID; menu timeout 0
   (single OS, same as today).
9. **Firstboot hookup** — copy `firstboot.sh` into the new root, install a
   systemd oneshot unit, enable it.
10. **Finish** — unmount, tell the user to pull the USB, `reboot` on Enter.

## firstboot.sh — runs once as root, then disables itself

- Install opencode to `/home/viper/.opencode/bin` via its official install
  script, run as `viper`, ownership correct.
- Clone `ViperBlackSkull/os` to `/home/viper/os`.
- Write `/etc/motd`: *"os is alive. `opencode auth login`, then build the
  rest."*
- `systemctl disable` itself; a manual re-run path
  (`/usr/local/bin/firstboot.sh`) is noted in the motd if anything failed.

## Error handling

- No network → abort before any destructive step; the ISO env is ephemeral,
  so a failed run costs nothing — retry.
- Wrong disk → mitigated by the lsblk + YES gate; script never defaults
  silently, `YES` is the only acceptance.
- pacstrap/bootloader failure → abort; live env unaffected.
- firstboot failure → non-fatal; re-runnable manually.

## Validation

- **QEMU gate:** boot the same `ARCH_202608` ISO against a qcow2 disk, run
  `install.sh`, assert: VM reboots into `os`, firstboot completes, opencode
  binary exists under `/home/viper/.opencode/bin`, `viper` can log in.
  Only after the VM passes does the script touch the XPS.
- **Acceptance:** the real reset on the XPS is the acceptance test.

## Non-goals (v1)

- No custom ISO (archiso) — may graduate to it later for auto-run installs
- No offline package preseeding — WiFi is required for pacstrap
- No display server / WM / desktop — TTY only
- No dotfile framework, no oh-my-zsh — plain zshrc; the OS grows in public
