# os — minimal Arch reset system Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One self-contained `install.sh` (+ README) in public repo `ViperBlackSkull/os` that turns a booted Arch live environment into a minimal, opencode-equipped `os` — and lays a self-perpetuating `sudo os-reset` boot entry so every future reset needs no USB.

**Architecture:** Single installer script runs as root inside the RAM-resident Arch live env (ISO USB the first time, the ESP-hosted live tree afterwards). It wipes the disk, pacstraps 9 packages, configures user/network/bootloader, pre-installs opencode, and copies the live env's `arch/` tree onto a 4G ESP with its own systemd-boot entry (`copytoram`). Validation is a scripted QEMU cycle (install → boot → os-reset → offline reinstall → boot) driven through a serial pty.

**Tech Stack:** bash (installer), QEMU + OVMF + libvirt-free pty serial harness (validation), systemd-boot, pacstrap, gh CLI (publish).

## Global Constraints

- Repo is PUBLIC (`ViperBlackSkull/os`) — **no secrets ever** (no WiFi passwords, no tokens; WiFi joins via `iwctl` before the script, iwd profiles transit RAM→disk only)
- Package list, exact: `base linux linux-firmware intel-ucode iwd sudo git neovim zsh curl`
- Partitioning, exact: 4G vfat ESP labeled `OSBOOT` at `/boot` + rest ext4 label `os`
- Hostname `os`; user `viper` (wheel, zsh); root locked; loader `timeout 1`, default `os.conf`
- archiso boot entry MUST carry `copytoram` (live env must be RAM-resident so the wipe is legal)
- `install.sh` defaults to interactive; unattended mode only via `--yes` + env: `OS_DISK`, `OS_TZ`, `OS_USER_PASS`, `OS_REPO_URL`, `OS_INSTALL_SRC`, `OS_SERIAL`, `OS_REBOOT` (`reboot`|`poweroff`|`none`), `OS_YES`
- `shellcheck` clean, `bash -n` clean on every commit of `install.sh`
- **NEVER run `install.sh` on the host XPS** until the full QEMU cycle is green (preflight enforces this: it refuses to run outside an Arch live env)
- Every commit message ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>`

## File Structure

```
os/
├── install.sh              # THE installer — everything inline, ~260 lines
├── README.md               # the reset ritual (5 lines) + troubleshooting
├── docs/superpowers/
│   ├── specs/2026-09-30-os-minimal-arch-reset-design.md   # exists
│   └── plans/2026-09-30-os-install.md                     # this file
└── tests/
    ├── lib/vm.sh           # QEMU control: start (iso|disk), send, wait_for, stop
    └── full-cycle.sh       # phases: iso → install → disk → reset (C+D)
```

`tests/` ships in the public repo on purpose — anyone (including future-you post-reset) can re-validate the installer on any machine with QEMU.

## Environment Contract (used across tasks)

`install.sh` reads (all optional; unset = interactive/default):

| Var | Meaning | Default |
|---|---|---|
| `OS_DISK` | target disk basename (`vda`, `nvme0n1`) | prompted, auto-default |
| `OS_YES=1` / `--yes` | skip the YES wipe gate | interactive gate |
| `OS_TZ` | timezone | `America/Vancouver` (prompted) |
| `OS_USER_PASS` | viper's password (chpasswd stdin) | prompted via `passwd` |
| `OS_REPO_URL` | git remote for `~/os` | `https://github.com/ViperBlackSkull/os.git` |
| `OS_INSTALL_SRC` | where to fetch install.sh from for the ESP copy | raw.githubusercontent URL |
| `OS_SERIAL=1` | append `console=ttyS0,115200n8` to both loader entries + enable `serial-getty@ttyS0` (test only) | off |
| `OS_REBOOT` | final action: `reboot` \| `poweroff` \| `none` | `reboot` |

