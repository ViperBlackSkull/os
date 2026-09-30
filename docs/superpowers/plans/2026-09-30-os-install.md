# os — minimal Arch reset script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One self-contained `install.sh` (+ README) in public repo `ViperBlackSkull/os` that turns a booted Arch live environment into a minimal, opencode-equipped `os` — and lays a self-perpetuating `sudo os-reset` boot entry so every future reset needs no USB.

**Architecture:** Single installer script runs as root inside the RAM-resident Arch live env (ISO USB the first time, the ESP-hosted live tree afterwards). It wipes the disk, pacstraps 9 packages, configures user/network/bootloader, pre-installs opencode, and copies the live env's `arch/` tree onto a 4G ESP with its own systemd-boot entry (`copytoram`). Validation: `bash -n` + `shellcheck` + a line-by-line review checklist; the first real run is the acceptance test, with the bootable USB as the recovery path.

**Tech Stack:** bash, pacstrap/genfstab/sgdisk (all on the stock ISO), systemd-boot, gh CLI (publish).

## Global Constraints

- Repo is PUBLIC (`ViperBlackSkull/os`) — **no secrets ever** (no WiFi passwords, no tokens; WiFi joins via `iwctl` before the script, iwd profiles transit RAM→disk only)
- Package list, exact: `base linux linux-firmware intel-ucode iwd sudo git neovim zsh curl`
- Partitioning, exact: 4G vfat ESP labeled `OSBOOT` at `/boot` + rest ext4 label `os`
- Hostname `os`; user `viper` (wheel, zsh); root locked; loader `timeout 1`, default `os.conf`
- archiso boot entry MUST carry `copytoram` (live env must be RAM-resident so the wipe is legal)
- `install.sh` defaults to interactive; unattended only via `--yes` + env: `OS_DISK`, `OS_YES`, `OS_TZ`, `OS_USER_PASS`, `OS_REPO_URL`, `OS_INSTALL_SRC`
- `shellcheck` clean, `bash -n` clean before every commit of `install.sh`
- **NEVER run `install.sh` on the host XPS as a test** — the first real run happens from the bootable USB, by the user (preflight also refuses to run outside a live env)
- Every commit message ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>`

## File Structure

```
os/
├── install.sh              # THE installer — everything inline, ~230 lines
├── README.md               # the reset ritual + notes
└── docs/superpowers/
    ├── specs/2026-09-30-os-minimal-arch-reset-design.md   # exists
    └── plans/2026-09-30-os-install.md                     # this file
```

## Environment Contract

| Var | Meaning | Default |
|---|---|---|
| `OS_DISK` | target disk basename (`vda`, `nvme0n1`) | prompted, auto-default (nvme0n1 → vda → sda) |
| `OS_YES=1` / `--yes` | skip the YES wipe gate | interactive gate |
| `OS_TZ` | timezone | `America/Vancouver` (prompted) |
| `OS_USER_PASS` | viper's password (fed to `chpasswd` stdin) | prompted via `passwd` |
| `OS_REPO_URL` | git remote for `~/os` | `https://github.com/ViperBlackSkull/os.git` |
| `OS_INSTALL_SRC` | where to fetch install.sh for the ESP copy (used when piped from `curl \| bash`, where `$0` is not a file) | raw.githubusercontent URL |

---

### Task 1: `install.sh` — the complete installer

**Files:**
- Create: `install.sh`

**Interfaces:**
- Produces: everything — this is the whole product. Later tasks only document/publish it.

- [ ] **Step 1: Write `install.sh` (complete file)**

