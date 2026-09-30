# `os` — minimal Arch reset

**Date:** 2026-09-30 · **Status:** design approved in conversation, pending spec review

## What this is

A public GitHub repo (`ViperBlackSkull/os`) that *is* the OS, Omarchy-style.
**Resets are standalone — no USB needed.** The ESP carries both the OS and
the archiso live tree, so a reset is one command on the running system:

> **Reset:** `sudo os-reset` → reboots into the live env (loaded to RAM
> from the ESP via `copytoram`) → `iwctl` connect → run `install.sh`
> (offline copy on the ESP, or curl from GitHub) → full nuke → reinstall.

**First install ever** (one time) uses the existing `ARCH_202608` USB:

> 1. F12 → boot the USB
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
| Reset medium | **Self-hosted** — archiso tree lives on the ESP alongside the OS; USB only for the very first install | Zero build pipeline; the USB (an extracted archiso on vfat) already proves the layout; `copytoram` + 62G RAM leaves the disk free to wipe; each install re-lays the reset entry (self-perpetuating) |
| Installer hosting | Public repo, `curl \| bash` | No credentials needed to fetch; nothing sensitive in repo |
| Data | **Full nuke** — all partitions incl. `/home` | User confirmed; backups live in git (idlevorn-backup et al.) |
| Secrets | Never in repo | WiFi joined via `iwctl` before the script runs; opencode auth is a manual `opencode auth login` after first boot |
| Filesystem | ext4, **4G** ESP at `/boot` + rest `/` | 4G holds both the OS kernels and the 1.3G archiso live tree; otherwise matches current XPS topology and systemd-boot |
| Name | `os` | User: minimalist, doesn't care |

## Repo layout

One script, one README. Everything else is inline:

```
os/
├── install.sh        # the whole installer — packages, config, bootloader, opencode
└── README.md         # the reset ritual
```

The package list lives as a variable in `install.sh` (that variable *is*
the OS definition and grows over time). No firstboot unit: the live env
already has network, so `install.sh` installs opencode directly into the
new root and clones the repo to `/home/viper/os` before reboot. The only
post-boot manual step is `opencode auth login`.

## install.sh — flow

Run as root from the ISO's live environment:

1. **Preflight** — must be root, must be on archiso (`[ -d /run/archiso ]`),
   network reachable (else print the `iwctl` one-liner and exit 1).
   Nothing destructive happens before the network check passes.
2. **Safety gate** — print `lsblk`; prompt for target disk (default
   `nvme0n1`); require typing `YES` to proceed.
3. **Wipe** — `sgdisk --zap-all` on the target.
4. **Partition** — 4G EFI vfat labeled ESP, rest ext4; mount ESP at `/boot`,
   root at `/mnt`.
5. **pacstrap** — inline package variable. v1 contents, in full:
   `base linux linux-firmware intel-ucode iwd sudo git neovim zsh`
6. **Configure** — hostname `os`; locale `en_US.UTF-8`; timezone prompted
   with default `America/Vancouver`; root account locked (`passwd -l`);
   user `viper` (wheel group, zsh login shell) with password set
   interactively during install; sudoers `wheel` drop-in via heredoc.
7. **Services + WiFi hand-off** — enable `iwd`, `systemd-networkd`,
   `systemd-resolved`; copy the live env's `/var/lib/iwd/` profiles into the
   new root so the fresh system auto-joins the same network (the user already
   authenticated in the ISO's RAM via `iwctl`; the password transits
   RAM→disk, never the repo); a `wlan.network` DHCP config via heredoc.
8. **Bootloader + reset entry** — `bootctl install`; loader entry for
   `vmlinuz-linux` + `intel-ucode` initrd + root by UUID; menu timeout 1
   with `os` as default. Then the standalone-reset layer: copy the live
   env's `arch/` tree (1.3G, from `/run/archiso/bootmnt`) plus the archiso
   kernel/initrd onto the ESP; write `loader/entries/archiso.conf` with
   `options archisodevice=UUID=<ESP> archisobasedir=arch copytoram`; copy
   `install.sh` itself to the ESP root as the offline re-run path.
9. **`os-reset` helper** — 3-line script installed to
   `/usr/local/bin/os-reset` on the new system: `bootctl set-default
   archiso.conf` + `reboot`. Running it mid-reset is safe: the live env is
   RAM-resident, and every (re)install resets the default back to `os`.
10. **Userland pre-install** — as `viper`, inside the new root: install
    opencode via its official script to `/home/viper/.opencode/bin`, clone
    `ViperBlackSkull/os` to `/home/viper/os`. No firstboot unit needed.
11. **Finish** — motd: *"os is alive. `opencode auth login`, then build
    the rest. Reset anytime: `sudo os-reset`."* Unmount, tell the user to
    pull the USB (first install only), `reboot` on Enter.

## Error handling

- No network → abort before any destructive step; the ISO env is ephemeral,
  so a failed run costs nothing — retry.
- Wrong disk → mitigated by the lsblk + YES gate; script never defaults
  silently, `YES` is the only acceptance.
- pacstrap/bootloader failure → abort; live env unaffected.
- opencode/repo pre-install failure → non-fatal warning; both are
  one-command installs post-boot once WiFi is up.

## Validation

- **QEMU gate:** boot the same `ARCH_202608` ISO against a qcow2 disk, run
  `install.sh`, assert: VM reboots into `os`, opencode binary exists under
  `/home/viper/.opencode/bin`, repo cloned at `/home/viper/os`, `viper` can
  log in. **Then prove self-perpetuation:** in the same VM run `os-reset` →
  live env boots from the ESP → `install.sh` re-runs offline from its ESP
  copy. Only after the full VM cycle passes does the script touch the XPS.
  (VM needs WiFi faking — QEMU user-net NAT + a wired-ish `systemd-networkd`
  test or `iwctl`-less DHCP via `enp0s3`; the script's network preflight
  accepts any routable interface, WiFi is just the XPS reality.)
- **Acceptance:** the real reset on the XPS is the acceptance test.

## Non-goals (v1)

- No custom ISO build (archiso/mkarchiso) — the ESP copies the stock live
  tree; nothing is rebuilt, just relocated
- No offline package preseeding — network is required for pacstrap
- No display server / WM / desktop — TTY only
- No dotfile framework, no oh-my-zsh — plain zshrc; the OS grows in public