`tests/lib/vm.sh` exports: `vm_deps`, `vm_ovmf`, `vm_start_iso`, `vm_start_disk`, `vm_send`, `vm_wait`, `vm_stop`, `vm_serve_http`. `tests/full-cycle.sh` subcommands: `iso|install|disk|reset|all`.

Constants shared: VM dir `/var/tmp/os-vm`, disk `40G` qcow2, VM RAM `4096M`, test password `os-test-1`.

---

### Task 1: `install.sh` — config, preflight, disk gate

**Files:**
- Create: `install.sh`

**Interfaces:**
- Produces: `die()`, `log()` helpers; config block (readonly vars); env-override block; preflight that dies outside a live env. Later tasks append functions below `preflight()` — top of file is owned by this task.

- [ ] **Step 1: Write `install.sh` header + preflight**

```bash
#!/bin/bash
# os — minimal Arch installer / resetter.
#
# Run as root inside an Arch live environment (RAM-resident):
#   curl -fsSL https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | bash
#   bash install.sh                          # interactive
#   OS_DISK=vda OS_YES=1 bash install.sh --yes   # unattended (tests, scripted resets)
#
# It wipes the target disk and installs: kernel, WiFi, git, neovim, zsh, opencode.
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
OS_SERIAL="${OS_SERIAL:-0}"
OS_REBOOT="${OS_REBOOT:-reboot}"
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
  local def
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

main() {
  preflight
  select_disk
  log "target confirmed: /dev/$DISK"
  die "install.sh: not implemented past disk selection yet (Task 3)"
}

main "$@"
```

- [ ] **Step 2: Syntax + lint check**

Run: `bash -n install.sh && shellcheck install.sh`
Expected: no output (clean). If shellcheck is missing: `sudo pacman -S --needed shellcheck`.

- [ ] **Step 3: Negative test on the host (safety proof)**

Run: `bash install.sh` (as current non-root user, on the live XPS system)
Expected: `os: error: run as root, inside the Arch live environment` and exit code 1. This proves preflight protects the host.
Run: `sudo bash install.sh`
Expected: `os: error: this only runs inside an Arch live environment` and exit 1. **Do not proceed past this — never test further on the host.**

- [ ] **Step 4: Unattended arg test**

Run: `OS_YES=1 bash install.sh --yes 2>&1 | tail -1`
Expected: `os: error: this only runs inside an Arch live environment` (arg parse must not error on `--yes`).

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat(install): preflight + disk gate with unattended mode

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: QEMU harness — `vm.sh` + `full-cycle.sh` with `iso` phase

**Files:**
- Create: `tests/lib/vm.sh`
- Create: `tests/full-cycle.sh`

**Interfaces:**
- Consumes: nothing yet (standalone).
- Produces: `vm_start_iso` (boots VM from ISO via `-kernel` direct boot + serial pty), `vm_start_disk` (boots qcow2 only), `vm_send LINE`, `vm_wait PATTERN [TIMEOUT_S]` (greps the serial log; dies on timeout), `vm_stop`, `vm_serve_http` (serves the repo over slirp at `http://10.0.2.2:8000/`, dumb-git enabled), `vm_download_iso`. Env: `VM_DIR=/var/tmp/os-vm`, `VM_PASS=os-test-1`. Serial pty path is parsed from qemu's stderr; the log is tailed into `$VM_DIR/serial.log`.

- [ ] **Step 1: Install VM dependencies**

Run: `sudo pacman -S --needed qemu-desktop edk2-ovmf shellcheck`
Expected: `qemu-system-x86_64 --version` prints a version; `ls /usr/share/edk2/x64/` shows `OVMF_CODE*.fd`.

- [ ] **Step 2: Write `tests/lib/vm.sh`**

