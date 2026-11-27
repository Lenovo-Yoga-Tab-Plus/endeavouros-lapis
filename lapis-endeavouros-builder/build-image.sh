#!/bin/bash
# Build an EndeavourOS image for the Lenovo Yoga Tab Plus (codename lapis).
#
# The boot path matches the running tablet:
#   boot_a       Mu-Silicium UEFI (Linux). Slot B stays the Android boot.
#   pstoredump   FAT16 EFI system partition (4096-byte sectors)
#   linuxboot    ext4 partition labeled "boot" (kernel, DTB, GRUB config)
#   arch         ext4 root filesystem labeled "eos-lapis"
# GRUB loads the linux-lapis Image, the Dracut initramfs, and the board DTB.
# The kernel package does not build that initramfs. Dracut does, inside this
# rootfs, and that is what mounts root=LABEL=eos-lapis.
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
CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused quiet splash plymouth.force-scale=1"
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
BOOT_SIZE_MB=1024

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
# An external downloader runs as pacman's DownloadUser and cannot write
# /var/lib/pacman/sync. Keep pacman's own client. GitHub Pages still returns
# 503 often enough that the sync and the install are retried below.
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
    dracut
    plymouth
    lapis-metapkg
    lapis-dracut
    lapis-grub-config
    waydroid
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

# The Plasma session is selected as "plasma"; its package list is packages/kde.
case "$DE_NAME" in
    plasma) DE_PKG_LIST="$SCRIPT_DIR/packages/kde" ;;
    *) DE_PKG_LIST="$SCRIPT_DIR/packages/$DE_NAME" ;;
esac
for pkg_list in \
    "$SCRIPT_DIR/packages/eos-base-group" \
    "$SCRIPT_DIR/packages/eos-apps" \
    "$SCRIPT_DIR/packages/recom-apps" \
    "$DE_PKG_LIST"
do
    if [ ! -f "$pkg_list" ]; then
        echo "Missing package list: $pkg_list" >&2
        exit 1
    fi
done
mapfile -t WANTED < <(
    printf '%s\n' "${BASE_PACKAGES[@]}"
    read_pkg_list "$SCRIPT_DIR/packages/eos-base-group"
    read_pkg_list "$SCRIPT_DIR/packages/eos-apps"
    read_pkg_list "$SCRIPT_DIR/packages/recom-apps"
    read_pkg_list "$DE_PKG_LIST"
)
mapfile -t WANTED < <(printf '%s\n' "${WANTED[@]}" | awk 'NF && !seen[$0]++')

echo "### Syncing package databases..."
attempt=1
while ! pacman --config "$PACMAN_CONF" -Sy; do
    if [ "$attempt" -ge 5 ]; then
        echo "Failed to sync package databases" >&2
        exit 1
    fi
    echo "Database sync failed (attempt ${attempt}/5); retrying in 15s" >&2
    attempt=$((attempt + 1))
    sleep 15
done

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
    gnome) REQUIRED=(lapis-metapkg lapis-dracut lapis-grub-config dracut waydroid linux-firmware linux-firmware-qcom linux-firmware-atheros networkmanager bluez bluez-utils openssh firefox python gnome-shell gdm plymouth pipewire) ;;
    plasma) REQUIRED=(lapis-metapkg lapis-dracut lapis-grub-config dracut waydroid linux-firmware linux-firmware-qcom linux-firmware-atheros networkmanager bluez bluez-utils openssh firefox python plasma-desktop sddm plymouth pipewire) ;;
esac
for pkg in archlinuxarm-keyring endeavouros-keyring "${REQUIRED[@]}"; do
    if ! printf '%s\n' "${AVAILABLE[@]}" | grep -qx "$pkg"; then
        echo "Required package is not available: $pkg" >&2
        exit 1
    fi
done

echo "### Trusting EndeavourOS packager keys..."
trust_endeavouros_keys

echo "### Seeding kernel cmdline for the install hook..."
install -d "$ROOTFS_DIR/etc" "$ROOTFS_DIR/boot"
printf '%s\n' "$CMDLINE" > "$ROOTFS_DIR/etc/cmdline"
printf '%s\n' "$CMDLINE" > "$ROOTFS_DIR/boot/cmdline.txt"
printf 'lapis placeholder initramfs\n' | gzip -c > "$ROOTFS_DIR/boot/initramfs.img"

