#!/bin/bash
# Build an EndeavourOS image for the Lenovo Yoga Tab Plus (codename lapis).
#
# The boot path matches the running tablet:
#   boot_a       Mu-Silicium UEFI (Linux). Slot B stays the Android boot.
#   pstoredump   FAT16 EFI system partition (4096-byte sectors)
#   lenovocust   ext4 partition labeled "boot" (kernel, DTB, GRUB config)
#   arch         ext4 root filesystem labeled "eos-lapis"
# GRUB loads the linux-lapis Image and the board DTB. linux-lapis has no
# embedded initramfs, so the kernel mounts the root named on its command line.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LAPIS_PORT_TREE:-/port}"

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
# Firmware leaves the panel and USB clocks running. They have to stay that way
# or the panel goes blank as soon as the kernel boots past GRUB.
CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused ignore_loglevel"
if [ -z "${LAPIS_REPO_NAME:-}" ]; then
    LAPIS_REPO_NAME="lapis-pkgs"
fi
if [ -z "${LAPIS_REPO_URL:-}" ]; then
    LAPIS_REPO_URL="https://lenovo-yoga-tab-plus.github.io/lapis-pkgs/repo/"
fi
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
SigLevel = Required DatabaseOptional
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

BASE_PACKAGES=(
    base sudo nano vim
    linux-firmware linux-firmware-qcom linux-firmware-atheros
    archlinuxarm-keyring
    endeavouros-keyring endeavouros-mirrorlist
    eos-hooks
    alsa-ucm-conf
    iptables
    python
    lapis-metapkg
)

read_pkg_list() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Missing package list: $file" >&2
        exit 1
    fi
    grep -vE '^[[:space:]]*(#|$)' "$file"
}

# pacstrap verifies packages with this container's keyring. The image only
# populates Arch Linux ARM, so EndeavourOS signatures stop at "unknown trust"
# (manuel's signing key A367FB01AE54040E and the archive key 003DB8B0CB23504F).
# These three files are endeavouros-keyring 20231222-1, pinned to the hashes
# in that package.
trust_endeavouros_keys() {
    local dir
    dir="$(mktemp -d)"
    if ! (
        set -euo pipefail
        cat > "$dir/sums" <<'EOF'
0e4682e11d84af11f4c3b5d9fb67479eb8d2cb48453cdcd7aafe5509ff19e566b1e6795630c5391a2c61d6c005bf83fd7073f389a76bf5adb3c34506721470e3  endeavouros.gpg
57b1603729122bbfad15e591da1d1bbadc9cbe5f6bcd1525c5045ef341c71993a5c6fef277bac60e841401b42d8c98b8e82e43a090d8b3917c155ac9f590b968  endeavouros-trusted
cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e  endeavouros-revoked
EOF
        while read -r _ file; do
            wget -q -O "$dir/$file" --user-agent=lapis \
                "https://raw.githubusercontent.com/endeavouros-team/keyring/main/$file"
        done < "$dir/sums"
        (
            cd "$dir"
            sha512sum -c sums
        )
        install -dm755 /usr/share/pacman/keyrings
        install -m0644 "$dir/endeavouros.gpg" "$dir/endeavouros-trusted" \
            "$dir/endeavouros-revoked" /usr/share/pacman/keyrings/
        pacman-key --populate endeavouros
    ); then
        rm -rf "$dir"
        echo "Failed to trust EndeavourOS packager keys" >&2
        return 1
    fi
    rm -rf "$dir"
}

mapfile -t WANTED < <(
    printf '%s\n' "${BASE_PACKAGES[@]}"
    read_pkg_list "$SCRIPT_DIR/packages/eos-base-group"
    read_pkg_list "$SCRIPT_DIR/packages/eos-apps"
    read_pkg_list "$SCRIPT_DIR/packages/recom-apps"
    read_pkg_list "$SCRIPT_DIR/packages/$DE_NAME"
)
mapfile -t WANTED < <(printf '%s\n' "${WANTED[@]}" | awk 'NF && !seen[$0]++')