```bash
#!/bin/bash
# tests/lib/vm.sh — QEMU control for the os validation cycle.
# Drives the guest entirely through a serial pty; output lands in $VM_DIR/serial.log.
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/tmp/os-vm}"
VM_DISK="$VM_DIR/disk.qcow2"
VM_ISO="${VM_ISO:-$VM_DIR/arch.iso}"
VM_LOG="$VM_DIR/serial.log"
VM_ERR="$VM_DIR/qemu.err"
VM_PID="$VM_DIR/qemu.pid"
VM_PTY=""
VM_PASS="${VM_PASS:-os-test-1}"
VM_RAM="${VM_RAM:-4096}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { printf 'vm: error: %s\n' "$*" >&2; exit 1; }

vm_deps() {
  command -v qemu-system-x86_64 >/dev/null || die "missing qemu-desktop"
  command -v qemu-img >/dev/null || die "missing qemu-desktop (qemu-img)"
  [[ -d /usr/share/edk2/x64 ]] || die "missing edk2-ovmf"
  command -v bsdtar >/dev/null || die "missing libarchive (bsdtar)"
  command -v shellcheck >/dev/null || die "missing shellcheck"
}

vm_ovmf() { ls /usr/share/edk2/x64/OVMF_CODE*.fd 2>/dev/null | head -1; }

vm_kvm() { [[ -w /dev/kvm ]] && printf -- '-enable-kvm -cpu host'; }

vm_download_iso() {
  mkdir -p "$VM_DIR"
  if [[ ! -s $VM_ISO ]]; then
    echo "vm: downloading latest Arch ISO to $VM_ISO (~1.4G, once)"
    curl -fL --retry 3 -o "$VM_ISO" \
      https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64-latest.iso
  fi
  [[ -s $VM_ISO ]] || die "no ISO at $VM_ISO"
}

vm_new_disk() {
  rm -f "$VM_DISK"
  qemu-img create -f qcow2 "$VM_DISK" 40G >/dev/null
}

# Serve $REPO_ROOT over slirp so the guest can fetch install.sh and
# git-clone the repo without GitHub (dumb HTTP).
vm_serve_http() {
  git -C "$REPO_ROOT" update-server-info
  if ! curl -fsS -o /dev/null http://127.0.0.1:8000/install.sh; then
    ( cd "$REPO_ROOT" && exec python -m http.server 8000 >/dev/null 2>&1 ) &
    sleep 1
  fi
  curl -fsS -o /dev/null http://127.0.0.1:8000/install.sh || die "http server failed"
}

vm_qemu_common() {
  printf -- '-machine q35 -m %s -smp 2 %s -bios %s -drive file=%s,if=virtio,format=qcow2 -nic user,model=virtio-net-pci -display none -serial pty -monitor none -pidfile %s' \
    "$VM_RAM" "$(vm_kvm)" "$(vm_ovmf)" "$VM_DISK" "$VM_PID"
}

vm_launch() {
  : > "$VM_LOG"
  # shellcheck disable=SC2086
  qemu-system-x86_64 $1 2>"$VM_ERR" &
  local i pty
  for i in $(seq 1 20); do
    pty=$(grep -o '/dev/pts/[0-9]*' "$VM_ERR" 2>/dev/null | head -1 || true)
    [[ -n $pty ]] && break
    sleep 0.5
  done
  [[ -n ${pty:-} ]] || { cat "$VM_ERR"; die "qemu did not expose a serial pty"; }
  VM_PTY="$pty"
  tail -c +1 -f "$VM_PTY" > "$VM_LOG" 2>/dev/null &
  echo $! > "$VM_DIR/reader.pid"
}

vm_start_iso() {
  local label
  label=$(blkid -s LABEL -o value "$VM_ISO")
  [[ -n $label ]] || die "could not read ISO label"
  bsdtar -x -C "$VM_DIR" -f "$VM_ISO" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
  vm_launch "$(vm_qemu_common) \
    -kernel $VM_DIR/arch/boot/x86_64/vmlinuz-linux \
    -initrd $VM_DIR/arch/boot/x86_64/initramfs-linux.img \
    -append 'archisolabel=$label archisobasedir=arch copytoram console=ttyS0,115200n8' \
    -cdrom $VM_ISO"
}

vm_start_disk() {
  vm_launch "$(vm_qemu_common)"
}

vm_send() { printf '%s\n' "$1" > "$VM_PTY"; }

vm_wait() {
  local pat=$1 to=${2:-600} i
  for ((i = 0; i < to; i++)); do
    grep -qE "$pat" "$VM_LOG" && { echo "vm: matched: $pat"; return 0; }
    sleep 1
  done
  echo "vm: timeout waiting for: $pat — last 40 serial lines:" >&2
  tail -40 "$VM_LOG" >&2
  return 1
}

vm_stop() {
  local pid
  pid=$(cat "$VM_PID" 2>/dev/null || true)
  [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  [[ -f $VM_DIR/reader.pid ]] && kill "$(cat "$VM_DIR/reader.pid")" 2>/dev/null || true
  rm -f "$VM_PID"
}

vm_login_root() {  # live env: root has no password
  vm_wait 'login:'
  sleep 2
  vm_send 'root'
  sleep 1
  vm_send ''
  vm_wait 'root@'
}
```