echo "### Bootstrapping rootfs with pacstrap (${#AVAILABLE[@]} packages)..."
attempt=1
while ! pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" "${AVAILABLE[@]}"; do
    if [ "$attempt" -ge 5 ]; then
        echo "Failed to install packages to new root" >&2
        exit 1
    fi
    echo "pacstrap failed (attempt ${attempt}/5); retrying in 20s" >&2
    attempt=$((attempt + 1))
    sleep 20
done
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
# 2944x1840 at ~270 dpi. Without this, Plymouth draws the splash at half
# the panel size and scales it up.
mkdir -p "$ROOTFS_DIR/etc/plymouth"
cat > "$ROOTFS_DIR/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=spinner
ShowDelay=0
DeviceTimeout=8
DeviceScale=1
EOF
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

# The image is only useful if every module lapis.conf loads is actually in
# this kernel. A missing name here is how the tablet boots with a blank panel
# or with touch, Wi-Fi, and the keyboard absent.
kernel_has_module() {
    local rel="$1" name="$2"
    local dir="$ROOTFS_DIR/usr/lib/modules/$rel"
    local us="${name//-/_}" hy="${name//_/-}" found
    if [ -f "$dir/modules.builtin" ] &&
        grep -Eq "/(${us}|${hy})\\.ko$" "$dir/modules.builtin"; then
        return 0
    fi
    found="$(find "$dir" -type f \( \
        -name "${us}.ko" -o -name "${us}.ko.xz" -o -name "${us}.ko.zst" -o -name "${us}.ko.gz" -o \
        -name "${hy}.ko" -o -name "${hy}.ko.xz" -o -name "${hy}.ko.zst" -o -name "${hy}.ko.gz" \
        \) -print -quit)"
    [ -n "$found" ]
}
for MODULE_CONF in \
    "$ROOTFS_DIR/usr/lib/modules-load.d/lapis.conf" \
    "$ROOTFS_DIR/usr/lib/modules-load.d/waydroid.conf"
do
    if [ ! -f "$MODULE_CONF" ]; then
        echo "lapis-configs did not install $MODULE_CONF" >&2
        exit 1
    fi
    while read -r mod; do
        case "$mod" in
            ''|\#*) continue ;;
        esac
        if ! kernel_has_module "$KERNVER" "$mod"; then
            echo "linux-lapis $KERNVER has no module named $mod" >&2
            exit 1
        fi
    done < "$MODULE_CONF"
done
KERNEL_CFG="$ROOTFS_DIR/boot/config-$KERNVER"
if [ ! -f "$KERNEL_CFG" ]; then
    echo "linux-lapis did not install $KERNEL_CFG" >&2
    exit 1
fi
if ! grep -q '^CONFIG_DRM_MSM=y$' "$KERNEL_CFG"; then
    echo "linux-lapis must build the display driver into the kernel" >&2
    exit 1
fi
for opt in CONFIG_PSI CONFIG_ANDROID_BINDER_IPC CONFIG_ANDROID_BINDERFS; do
    if ! grep -q "^${opt}=y$" "$KERNEL_CFG"; then
        echo "linux-lapis must enable $opt for Waydroid" >&2
        exit 1
    fi
done
if ! grep -q '^CONFIG_ANDROID_BINDER_DEVICES=""$' "$KERNEL_CFG"; then
    echo "linux-lapis must leave binder devices empty so Waydroid uses binderfs" >&2
    exit 1
fi
if [ ! -x "$ROOTFS_DIR/usr/bin/waydroid" ]; then
    echo "waydroid is not installed" >&2
    exit 1
fi

# Stock iio-sensor-proxy owns its bus name before it opens the SSC sensors and
# drops a claim that lands in between. lapis-autobright claims the light right
# then, and auto-brightness reads 0 lux for the whole boot.
if [ ! -x "$ROOTFS_DIR/usr/lib/lapis/iio-sensor-proxy" ] ||
    ! grep -qx 'ExecStart=/usr/lib/lapis/iio-sensor-proxy' \
        "$ROOTFS_DIR/usr/lib/systemd/system/iio-sensor-proxy.service.d/lapis-sensor-proxy.conf" 2>/dev/null; then
    echo "lapis-metapkg did not install lapis-sensor-proxy" >&2
    exit 1