echo "### Syncing package databases..."
pacman --config "$PACMAN_CONF" -Sy

AVAILABLE=()
SKIPPED=()
for pkg in "${WANTED[@]}"; do
    if pacman --config "$PACMAN_CONF" -Si "$pkg" >/dev/null 2>&1; then
        AVAILABLE+=("$pkg")
    else
        SKIPPED+=("$pkg")
        echo "skip (not in the repos): $pkg"
    fi
done

case "$DE_NAME" in
    gnome) REQUIRED=(lapis-metapkg linux-firmware linux-firmware-qcom linux-firmware-atheros networkmanager bluez bluez-utils openssh firefox python gnome-shell gdm pipewire) ;;
    plasma) REQUIRED=(lapis-metapkg linux-firmware linux-firmware-qcom linux-firmware-atheros networkmanager bluez bluez-utils openssh firefox python plasma-desktop sddm pipewire) ;;
esac
for pkg in archlinuxarm-keyring endeavouros-keyring "${REQUIRED[@]}"; do
    if ! printf '%s\n' "${AVAILABLE[@]}" | grep -qx "$pkg"; then
        echo "Required package is not available: $pkg" >&2
        exit 1
    fi
done

echo "### Trusting EndeavourOS packager keys..."
trust_endeavouros_keys

echo "### Bootstrapping rootfs with pacstrap (${#AVAILABLE[@]} packages)..."
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" "${AVAILABLE[@]}"
echo "### Installing packager keys into the rootfs..."
arch-chroot "$ROOTFS_DIR" pacman-key --populate archlinuxarm endeavouros

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
LABEL=$ROOTFS_LABEL /         ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL    /boot     ext4 defaults 0 2
LABEL=$ESP_LABEL     /boot/efi vfat defaults,nofail,x-systemd.device-timeout=10 0 2
EOF
echo "%wheel ALL=(ALL:ALL) ALL" > "$ROOTFS_DIR/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/wheel"
mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
printf '%s\n' 'PermitRootLogin prohibit-password' \
    > "$ROOTFS_DIR/etc/ssh/sshd_config.d/lapis-root.conf"
arch-chroot "$ROOTFS_DIR" passwd -l root

echo "### Staging kernel, Wi-Fi firmware, sensors, and boot services..."
export LAPIS_PORT_TREE="$PORT"
"$SCRIPT_DIR/stage-lapis-hardware.sh" "$ROOTFS_DIR"

enable_unit() {
    arch-chroot "$ROOTFS_DIR" systemctl enable "$1"
}
enable_unit NetworkManager.service
case "$DE_NAME" in
    gnome) enable_unit gdm.service ;;
    plasma) enable_unit sddm.service ;;
esac
enable_unit bluetooth.service
enable_unit sshd.service
enable_unit qrtr-ns.service
enable_unit hexagonrpcd-adsp-sensorspd.service
enable_unit lapis-ssc-resume.service
enable_unit iio-sensor-proxy.service
enable_unit tuned.service
enable_unit tuned-ppd.service
enable_unit mark-boot-successful.service
enable_unit lapis-hardware-mac.service
enable_unit lapis-tablet-mode.service
enable_unit mnt-persist.mount

KERNEL="$ROOTFS_DIR/boot/Image"
DTB="$ROOTFS_DIR/boot/dtbs/qcom/$DTB_NAME"
# linux-lapis installs the release file under lenovo-lapis, not lapis.
KERNREL="$ROOTFS_DIR/usr/share/kernel/lenovo-lapis/kernel.release"
if [ ! -f "$KERNEL" ] || [ ! -f "$DTB" ] || [ ! -f "$KERNREL" ]; then
    echo "linux-lapis did not install Image, $DTB_NAME, or kernel.release" >&2
    echo "looked for $KERNEL, $DTB, and $KERNREL" >&2
    exit 1
fi
KERNVER="$(cat "$KERNREL")"

