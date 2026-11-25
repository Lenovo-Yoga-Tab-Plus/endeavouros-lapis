# EndeavourOS for the Lenovo Yoga Tab Plus (lapis)

Image builder for the Lenovo Yoga Tab Plus (TB520FU, codename lapis). Device packages come from the sibling `lapis-pkgs` repository.

Boot is Mu-Silicium UEFI, a FAT EFI system partition, an ext4 boot filesystem, and an ext4 root. Same arrangement as the Xiaomi Pad 6 (pipa) port, with this tablet's partition names.

| Image | Partition | Size on the tablet |
| --- | --- | --- |
| `silicium.img` | `boot_a` | 96 MB |
| `endeavouros_esp.raw` | `pstoredump` | 128 MB, FAT16, 4096-byte sectors |
| `endeavouros_boot.raw` | `lenovocust` | 300 MB, image is 256 MB, label `boot` |
| `endeavouros_rootfs.raw` | `arch` | 100 GB partition, image is the installed tree plus spare room, label `eos-lapis` |

`flash.sh` writes those four partitions and leaves slot B, `userdata`, and `vbmeta` alone. Slot B is the Android boot. It does not call `set_active`. That clears the successful flag, and this bootloader then treats a vbmeta mismatch as fatal. The tablet needs to already be on slot A. `flash-multiboot.sh` asks for the boot slot and the rootfs partition name, and switches slots only when the requested slot is not already active.

GRUB loads `/Image` and `/dtbs/qcom/sm8650-lenovo-tb520fu.dtb` from the boot filesystem. The menu is `\EFI\BOOT\grub.cfg` on the EFI partition: `search --set=root --label boot`, then `linux /Image` and `devicetree`. The kernel is `linux-lapis`. It mounts the root named on its command line. The root line in `/etc/fstab` is `defaults,x-systemd.growfs`. On first boot systemd grows that filesystem to the partition, the same way the Pipa image fills its root partition.

```
root=LABEL=eos-lapis rw rootwait console=tty0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused ignore_loglevel
```

The image installs the EndeavourOS desktop for the selected session, the base group, the EndeavourOS apps, and Firefox. It also stages the ath12k `tb520fu/` firmware layout with the generic board file, the SSC sensor root, `qrtr-ns`, and the hexagonrpcd build that serves that root. `sshd` is enabled, and the tablet SSH public key is installed for root. A oneshot runs `lapis-slot mark-successful` after boot.

The Silicium image in `lapis-endeavouros-builder/silicium.img` is the RELEASE build that boots this tablet. The GRUB binary in `efi-template/EFI/BOOT/BOOTAA64.EFI` is the one on the tablet's EFI system partition.

## Build

`lapis-pkgs` has to be built and reachable first. The default repo URL is `https://lenovo-yoga-tab-plus.github.io/lapis-pkgs/repo/`.

The build reads a TB520FU checkout when one sits next to this repo. A clone on its own uses `port/`, which already has the sensor dump, `qrtr-ns`, `hexagonrpcd`, the generic ath12k board file, and `keys/tb520fu_ed25519.pub`. Set `LAPIS_PORT_TREE` to use a different checkout. The kernel comes from the `linux-lapis` package.

```bash
make builder
make gnome
make plasma
make all
```

Use a local repo while the Pages site is not published yet:

```bash
LAPIS_REPO_URL=file:///build/images/repo make gnome
```

Mount that repo into the container with another `-v` in the Makefile, or publish the repo and use the default URL.

Each archive contains:

- `silicium.img`
- `endeavouros_esp.raw`
- `endeavouros_boot.raw`
- `endeavouros_rootfs.raw`
- `flash.sh`
- `flash-multiboot.sh`
- `BUILDINFO.txt`
- `SHA256SUMS`

## First boot

GNOME runs `gnome-initial-setup`. Plasma uses the login screen. Root password is `root`. Hostname is `lapis`. USB networking comes from `lapis-configs`. SSH accepts the `tb520fu-host` key as root.

## Status

| Device | State |
| --- | --- |
| Panel | Working |
| Touch | Working |
| Pen | Working |
| Folio | Working |
| Keyboard | Working |
| Clickpad | Working |
| Wi-Fi | Working |
| Bluetooth | Working |
| USB network | Working |
| Rear camera | Working |
| Front camera | Working |
| Speakers | Working |
| Internal microphones | Working |
| Headset microphone | Working |
| Light sensor | Working |
| Orientation | Working |
| Proximity | Working |
| Compass | Working |
| Suspend | Working |
| Fingerprint | Not working |