fi

echo "### Generating initramfs with dracut..."
if ! arch-chroot "$ROOTFS_DIR" sh -c 'command -v dracut >/dev/null'; then
    echo "dracut is required in the target rootfs but was not found" >&2
    exit 1
fi
if [ ! -f "$ROOTFS_DIR/usr/lib/dracut/dracut.conf.d/10-lapis.conf" ]; then
    echo "lapis-dracut did not install /usr/lib/dracut/dracut.conf.d/10-lapis.conf" >&2
    exit 1
fi
install -d "$ROOTFS_DIR/etc/dracut.conf.d"
cat > "$ROOTFS_DIR/etc/dracut.conf.d/99-plymouth.conf" <<'EOF'
add_dracutmodules+=" plymouth "
EOF
# The disk and the panel are built into the kernel. Packing every module
# into the initramfs makes boot take minutes and leaves the other devices down.
arch-chroot "$ROOTFS_DIR" dracut --force --no-hostonly --no-kernel \
    --omit "firmware kernel-modules kernel-modules-extra kernel-network-modules bluetooth crypt systemd-cryptsetup dm lvm mdraid multipath nfs nbd iscsi fcoe fips cifs qemu qemu-net hwdb resume qcom-adsp devicetree-firmware" \
    --kver "$KERNVER" \
    "/boot/initramfs-$KERNVER.img"
cp -f "$ROOTFS_DIR/boot/initramfs-$KERNVER.img" "$ROOTFS_DIR/boot/initramfs.img"
INITRAMFS_BYTES="$(stat -c '%s' "$ROOTFS_DIR/boot/initramfs.img")"
echo "Initramfs size: $INITRAMFS_BYTES bytes"
if [ "$INITRAMFS_BYTES" -lt 262144 ]; then
    echo "Dracut initramfs is unexpectedly small" >&2
    exit 1
fi
if [ "$INITRAMFS_BYTES" -gt 50331648 ]; then
    echo "Dracut initramfs is larger than 48 MB. That image boots the panel and leaves the other devices down." >&2
    exit 1
fi
INITRAMFS="$ROOTFS_DIR/boot/initramfs.img"

# This is the menu that booted the installed system. It lives on the EFI
# partition. GRUB selects the ext4 volume labeled "boot", then loads /Image,
# the Dracut initramfs, and the board DTB from there. There is no configfile
# chain. Dracut mounts root=LABEL=eos-lapis.
# Android starts \EFI\ANDROID\boot.efi with the linux command. This GRUB
# image has no chainloader command, and linux loads an EFI application.
# That loader enters the stock kernel with the MMU off. A fresh image
# does not contain the Android payload.
write_boot_grub_cfg() {
    cat > "$1" <<EOF
search --no-floppy --set=root --label $BOOT_LABEL
set timeout=15
set timeout_style=menu
set default=0

menuentry 'Linux' {
  search --no-floppy --set=root --label $BOOT_LABEL
  linux /Image $CMDLINE
  devicetree /dtbs/qcom/$DTB_NAME
  initrd /initramfs.img
}

menuentry 'Android' {
  search --no-floppy --set=root --file /EFI/ANDROID/boot.efi
  linux /EFI/ANDROID/boot.efi
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
cp "$INITRAMFS" "$BOOT_MNT/initramfs.img"
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
echo "  endeavouros_boot.raw   -> linuxboot"
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
fastboot flash linuxboot endeavouros_boot.raw
fastboot flash arch endeavouros_rootfs.raw
fastboot reboot
EOF

cat > "$OUT/flash-multiboot.sh" <<'EOF'
#!/usr/bin/env bash
# Flash the Linux slot. The EFI and kernel partitions stay on pstoredump
# and linuxboot. Slot B stays the Android boot.
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
echo "  endeavouros_boot.raw   -> linuxboot"
echo "  endeavouros_rootfs.raw -> $ROOT_PART"
read -r -p "Type yes to flash: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

fastboot devices | grep -q . || { echo "No fastboot device." >&2; exit 1; }
fastboot flash "$BOOT_PART" silicium.img
fastboot flash pstoredump endeavouros_esp.raw
fastboot flash linuxboot endeavouros_boot.raw
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
