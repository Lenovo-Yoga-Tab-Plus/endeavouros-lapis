#!/bin/bash
# Build an EndeavourOS image for the Lenovo Yoga Tab Plus (codename lapis).
#
# The boot path matches the running tablet:
#   boot_b       Mu-Silicium UEFI
#   pstoredump   FAT16 EFI system partition (4096-byte sectors)
#   lenovocust   ext4 partition labeled "boot" (kernel, DTB, GRUB config)
#   arch         ext4 root filesystem labeled "eos-lapis"
# GRUB loads an uncompressed Image and the board DTB. There is no initramfs.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-image.sh [plasma|gnome]

Environment variables:
  LAPIS_REPO_URL    Pacman repo URL (default: the lapis-pkgs Pages site)
  LAPIS_REPO_NAME   Pacman repo section name (default: lapis-pkgs)
  BUILD_GIT_REV     Git revision stamped into build metadata
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "You must be root to run this script."
    exit 1
fi

DE_NAME="${1:-gnome}"
case "$DE_NAME" in
    plasma|gnome) ;;
    *) usage; exit 1 ;;
esac

DATE=$(date -u +%Y%m%d)
BUILD_DIR=/build
IMAGES_DIR="$BUILD_DIR/images"
WORK_DIR="$BUILD_DIR/work-$DE_NAME"
ROOTFS_DIR="$WORK_DIR/rootfs"
IMAGE_MNT="$WORK_DIR/mnt_image"
ESP_MNT="$WORK_DIR/mnt_esp"
BOOT_MNT="$WORK_DIR/mnt_boot"
PACMAN_CONF="$WORK_DIR/pacman.conf"
IMAGE_NAME="endeavouros-lapis-${DE_NAME}-${DATE}"
OUT="$IMAGES_DIR/$IMAGE_NAME"
ROOTFS_LABEL="eos-lapis"
BOOT_LABEL="boot"
ESP_LABEL="EOSLAPIS"
DTB_NAME="sm8650-lenovo-tb520fu.dtb"
CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused ignore_loglevel"
LAPIS_REPO_NAME="${LAPIS_REPO_NAME:-lapis-pkgs}"
LAPIS_REPO_URL="${LAPIS_REPO_URL:-https://lenovo-yoga-tab-plus.github.io/lapis-pkgs/repo/}"
BUILD_GIT_REV="${BUILD_GIT_REV:-unknown}"
SILICIUM_IMG="$(pwd)/silicium.img"
SILICIUM_SHA256="665927da2bcc072b96968992549e6a16d4f6903d5d1213068f8322bf9c5f57ab"
EFI_TEMPLATE="$(pwd)/efi-template"
ESP_SIZE_MB=128
BOOT_SIZE_MB=256

cleanup() {
    if mountpoint -q "$ROOTFS_DIR/boot" 2>/dev/null; then
        umount "$ROOTFS_DIR/boot" || true
    fi
    if mountpoint -q "$IMAGE_MNT" 2>/dev/null; then
        umount "$IMAGE_MNT" || true
    fi
    if mountpoint -q "$ESP_MNT" 2>/dev/null; then
        umount "$ESP_MNT" || true
    fi
    if mountpoint -q "$BOOT_MNT" 2>/dev/null; then
        umount "$BOOT_MNT" || true
    fi
}
trap cleanup EXIT

if [ ! -f "$SILICIUM_IMG" ]; then
    echo "Missing Mu-Silicium image: $SILICIUM_IMG" >&2
    exit 1
fi
echo "$SILICIUM_SHA256  $SILICIUM_IMG" | sha256sum -c -
if [ ! -f "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" ]; then
    echo "Missing GRUB binary: $EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" >&2
    exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$ROOTFS_DIR" "$IMAGE_MNT" "$ESP_MNT" "$BOOT_MNT" "$OUT"

echo "### Preparing pacman configuration..."
cp /etc/pacman.conf "$PACMAN_CONF"
sed -i '/^DisableSandbox$/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a DisableSandbox' "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[$LAPIS_REPO_NAME]
SigLevel = Optional TrustAll
Server = $LAPIS_REPO_URL

[endeavouros]
SigLevel = Optional TrustAll
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

