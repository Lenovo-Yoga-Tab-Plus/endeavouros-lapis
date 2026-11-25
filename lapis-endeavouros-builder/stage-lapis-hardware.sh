#!/bin/bash
# Install the pieces the package repo does not ship.
#
# linux-lapis supplies the kernel, the modules, and the DTB. The qrtr and
# hexagonrpc packages supply the sensor daemons. ath12k needs the tb520fu
# firmware directory and the generic board file. Sensors also need the SSC
# file root.
set -euo pipefail

ROOTFS="${1:?rootfs directory}"
PORT="${LAPIS_PORT_TREE:-/port}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FIRMWARE_RAW="${FIRMWARE_RAW:-$PORT/downstream/firmware_raw}"
ATH12K_BOARD="${ATH12K_BOARD:-$PORT/initramfs_build/mini_stage/lib/wlan-sets/bdf/generic.bin}"
SSH_PUBKEY="${SSH_PUBKEY:-$PORT/keys/tb520fu_ed25519.pub}"

require() {
    if [ ! -e "$1" ]; then
        echo "missing $2: $1" >&2
        exit 1
    fi
}

require "$FIRMWARE_RAW/dsp/adsp" "ADSP sensor libraries"
require "$FIRMWARE_RAW/vendor/etc_sensors/config" "sensor config"
require "$FIRMWARE_RAW/vendor/etc_sensors/sns_reg_config" "sensor registry config"
require "$FIRMWARE_RAW/persist_cal/sensors/registry/sns_reg_version" "sensor calibration"
require "$ATH12K_BOARD" "generic ath12k board file"
require "$SSH_PUBKEY" "USB ssh public key"

echo "### Installing the ath12k board file..."
mkdir -p "$ROOTFS/usr/lib/lapis"
install -m 644 "$ATH12K_BOARD" "$ROOTFS/usr/lib/lapis/ath12k-board.bin"
install -m 755 "$SCRIPT_DIR/stage-ath12k.sh" "$ROOTFS/usr/lib/lapis/stage-ath12k.sh"
install -m 755 "$SCRIPT_DIR/restore-port-binaries.sh" "$ROOTFS/usr/lib/lapis/restore-port-binaries.sh"
"$SCRIPT_DIR/stage-ath12k.sh" "$ROOTFS"

mkdir -p "$ROOTFS/usr/share/libalpm/hooks"
cat > "$ROOTFS/usr/share/libalpm/hooks/lapis-port-files.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-firmware
Target = linux-firmware-atheros
Target = linux-firmware-qcom

[Action]
Description = Restore the TB520FU ath12k board-file layout
When = PostTransaction
Exec = /usr/lib/lapis/restore-port-binaries.sh
EOF

echo "### Installing the sensor file root..."
SENSOR="$ROOTFS/var/lib/lapis-ssc/root"
rm -rf "$SENSOR"
mkdir -p "$SENSOR/dsp" "$SENSOR/sensors/persist" "$SENSOR/socinfo"
cp -a "$FIRMWARE_RAW/dsp/adsp" "$SENSOR/dsp/adsp"
cp -a "$FIRMWARE_RAW/vendor/etc_sensors/config" "$SENSOR/sensors/config"
install -m 644 "$FIRMWARE_RAW/vendor/etc_sensors/sns_reg_config" \
    "$SENSOR/sensors/sns_reg.conf"
cp -a "$FIRMWARE_RAW/persist_cal/sensors/registry" "$SENSOR/sensors/persist/registry"
printf 'QRD\n' > "$SENSOR/socinfo/hw_platform"
printf 'QRD\n' > "$SENSOR/socinfo/platform_subtype"
printf '0\n' > "$SENSOR/socinfo/platform_subtype_id"
printf '65536\n' > "$SENSOR/socinfo/platform_version"
printf '577\n' > "$SENSOR/socinfo/soc_id"
printf '2.0\n' > "$SENSOR/socinfo/revision"
mkdir -p "$SENSOR/data/vendor/aplogd"
: > "$SENSOR/data/vendor/aplogd/log.txt"
if [ ! -d "$SENSOR/sensors/persist/registry/registry" ]; then
    echo "sensor registry is missing the nested registry directory" >&2
    exit 1
fi

echo "### Installing boot and login files..."
mkdir -p "$ROOTFS/etc/systemd/system"
cat > "$ROOTFS/etc/systemd/system/mark-boot-successful.service" <<'EOF'
[Unit]
Description=Mark the booted slot successful
After=local-fs.target
ConditionPathExists=/usr/bin/lapis-slot

[Service]
Type=oneshot
ExecStart=/usr/bin/lapis-slot mark-successful
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

install -Dm600 "$SSH_PUBKEY" "$ROOTFS/root/.ssh/authorized_keys"
chmod 700 "$ROOTFS/root/.ssh"

echo "Staged Wi-Fi firmware and sensors"