# This is the menu that booted the installed system. It lives on the EFI
# partition. GRUB selects the ext4 volume labeled "boot", then loads /Image
# and the board DTB from there. There is no configfile chain. linux-lapis
# mounts the root filesystem named by root= on the command line.
write_boot_grub_cfg() {
    cat > "$1" <<EOF
search --no-floppy --set=root --label $BOOT_LABEL
set timeout=1
set default=0
menuentry 'EndeavourOS' {
  linux /Image $CMDLINE
  devicetree /dtbs/qcom/$DTB_NAME
}
EOF
}

write_esp_grub_cfg() {
    write_boot_grub_cfg "$1"
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
cp -a "$ROOTFS_DIR/boot/dtbs/qcom/." "$BOOT_MNT/dtbs/qcom/"
printf '%s\n' "$CMDLINE" > "$BOOT_MNT/cmdline.txt"
write_boot_grub_cfg "$BOOT_MNT/grub2/grub.cfg"
umount "$BOOT_MNT"

echo "### Creating the EFI system partition..."
truncate -s "${ESP_SIZE_MB}M" "$OUT/endeavouros_esp.raw"
# pstoredump is a 128M FAT16 volume with 4096-byte sectors.
mkfs.fat -F 16 -S 4096 -n "$ESP_LABEL" "$OUT/endeavouros_esp.raw"
mount -o loop "$OUT/endeavouros_esp.raw" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT"
cp "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
write_esp_grub_cfg "$ESP_MNT/EFI/BOOT/grub.cfg"
umount "$ESP_MNT"

echo "### Creating the root filesystem image..."
# Same sizing as the pipa image: the file is the installed tree plus a
# little spare room. x-systemd.growfs in fstab grows it to the partition
# on first boot, so the image is not the size of the arch partition.
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
packages=${#AVAILABLE[@]}
skipped=${SKIPPED[*]:-none}
EOF

cat > "$OUT/flash.sh" <<'EOF'
#!/usr/bin/env bash
# Flash EndeavourOS onto the Linux slot.
# Slot B, userdata, and vbmeta are left alone.
set -euo pipefail
cd "$(dirname "$0")"

echo "Lenovo Yoga Tab Plus (lapis) flasher"
echo "  silicium.img           -> boot_a"
echo "  endeavouros_esp.raw    -> pstoredump"
echo "  endeavouros_boot.raw   -> lenovocust"
echo "  endeavouros_rootfs.raw -> arch"
echo
echo "Linux is slot A. Slot B is the Android boot and is not written."
echo "userdata and vbmeta are not written."
echo "The active slot is left as it is. set_active would clear the successful flag."
read -r -p "Type yes to flash: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

fastboot devices | grep -q . || { echo "No fastboot device." >&2; exit 1; }
fastboot flash boot_a silicium.img
fastboot flash pstoredump endeavouros_esp.raw
fastboot flash lenovocust endeavouros_boot.raw
fastboot flash arch endeavouros_rootfs.raw
fastboot reboot
EOF

cat > "$OUT/flash-multiboot.sh" <<'EOF'
#!/usr/bin/env bash
# Flash the Linux slot. The EFI and kernel partitions stay on pstoredump
# and lenovocust. Slot B stays the Android boot.
set -euo pipefail
cd "$(dirname "$0")"

echo "Boot slot: boot_a (Linux). Slot B is the Android boot and is not written."
BOOT_PART=boot_a

read -r -p "Rootfs partition name [arch]: " ROOT_PART
ROOT_PART="${ROOT_PART:-arch}"
case "$ROOT_PART" in
    userdata|boot_a|boot_b|vbmeta|vbmeta_a|vbmeta_b|persist|fsg|modemst1|modemst2|xbl|xbl_a|xbl_b|abl|abl_a|abl_b)
        echo "$ROOT_PART is not a Linux rootfs target." >&2
        exit 1
        ;;
esac

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
CURRENT="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')"
WANTED="${BOOT_PART#boot_}"
if [ "$CURRENT" != "$WANTED" ]; then
    echo "Switching the active slot from ${CURRENT:-unknown} to $WANTED."
    echo "set_active clears the successful flag."
    fastboot set_active "$WANTED"
fi
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
