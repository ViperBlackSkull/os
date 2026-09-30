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
    || die "no network — connect first, e.g.: iwctl station wlan0 connect '<ssid>'"
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
    curl -fsSL "$OS_INSTALL_SRC" -o /mnt/boot/install.sh \
      || echo "os: warning: could not copy install.sh to ESP — resets will need the curl one-liner" >&2
  fi
  [[ -f /mnt/boot/install.sh ]] && chmod 755 /mnt/boot/install.sh || true

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