- [ ] **Step 3: Write `tests/full-cycle.sh` with the `iso` phase**

```bash
#!/bin/bash
# tests/full-cycle.sh — the os validation cycle in QEMU.
#   iso     : boot the live ISO, reach a root shell                    (Task 2)
#   install : run install.sh in the live VM, power off                 (Task 3)
#   disk    : boot the installed disk, assert os + opencode + repo     (Tasks 3-4)
#   reset   : os-reset → live env → offline reinstall → boot + assert  (Task 5)
#   all     : everything, fresh disk
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/vm.sh
source lib/vm.sh

phase_iso() {
  vm_deps; vm_download_iso; vm_new_disk
  echo "PASS-CHECK: booting ISO, expect root@ prompt + /dev/vda"
  vm_start_iso
  vm_login_root
  vm_send 'lsblk -dnpo NAME,TYPE | grep disk'
  vm_wait 'vda'
  vm_send 'ping -c1 -W5 10.0.2.2 >/dev/null && echo NET_OK'
  vm_wait 'NET_OK'
  vm_stop
  echo "PASS: phase iso"
}

phase_install() {
  vm_deps; vm_download_iso
  vm_new_disk
  vm_serve_http
  echo "FAIL-FIRST: install.sh stops after disk selection (Task 1 stub)"
  vm_start_iso
  vm_login_root
  vm_send "curl -fsS -o /root/install.sh http://10.0.2.2:8000/install.sh && \
OS_DISK=vda OS_YES=1 OS_USER_PASS='$VM_PASS' OS_SERIAL=1 OS_REBOOT=poweroff \
OS_REPO_URL=http://10.0.2.2:8000/ OS_INSTALL_SRC=http://10.0.2.2:8000/install.sh \
bash /root/install.sh --yes"
  vm_wait 'not implemented past disk selection'
  vm_stop
  echo "EXPECTED-FAIL: phase install (install.sh incomplete) — becomes PASS in Task 3"
}

phase_disk() {
  vm_deps
  echo "FAIL-FIRST: disk is not bootable yet (Task 3 will make it boot)"
  vm_start_disk
  vm_wait 'os login:'
  vm_stop
  echo "EXPECTED-FAIL: phase disk — becomes PASS in Task 3/4"
}

phase_reset() { die "phase_reset implemented in Task 5"; }

case "${1:-all}" in
  iso) phase_iso ;;
  install) phase_install ;;
  disk) phase_disk ;;
  reset) phase_reset ;;
  all) phase_iso; phase_install; phase_disk; phase_reset ;;
  *) die "usage: $0 {iso|install|disk|reset|all}" ;;
esac
```

- [ ] **Step 4: Lint + permissions**

Run: `chmod +x tests/full-cycle.sh tests/lib/vm.sh && shellcheck tests/lib/vm.sh tests/full-cycle.sh && bash -n tests/lib/vm.sh tests/full-cycle.sh`
Expected: clean.