BASE_PACKAGES=(
    base sudo nano vim git wget rsync openssh
    networkmanager iwd mesa
    linux-firmware linux-firmware-qcom
    archlinuxarm-keyring
    alsa-ucm-conf alsa-utils
    pipewire pipewire-alsa pipewire-pulse wireplumber
    upower
    iptables noto-fonts
    endeavouros-branding endeavouros-keyring endeavouros-mirrorlist
    eos-hooks eos-rankmirrors welcome
)

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            plasma-meta plasma-desktop sddm
            konsole dolphin
        )
        ;;
    gnome)
        DESKTOP_PACKAGES=(
            gnome-shell gnome-session gnome-control-center gnome-console
            nautilus gdm gnome-initial-setup xdg-desktop-portal-gnome
        )
        ;;
esac

echo "### Bootstrapping rootfs with pacstrap..."
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" \
    "${BASE_PACKAGES[@]}" \
    "${LAPIS_REPO_NAME}/lapis-metapkg" \
    "${DESKTOP_PACKAGES[@]}"

cp "$PACMAN_CONF" "$ROOTFS_DIR/etc/pacman.conf"
printf '%s\n' lapis > "$ROOTFS_DIR/etc/hostname"
cat > "$ROOTFS_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
127.0.1.1 lapis.localdomain lapis
EOF
printf '%s\n' 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
printf '%s\n' 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"
printf '%s\n' "$CMDLINE" > "$ROOTFS_DIR/etc/cmdline"
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL /         ext4 defaults 0 1
LABEL=$BOOT_LABEL    /boot     ext4 defaults 0 2
LABEL=$ESP_LABEL     /boot/efi vfat defaults,nofail,x-systemd.device-timeout=10 0 2
EOF
echo "%wheel ALL=(ALL:ALL) ALL" > "$ROOTFS_DIR/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/wheel"
echo 'root:root' | arch-chroot "$ROOTFS_DIR" chpasswd

arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager.service
case "$DE_NAME" in
    gnome) arch-chroot "$ROOTFS_DIR" systemctl enable gdm.service ;;
    plasma) arch-chroot "$ROOTFS_DIR" systemctl enable sddm.service ;;
esac

KERNEL="$ROOTFS_DIR/boot/Image"
DTB="$ROOTFS_DIR/boot/dtbs/qcom/$DTB_NAME"
KERNREL="$ROOTFS_DIR/usr/share/kernel/lapis/kernel.release"
if [ ! -f "$KERNEL" ] || [ ! -f "$DTB" ] || [ ! -f "$KERNREL" ]; then
    echo "linux-lapis did not install Image, $DTB_NAME, or kernel.release" >&2
    exit 1
fi
KERNVER="$(cat "$KERNREL")"

write_grub_cfg() {
    cat > "$1" <<EOF
set timeout=1
set default=0
menuentry 'EndeavourOS' {
  linux /Image $CMDLINE
  devicetree /dtbs/qcom/$DTB_NAME
}
EOF
}

echo "### Creating the boot filesystem..."
truncate -s "${BOOT_SIZE_MB}M" "$OUT/endeavouros_boot.raw"
MKE2FS_DEVICE_SECTSIZE=4096 MKE2FS_DEVICE_PHYS_SECTSIZE=4096 \
    mkfs.ext4 -F -L "$BOOT_LABEL" -b 4096 \
    -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file \
    "$OUT/endeavouros_boot.raw"
mount -o loop "$OUT/endeavouros_boot.raw" "$BOOT_MNT"
cp "$KERNEL" "$BOOT_MNT/Image"
mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2"
cp "$DTB" "$BOOT_MNT/dtbs/qcom/$DTB_NAME"
printf '%s\n' "$CMDLINE" > "$BOOT_MNT/cmdline.txt"
write_grub_cfg "$BOOT_MNT/grub2/grub.cfg"
umount "$BOOT_MNT"

echo "### Creating the EFI system partition..."
truncate -s "${ESP_SIZE_MB}M" "$OUT/endeavouros_esp.raw"
# pstoredump is a 128M FAT16 volume with 4096-byte sectors.
mkfs.fat -F 16 -S 4096 -n "$ESP_LABEL" "$OUT/endeavouros_esp.raw"
mount -o loop "$OUT/endeavouros_esp.raw" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT"
cp "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
write_grub_cfg "$ESP_MNT/EFI/BOOT/grub.cfg"
umount "$ESP_MNT"