```bash
#!/bin/bash
# os — minimal Arch installer / resetter.
#
# Run as root inside an Arch live environment (RAM-resident):
#   curl -fsSL https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | bash
#   bash install.sh                              # interactive
#   OS_DISK=vda OS_YES=1 bash install.sh --yes   # unattended
#
# Wipes the target disk and installs: kernel, WiFi, git, neovim, zsh, opencode.
# A boot entry + ESP copy of the live tree make `sudo os-reset` work forever after.
set -Eeuo pipefail

### config ###
readonly OS_NAME="os"
readonly OS_USER="viper"
readonly ESP_LABEL="OSBOOT"
readonly ESP_SIZE="4G"
readonly OS_TZ_DEFAULT="America/Vancouver"
readonly OS_REPO_URL_DEFAULT="https://github.com/ViperBlackSkull/os.git"
readonly OS_INSTALL_SRC_DEFAULT="https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh"
readonly OPENCODE_INSTALL="https://opencode.ai/install"
readonly -a OS_PACKAGES=(base linux linux-firmware intel-ucode iwd sudo git neovim zsh curl)
readonly OS_BOOT_TIMEOUT=1

### env overrides (unattended mode) ###
OS_REPO_URL="${OS_REPO_URL:-$OS_REPO_URL_DEFAULT}"
OS_INSTALL_SRC="${OS_INSTALL_SRC:-$OS_INSTALL_SRC_DEFAULT}"
OS_TZ="${OS_TZ:-$OS_TZ_DEFAULT}"
OS_USER_PASS="${OS_USER_PASS:-}"
ASSUME_YES="${OS_YES:-0}"
[[ ${1:-} == "--yes" ]] && ASSUME_YES=1

die() { printf 'os: error: %s\n' "$*" >&2; exit 1; }
log() { printf '\nos: \033[1m%s\033[0m\n' "$*"; }

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root, inside the Arch live environment"
  [[ -d /run/archiso ]] || die "this only runs inside an Arch live environment (boot the ISO / os-reset first)"
  [[ -d /run/archiso/bootmnt/arch ]] || die "live medium has no arch/ tree at /run/archiso/bootmnt"
  curl -fsS --max-time 15 -o /dev/null https://geo.mirror.pkgbuild.com/ \
    || die "no network — connect first, e.g.: iwctl station wlan0 connect 'EscapeTwogether'"
}

default_disk() {
  local d
  for d in nvme0n1 vda sda; do
    [[ -b /dev/$d ]] && { printf '%s\n' "$d"; return; }
  done
  lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1; exit}' | xargs -r basename
}

select_disk() {
  local def ok
  def="$(default_disk)"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
  DISK="${OS_DISK:-}"
  if [[ -z $DISK ]]; then
    read -rp "target disk [$def]: " DISK
    DISK="${DISK:-$def}"
  fi
  [[ -b /dev/$DISK ]] || die "/dev/$DISK is not a block device"
  if [[ $ASSUME_YES != 1 ]]; then
    printf 'THIS WIPES /dev/%s — ALL PARTITIONS, ALL DATA.\n' "$DISK"
    read -rp "type YES to continue: " ok
    [[ $ok == "YES" ]] || die "aborted"
  fi
}

wipe_and_partition() {
  log "wiping and partitioning /dev/$DISK"
  sgdisk --zap-all "/dev/$DISK"
  sgdisk -n "1:0:+$ESP_SIZE" -t 1:ef00 -c 1:"$ESP_LABEL" "/dev/$DISK"
  sgdisk -n "2:0:0" -t 2:8300 "/dev/$DISK"
  partprobe "/dev/$DISK" || true
  udevadm settle || true
  sleep 1  # nvme partitions can appear a beat late
  mkfs.vfat -F32 -n "$ESP_LABEL" "/dev/$DISK"1
  mkfs.ext4 -F -L "$OS_NAME" "/dev/$DISK"2
  mount "/dev/$DISK"2 /mnt
  mount --mkdir "/dev/$DISK"1 /mnt/boot
}

pacstrap_base() {
  log "pacstrap: ${OS_PACKAGES[*]}"
  pacstrap /mnt "${OS_PACKAGES[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system() {
  log "configuring base system"
  echo "$OS_NAME" > /mnt/etc/hostname
  printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$OS_NAME" > /mnt/etc/hosts
  ln -sf "/usr/share/zoneinfo/$OS_TZ" /mnt/etc/localtime
  sed -i 's/^#en_US\.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
  echo 'LANG=en_US.UTF-8' > /mnt/etc/locale.conf
  arch-chroot /mnt locale-gen

  arch-chroot /mnt useradd -m -G wheel -s /usr/bin/zsh "$OS_USER"
  if [[ -n $OS_USER_PASS ]]; then
    printf '%s:%s\n' "$OS_USER" "$OS_USER_PASS" | arch-chroot /mnt chpasswd
  else
    until arch-chroot /mnt passwd "$OS_USER"; do :; done
  fi
  arch-chroot /mnt passwd -l root
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
  chmod 440 /mnt/etc/sudoers.d/10-wheel

  mkdir -p /mnt/etc/systemd/network
  printf '[Match]\nName=wlan*\n\n[Network]\nDHCP=yes\n' > /mnt/etc/systemd/network/20-wlan.network
  printf '[Match]\nName=en* Name=eth*\n\n[Network]\nDHCP=yes\n' > /mnt/etc/systemd/network/21-wired.network
  if ls -A /var/lib/iwd 2>/dev/null | grep -q .; then
    log "carrying iwd WiFi profiles over (RAM -> disk, never the repo)"
    mkdir -p /mnt/var/lib/iwd
    cp -a /var/lib/iwd/. /mnt/var/lib/iwd/
    chmod 700 /mnt/var/lib/iwd
    chmod 600 /mnt/var/lib/iwd/* 2>/dev/null || true
  else
    echo "os: warning: no iwd profiles found — after boot: iwctl station wlan0 connect '<ssid>'" >&2
  fi
  arch-chroot /mnt systemctl enable iwd systemd-networkd systemd-resolved
  ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
}

install_bootloader() {
  log "installing systemd-boot"
  arch-chroot /mnt bootctl install \
    || echo "os: warning: NVRAM registration failed — fallback boot path written" >&2
  mkdir -p /mnt/boot/EFI/BOOT
  cp /mnt/boot/EFI/systemd/systemd-bootx64.efi /mnt/boot/EFI/BOOT/BOOTX64.EFI

  ESP_UUID=$(blkid -s UUID -o value "/dev/$DISK"1)
  ROOT_UUID=$(blkid -s UUID -o value "/dev/$DISK"2)

  printf 'timeout %s\ndefault os.conf\n' "$OS_BOOT_TIMEOUT" > /mnt/boot/loader/loader.conf
  cat > /mnt/boot/loader/entries/os.conf <<EOF
title   $OS_NAME
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF
}

lay_reset_layer() {
  log "laying the standalone reset layer onto the ESP"
  cp -a /run/archiso/bootmnt/arch /mnt/boot/arch
  cp /run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux /mnt/boot/vmlinuz-archiso
  cp /run/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img /mnt/boot/initramfs-archiso.img

  if [[ -f $0 && $(basename "$0") == install.sh ]]; then
    cp "$0" /mnt/boot/install.sh
  else
    curl -fsSL "$OS_INSTALL_SRC" -o /mnt/boot/install.sh
  fi
  chmod 755 /mnt/boot/install.sh

  cat > /mnt/boot/loader/entries/archiso.conf <<EOF
title   $OS_NAME reinstall (Arch live, RAM-resident)
linux   /vmlinuz-archiso
initrd  /initramfs-archiso.img
options archisodevice=UUID=$ESP_UUID archisobasedir=arch copytoram
EOF

  cat > /mnt/usr/local/bin/os-reset <<'EOF'
#!/bin/sh
# os: reboot into the reinstall environment (RAM-resident Arch live)
set -e
bootctl --esp-path=/boot set-default archiso.conf
echo "os: rebooting into the reinstall environment in 3s (Ctrl-C to cancel)"
sleep 3
systemctl reboot
EOF
  chmod 755 /mnt/usr/local/bin/os-reset
}

install_userland() {
  log "pre-installing opencode + cloning the os repo for $OS_USER"
  arch-chroot /mnt su -l "$OS_USER" -c "curl -fsSL $OPENCODE_INSTALL | sh" \
    || echo "os: warning: opencode pre-install failed — after boot: curl -fsSL $OPENCODE_INSTALL | sh" >&2
  arch-chroot /mnt su -l "$OS_USER" -c "git clone $OS_REPO_URL \$HOME/os" \
    || echo "os: warning: repo clone failed — after boot: git clone $OS_REPO_URL ~/os" >&2

  cat > "/mnt/home/$OS_USER/.zshrc" <<'EOF'
# os — minimal zsh
export PATH="$HOME/.opencode/bin:$PATH"
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_dups
autoload -Uz promptinit && promptinit
PROMPT='%F{cyan}%m%f %F{green}%~%f %# '
EOF
  chown "$OS_USER:" "/mnt/home/$OS_USER/.zshrc"

  cat > /mnt/etc/motd <<EOF

  $OS_NAME is alive.
  Next: opencode auth login   (then build the rest)
  Reset this machine anytime: sudo os-reset

EOF
}

finish() {
  log "done — unmounting"
  umount -R /mnt
  echo "os: remove the USB (first install only) and press Enter to reboot"
  read -r
  reboot
}

main() {
  preflight
  select_disk
  wipe_and_partition
  pacstrap_base
  configure_system
  install_bootloader
  lay_reset_layer
  install_userland
  finish
}

main "$@"
```