- [ ] **Step 5: Run the iso phase**

Run: `./tests/full-cycle.sh iso`
Expected output ends with:
```
vm: matched: root@
vm: matched: vda
vm: matched: NET_OK
PASS: phase iso
```
(First run downloads the ~1.4G ISO. If `/dev/kvm` is absent, the VM still runs via TCG — slower boot, same assertions.)

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "test: QEMU serial harness + iso phase (boot, disk, network)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: `install.sh` core — wipe, pacstrap, config, bootloader

**Files:**
- Modify: `install.sh` (replace the `main()` stub with the full install flow)

**Interfaces:**
- Consumes: `die`, `log`, config block, env overrides from Task 1; `$DISK` from `select_disk`.
- Produces: a bootable `os` on `/dev/$DISK` — root `os` partition, ESP at `/boot` with `loader/entries/os.conf`, networkd config, user `viper` (password `$OS_USER_PASS`), services enabled. `$ESP_UUID`, `$ROOT_UUID` computed here and reused by Task 5's reset layer.

- [ ] **Step 1: Replace `main()` and add the install functions (full code)**

Replace everything from `main() {` to the end of file with:

```bash
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
    || echo "os: warning: NVRAM registration failed (QEMU?) — fallback path used" >&2
  mkdir -p /mnt/boot/EFI/BOOT
  cp /mnt/boot/EFI/systemd/systemd-bootx64.efi /mnt/boot/EFI/BOOT/BOOTX64.EFI

  ESP_UUID=$(blkid -s UUID -o value "/dev/$DISK"1)
  ROOT_UUID=$(blkid -s UUID -o value "/dev/$DISK"2)
  SERIAL_OPTS=""
  [[ $OS_SERIAL == 1 ]] && SERIAL_OPTS="console=tty0 console=ttyS0,115200n8"

  printf 'timeout %s\ndefault os.conf\n' "$OS_BOOT_TIMEOUT" > /mnt/boot/loader/loader.conf
  cat > /mnt/boot/loader/entries/os.conf <<EOF
title   $OS_NAME
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw $SERIAL_OPTS
EOF
}

finish() {
  log "done — unmounting"
  umount -R /mnt
  case $OS_REBOOT in
    reboot)
      echo "os: remove the USB (first install only) and press Enter to reboot"
      read -r
      reboot ;;
    poweroff) poweroff ;;
    none) echo "os: installed — reboot when ready" ;;
  esac
}

main() {
  preflight
  select_disk
  wipe_and_partition
  pacstrap_base
  configure_system
  install_bootloader
  finish
}

main "$@"
```

Note: Task 4 adds `install_userland` and Task 5 adds `lay_reset_layer` — both called from `main()` between `install_bootloader` and `finish`.

- [ ] **Step 2: Lint**

Run: `bash -n install.sh && shellcheck install.sh`
Expected: clean.

- [ ] **Step 3: Flip the install and disk phases to real assertions**

In `tests/full-cycle.sh`, replace `phase_install()` with:

```bash
phase_install() {
  vm_deps; vm_download_iso
  vm_new_disk
  vm_serve_http
  vm_start_iso
  vm_login_root
  vm_send "curl -fsS -o /root/install.sh http://10.0.2.2:8000/install.sh && \
OS_DISK=vda OS_YES=1 OS_USER_PASS='$VM_PASS' OS_SERIAL=1 OS_REBOOT=poweroff \
OS_REPO_URL=http://10.0.2.2:8000/ OS_INSTALL_SRC=http://10.0.2.2:8000/install.sh \
bash /root/install.sh --yes"
  vm_wait 'done — unmounting'
  vm_wait 'power down|reboot: Power down|ACPI' 180
  vm_stop
  echo "PASS: phase install"
}
```