echo "### Creating the root filesystem image..."
ROOT_BYTES="$(du -sb "$ROOTFS_DIR" | awk '{print $1}')"
ROOT_MB="$(( ROOT_BYTES / 1024 / 1024 + ROOT_BYTES / 1024 / 1024 / 8 + 512 ))"
truncate -s "${ROOT_MB}M" "$OUT/endeavouros_rootfs.raw"
MKE2FS_DEVICE_SECTSIZE=4096 MKE2FS_DEVICE_PHYS_SECTSIZE=4096 \
    mkfs.ext4 -F -L "$ROOTFS_LABEL" -b 4096 "$OUT/endeavouros_rootfs.raw"
mount -o loop "$OUT/endeavouros_rootfs.raw" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' "$ROOTFS_DIR/" "$IMAGE_MNT/"
umount "$IMAGE_MNT"

echo "### Packing the release archive..."
cp "$SILICIUM_IMG" "$OUT/silicium.img"
cat > "$OUT/BUILDINFO.txt" <<EOF
desktop=$DE_NAME
date=$DATE
git=$BUILD_GIT_REV
kernel=$KERNVER
hostname=lapis
root_label=$ROOTFS_LABEL
boot_label=$BOOT_LABEL
esp_label=$ESP_LABEL
repo=$LAPIS_REPO_URL
cmdline=$CMDLINE
EOF

cat > "$OUT/flash.sh" <<'EOF'
#!/usr/bin/env bash
# Flash EndeavourOS onto the partitions the lapis port already uses.
# Slot A, userdata, and vbmeta are left alone.
set -euo pipefail
cd "$(dirname "$0")"

echo "Lenovo Yoga Tab Plus (lapis) flasher"
echo "  silicium.img           -> boot_b"
echo "  endeavouros_esp.raw    -> pstoredump"
echo "  endeavouros_boot.raw   -> lenovocust"
echo "  endeavouros_rootfs.raw -> arch"
echo
echo "This replaces the Linux system on the arch partition."
echo "boot_a and userdata are not written."
read -r -p "Type yes to flash: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

fastboot devices | grep -q . || { echo "No fastboot device." >&2; exit 1; }
fastboot flash boot_b silicium.img
fastboot flash pstoredump endeavouros_esp.raw
fastboot flash lenovocust endeavouros_boot.raw
fastboot flash arch endeavouros_rootfs.raw
fastboot set_active b
fastboot reboot
EOF

cat > "$OUT/flash-multiboot.sh" <<'EOF'
#!/usr/bin/env bash
# Choose the boot slot and the rootfs partition. The EFI and kernel
# partitions stay on pstoredump and lenovocust.
set -euo pipefail
cd "$(dirname "$0")"

echo "Boot slot:"
echo "  1) boot_b   (the slot this port uses)"
echo "  2) boot_a"
read -r -p "Choice [1]: " slot_choice
case "${slot_choice:-1}" in
    1|"") BOOT_PART=boot_b ;;
    2) BOOT_PART=boot_a ;;
    *) echo "Unknown choice." >&2; exit 1 ;;
esac

read -r -p "Rootfs partition name [arch]: " ROOT_PART
ROOT_PART="${ROOT_PART:-arch}"
if [ "$ROOT_PART" = "userdata" ]; then
    echo "userdata is the Android data partition."
    read -r -p "Type userdata again to overwrite it: " confirm_user
    [ "$confirm_user" = "userdata" ] || { echo "Cancelled."; exit 1; }
fi

echo
echo "  silicium.img           -> $BOOT_PART"
echo "  endeavouros_esp.raw    -> pstoredump"
echo "  endeavouros_boot.raw   -> lenovocust"
echo "  endeavouros_rootfs.raw -> $ROOT_PART"
read -r -p "Type yes to flash: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

fastboot devices | grep -q . || { echo "No fastboot device." >&2; exit 1; }
fastboot flash "$BOOT_PART" silicium.img
fastboot flash pstoredump endeavouros_esp.raw
fastboot flash lenovocust endeavouros_boot.raw
fastboot flash "$ROOT_PART" endeavouros_rootfs.raw
case "$BOOT_PART" in
    boot_a) fastboot set_active a ;;
    boot_b) fastboot set_active b ;;
esac
fastboot reboot
EOF
chmod +x "$OUT/flash.sh" "$OUT/flash-multiboot.sh"

(
    cd "$OUT"
    sha256sum \
        silicium.img \
        endeavouros_esp.raw \
        endeavouros_boot.raw \
        endeavouros_rootfs.raw \
        flash.sh \
        flash-multiboot.sh \
        BUILDINFO.txt > SHA256SUMS
)
zip -j "$OUT.zip" "$OUT"/*
echo "Wrote $OUT.zip"