- [ ] **Step 2: Lint**

Run: `bash -n install.sh && shellcheck install.sh` (install shellcheck first if missing: `sudo pacman -S --needed shellcheck`)
Expected: no output (clean).

- [ ] **Step 3: Negative test on the host (safety proof — nothing destructive runs)**

Run: `bash install.sh` → expect `os: error: run as root, inside the Arch live environment`, exit 1.
Run: `sudo bash install.sh` → expect `os: error: this only runs inside an Arch live environment`, exit 1.
Run: `OS_YES=1 bash install.sh --yes` → same error as the first (proves `--yes` parsing).

- [ ] **Step 4: Line-by-line review checklist (this replaces the VM gate)**

Re-read the script and confirm each item, fixing inline if any fails:
1. Every heredoc that must NOT expand variables uses quoted delimiter (`<<'EOF'`): os-reset, .zshrc. Unquoted heredocs (os.conf, archiso.conf, motd) intentionally expand — verify each expansion var is defined at that point (`$ROOT_UUID`, `$ESP_UUID`, `$OS_NAME`).
2. `$ESP_UUID` is set in `install_bootloader` BEFORE `lay_reset_layer` uses it (call order in `main`).
3. `printf '%%wheel...'` — `%` escaped for printf format.
4. `cp -a /var/lib/iwd/.` — trailing `/.` copies directory contents.
5. `su -l` runs login shells; opencode/git failures are warnings (`|| echo`), not aborts — user can recover post-boot.
6. No secret (WiFi password, token) appears anywhere in the script or its output.
7. `set -Eeuo pipefail` + every intentionally-fallible command (`partprobe`, `bootctl install`, userland) has an explicit `|| ` handler so one warning can't abort the whole install.
8. Paths referenced exist on the stock ISO: `sgdisk`, `partprobe`, `mkfs.vfat`, `pacstrap`, `genfstab`, `arch-chroot`, `blkid`, `bootctl` (via pacstrap'd system — verify `arch-chroot /mnt bootctl` works: util/systemd in `base` provides bootctl ✓).

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: install.sh — minimal Arch installer with self-perpetuating os-reset

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: README + spec touch-up + publish

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-09-30-os-minimal-arch-reset-design.md` (validation + decisions rows)

**Interfaces:**
- Consumes: finished `install.sh`.
- Produces: public repo `ViperBlackSkull/os`, branch `main`, raw install.sh URL returning 200.

- [ ] **Step 1: Write `README.md`**

```markdown
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
```

- [ ] **Step 2: Spec consistency edits**

In the spec's Decisions table add:

```markdown
| Unattended mode | `--yes` + `OS_DISK`/`OS_TZ`/`OS_USER_PASS`/`OS_REPO_URL`/`OS_INSTALL_SRC` env overrides | Scripted resets; interactive by default |
| Validation | shellcheck + line-review checklist; first real run from USB is the acceptance test (user opted out of a QEMU harness) | USB ISO is the recovery path for a failed run |
```

Replace the spec's "Validation" section body (QEMU gate) with the same two lines in prose, and add to Non-goals: "No QEMU/test harness — kept out of scope by user decision".

- [ ] **Step 3: Final lint**

Run: `bash -n install.sh && shellcheck install.sh`
Expected: clean.

- [ ] **Step 4: Publish**

```bash
git add README.md docs/ && git commit -m "docs: README ritual + spec validation decision

Co-Authored-By: Claude Code <noreply@anthropic.com>"
git branch -M main
gh auth status || echo "gh not authenticated — user runs: gh auth login"
gh repo create ViperBlackSkull/os --public --source . --push
curl -fsSI https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | head -1
```
Expected: repo URL printed; raw URL answers `HTTP/2 200`.

- [ ] **Step 5: Hand the ritual to the user**

State plainly: the first real run is the acceptance test; recovery from any failure is "boot the USB again". The F12 ritual is theirs to run when ready — nothing auto-runs on real hardware.

---

## Self-Review (applied while writing)

- **Spec coverage:** ritual, full nuke, 9 packages, iwd+networkd+resolved with RAM→disk profile hand-off, systemd-boot timeout 1 / default os.conf, 4G `OSBOOT` ESP, archiso entry with `copytoram`, offline ESP installer copy, `os-reset`, opencode + repo pre-install, motd, public no-secrets repo — all in Task 1's script; README + publish in Task 2. Validation sections of spec updated to match the no-QEMU decision.
- **Placeholders:** none — complete script and README inline.
- **Consistency:** env var names match the Environment Contract; `$ESP_UUID`/`$ROOT_UUID` defined before use per `main()` call order; README's reset path (`/run/archiso/bootmnt/install.sh`) matches `lay_reset_layer`'s ESP copy location.