and `phase_disk()` with (final form — the `os ~ %` prompt comes from Task 4's `.zshrc`; keep them in sync):

```bash
phase_disk() {
  vm_deps
  vm_start_disk
  vm_wait 'os login:'
  sleep 2
  vm_send 'viper'
  vm_wait 'Password:'
  sleep 1
  vm_send "$VM_PASS"
  vm_wait 'os ~ %'
  vm_send 'test -x ~/.opencode/bin/opencode && echo OPENCODE_OK; test -d ~/os/.git && echo REPO_OK; ping -c1 -W5 10.0.2.2 >/dev/null && echo NET_OK'
  vm_wait 'NET_OK'
  vm_stop
  echo "PASS: phase disk"
}
```

(Task 3's run only proves boot + login + network — `OPENCODE_OK`/`REPO_OK` first match in Task 4, so `phase_disk` here greps only `NET_OK`, the last assertion to appear; the sends of the earlier two are harmless no-ops until Task 4.)

- [ ] **Step 4: Run install + disk phases**

Run: `./tests/full-cycle.sh install && ./tests/full-cycle.sh disk`
Expected:
```
vm: matched: done — unmounting
PASS: phase install
vm: matched: os login:
vm: matched: os ~ %
PASS: phase disk (booted os, logged in as viper)
```
(Boots take 1–3 min with KVM. If `os login:` never appears, inspect `/var/tmp/os-vm/serial.log` — the loader entry `console=ttyS0` comes from `OS_SERIAL=1`; verify `/mnt/boot/loader/entries/os.conf` got `$SERIAL_OPTS` during install.)

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/full-cycle.sh
git commit -m "feat(install): wipe, pacstrap, system config, systemd-boot — bootable os

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: `install.sh` userland — opencode, repo, zshrc, motd

**Files:**
- Modify: `install.sh` (add `install_userland()`, call it in `main()`)

**Interfaces:**
- Consumes: `OS_USER`, `OS_REPO_URL`, `OPENCODE_INSTALL`, `die`/`log`.
- Produces: `/home/viper/.opencode/bin/opencode`, `/home/viper/os/.git`, `~/.zshrc` with PATH (prompt `os ~ %` — phase_disk depends on this string), `/etc/motd`.

- [ ] **Step 1: Add `install_userland()` (full code) and wire it in**

Insert before `finish()`:

```bash
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
```

And in `main()`, add between `install_bootloader` and `finish`:

```bash
  install_userland
```

- [ ] **Step 2: Lint**

Run: `bash -n install.sh && shellcheck install.sh`
Expected: clean.

- [ ] **Step 3: Add the phase_disk assertions that Task 4 makes true**

In `tests/full-cycle.sh` `phase_disk()`, the combined send from Task 3 already emits `OPENCODE_OK`/`REPO_OK`/`NET_OK`; add the `MOTD_OK` send plus all four waits, before `vm_stop`:

```bash
  vm_send 'cat /etc/motd | grep -q os-reset && echo MOTD_OK'
  vm_wait 'OPENCODE_OK'
  vm_wait 'REPO_OK'
  vm_wait 'NET_OK'
  vm_wait 'MOTD_OK'
  vm_stop
```

Run: `./tests/full-cycle.sh install && ./tests/full-cycle.sh disk`
Expected: all of `OPENCODE_OK`, `REPO_OK`, `NET_OK`, `MOTD_OK` matched, then `PASS: phase disk...`.
(Needed because Task 3's install ran before opencode existed — rerunning `install` phase re-installs fresh with Task 4 code.)

- [ ] **Step 4: Commit**

```bash
git add install.sh tests/full-cycle.sh
git commit -m "feat(install): pre-install opencode + clone os repo, minimal zshrc + motd

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: `install.sh` reset layer + `os-reset`; full-cycle `reset` phase

**Files:**
- Modify: `install.sh` (add `lay_reset_layer()`, call it in `main()`)
- Modify: `tests/full-cycle.sh` (implement `phase_reset()`)

**Interfaces:**
- Consumes: `ESP_UUID`, `SERIAL_OPTS` from `install_bootloader()`; `/run/archiso/bootmnt` from the live env; `OS_INSTALL_SRC`.
- Produces: `/boot/arch/` live tree, `/boot/vmlinuz-archiso`, `/boot/initramfs-archiso.img`, `loader/entries/archiso.conf` (with `archisodevice=UUID=$ESP_UUID archisobasedir=arch copytoram`), `/boot/install.sh` (offline copy), `/usr/local/bin/os-reset`.

- [ ] **Step 1: Add `lay_reset_layer()` (full code) and wire it in**

Insert after `install_bootloader()`:

```bash
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
options archisodevice=UUID=$ESP_UUID archisobasedir=arch copytoram $SERIAL_OPTS
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
```

In `main()`, add between `install_bootloader` and `install_userland`:

```bash
  lay_reset_layer
```

- [ ] **Step 2: Lint**

Run: `bash -n install.sh && shellcheck install.sh`
Expected: clean.

- [ ] **Step 3: Implement `phase_reset()` in `tests/full-cycle.sh`**

Replace `phase_reset() { die ...; }` with:

```bash
phase_reset() {
  vm_deps; vm_serve_http
  echo "PASS-CHECK: boot os, verify reset entry, os-reset, offline reinstall, boot again"
  vm_start_disk
  vm_wait 'os login:'
  sleep 2
  vm_send 'viper'
  vm_wait 'Password:'
  sleep 1
  vm_send "$VM_PASS"
  vm_wait 'os ~ %'
  vm_send 'bootctl list | grep -q archiso.conf && echo ENTRY_OK; test -x /usr/local/bin/os-reset && echo RESETBIN_OK; test -f /boot/install.sh && echo ESPSCRIPT_OK'
  vm_wait 'ENTRY_OK'
  vm_wait 'RESETBIN_OK'
  vm_wait 'ESPSCRIPT_OK'
  echo "PASS: reset layer present on ESP"

  echo "PASS-CHECK: os-reset reboots into RAM-resident live env from the ESP"
  vm_send "echo '$VM_PASS' | sudo -S os-reset"
  vm_wait 'login:' 300          # archiso serial login (systemd spawns getty on console=)
  sleep 3
  vm_send 'root'
  sleep 2
  vm_send ''
  vm_wait 'root@'
  vm_send 'test -f /run/archiso/bootmnt/install.sh && echo OFFLINE_OK'
  vm_wait 'OFFLINE_OK'
  echo "PASS: live env booted from ESP, offline installer reachable"

  echo "PASS-CHECK: offline reinstall (packages still via network, script from ESP)"
  vm_send "OS_DISK=vda OS_YES=1 OS_USER_PASS='$VM_PASS' OS_SERIAL=1 OS_REBOOT=poweroff \
OS_REPO_URL=http://10.0.2.2:8000/ OS_INSTALL_SRC=http://10.0.2.2:8000/install.sh \
bash /run/archiso/bootmnt/install.sh --yes"
  vm_wait 'done — unmounting' 900
  vm_wait 'power down|ACPI' 180
  vm_stop

  echo "PASS-CHECK: disk boots os again after the offline reinstall"
  vm_start_disk
  vm_wait 'os login:'
  sleep 2
  vm_send 'viper'
  vm_wait 'Password:'
  sleep 1
  vm_send "$VM_PASS"
  vm_wait 'os ~ %'
  vm_send 'test -x ~/.opencode/bin/opencode && echo OPENCODE_OK2'
  vm_wait 'OPENCODE_OK2'
  vm_stop
  echo "PASS: phase reset — full self-perpetuating cycle proven"
}
```

- [ ] **Step 4: Run the complete cycle, fresh disk**

Run: `./tests/full-cycle.sh all`
Expected, in order: `PASS: phase iso` → `PASS: phase install` → disk-phase OKs → `PASS: reset layer present on ESP` → `PASS: live env booted from ESP...` → `PASS: phase reset — full self-perpetuating cycle proven`.
(Watch `/var/tmp/os-vm/serial.log` live in another terminal if anything stalls. The offline reinstall re-downloads ~400M of packages — the 900s wait is deliberate.)

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/full-cycle.sh
git commit -m "feat(install): self-perpetuating reset layer + os-reset; full QEMU cycle green

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: README, spec touch-up, publish

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-09-30-os-minimal-arch-reset-design.md` (one added decision line)

**Interfaces:**
- Consumes: finished `install.sh`, green full-cycle.
- Produces: public repo `ViperBlackSkull/os` on GitHub, branch `main`.

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
own ESP, runs `install.sh` (offline copy on the ESP at `/boot/install.sh`),
wipes the disk, and reinstalls `os` from scratch. The reset entry re-lays
itself on every install.

## Grow the OS

Edit `OS_PACKAGES` in `install.sh` (or the dotfiles it writes), push, and
`sudo os-reset` to replay. The repo is the OS.

## Validate without a machine

`tests/full-cycle.sh all` boots the whole lifecycle in QEMU:
install → boot → os-reset → offline reinstall → boot.

## Notes

- No secrets live here. WiFi joins happen per-machine via `iwctl` and are
  carried RAM→disk by the installer, never committed.
- If `opencode` didn't pre-install (offline first boot), run:
  `curl -fsSL https://opencode.ai/install | sh`
```

- [ ] **Step 2: Spec consistency line**

In `docs/superpowers/specs/2026-09-30-os-minimal-arch-reset-design.md`, add to the Decisions table:

```markdown
| Unattended mode | `--yes` + `OS_*` env overrides (`OS_DISK`, `OS_TZ`, `OS_USER_PASS`, `OS_REPO_URL`, `OS_INSTALL_SRC`, `OS_SERIAL`, `OS_REBOOT`) | Makes the QEMU validation cycle scriptable; doubles as scripted resets; interactive by default |
```

- [ ] **Step 3: Final lint + full-cycle re-run on the exact published tree**

Run: `bash -n install.sh && shellcheck install.sh tests/lib/vm.sh tests/full-cycle.sh && ./tests/full-cycle.sh all`
Expected: all phases PASS (this is the exact code that ships).

- [ ] **Step 4: Publish**

```bash
git add README.md docs/ && git commit -m "docs: README ritual + spec unattended-mode decision

Co-Authored-By: Claude Code <noreply@anthropic.com>"
git branch -M main
gh auth status || die "gh not authenticated — run: gh auth login"
gh repo create ViperBlackSkull/os --public --source . --push
curl -fsSI https://raw.githubusercontent.com/ViperBlackSkull/os/main/install.sh | head -1
```
Expected: repo URL printed, and the raw URL answers `HTTP/2 200`.

- [ ] **Step 5: Hand the ritual to the user**

Tell the user: everything is validated; the real first install on the XPS is theirs to run (F12 → USB → `iwctl` → the curl line from README). Nothing auto-runs on real hardware.

---

## Self-Review (already applied while writing)

- **Spec coverage:** ritual (README + install.sh), full nuke (sgdisk zap), 9-package list, iwd/networkd/resolved + profile hand-off, systemd-boot timeout 1 default os, 4G ESP OSBOOT, archiso entry with copytoram, ESP offline installer copy, `os-reset`, opencode + repo pre-install, motd, QEMU gate incl. self-perpetuation, public repo no secrets, first-install-from-USB → all covered by Tasks 1–6.
- **Placeholders:** `OS_USER_PLACEHOLDER` in Task 3 Step 3 is explicitly replaced within the same step — no TBDs remain.
- **Consistency:** prompt string `os ~ %` (Task 4 `.zshrc` ↔ Task 3/5 `vm_wait`); env var names match the Environment Contract table; `ESP_UUID`/`SERIAL_OPTS` produced in `install_bootloader`, consumed in `lay_reset_layer`; `VM_PASS` defined in vm.sh, used in both phase files.
