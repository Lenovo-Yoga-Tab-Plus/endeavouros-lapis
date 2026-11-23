# EndeavourOS for the Lenovo Yoga Tab Plus (lapis)

Image builder for the Lenovo Yoga Tab Plus. The product number is TB520FU. The codename used by this port is lapis. Device packages are published from the sibling `lapis-pkgs` repository.

The boot flow is the same shape as the Xiaomi Pad 6 (pipa) port: Mu-Silicium UEFI, a FAT EFI system partition, a dedicated ext4 boot filesystem, and an ext4 root filesystem. The partition names are the ones on this tablet.

| Image | Partition | Size on the tablet |
| --- | --- | --- |
| `silicium.img` | `boot_a` | 96 MB |
| `endeavouros_esp.raw` | `pstoredump` | 128 MB, FAT16, 4096-byte sectors |
| `endeavouros_boot.raw` | `lenovocust` | 300 MB, image is 256 MB, label `boot` |
| `endeavouros_rootfs.raw` | `arch` | 100 GB partition, image is the installed tree plus spare room, label `eos-lapis` |

`flash.sh` writes those four partitions and leaves slot B, `userdata`, and `vbmeta` alone. Slot B is the Android boot. It does not call `set_active`, because that clears the successful flag and this bootloader then treats a vbmeta mismatch as fatal. The tablet needs to already be on slot A. `flash-multiboot.sh` asks for the boot slot and the rootfs partition name, and switches slots only when the requested slot is not already active.

GRUB loads `/Image` and `/dtbs/qcom/sm8650-lenovo-tb520fu.dtb` from the boot filesystem. The menu is `\EFI\BOOT\grub.cfg` on the EFI partition: `search --set=root --label boot`, then `linux /Image` and `devicetree`. The kernel is `linux-lapis`. It mounts the root named on its command line. The root line in `/etc/fstab` is `defaults,x-systemd.growfs`. On first boot systemd grows that filesystem to the partition, which is how the Pipa image fills its root partition.

```
root=LABEL=eos-lapis rw rootwait console=tty0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused ignore_loglevel
```

The image installs the current EndeavourOS desktop list for the selected session, the base group, the EndeavourOS apps, and Firefox. It also stages the ath12k `tb520fu/` firmware layout with the generic board file, the SSC sensor root, `qrtr-ns`, and the hexagonrpcd build that serves that root. `sshd` is enabled and the tablet SSH public key is installed for root. A oneshot runs `qbootctl -m` after boot.

The Silicium image in `lapis-endeavouros-builder/silicium.img` is the RELEASE build that boots this tablet. The GRUB binary in `efi-template/EFI/BOOT/BOOTAA64.EFI` is the one on the tablet's EFI system partition.

## Local build

`lapis-pkgs` has to be built and reachable first. The default repo URL is `https://lenovo-yoga-tab-plus.github.io/lapis-pkgs/repo/`.

The build reads a TB520FU checkout when one sits next to this repo. A clone on its own uses `port/`, which already has the sensor dump, `qrtr-ns`, `hexagonrpcd`, the generic ath12k board file, and `keys/tb520fu_ed25519.pub`. Set `LAPIS_PORT_TREE` to use a different checkout. The kernel comes from the `linux-lapis` package.

```bash
make builder
make gnome
make plasma
make all
```

Point the builder at a local repo while the Pages site is not published yet:

```bash
LAPIS_REPO_URL=file:///build/images/repo make gnome
```

Mount that repo into the container by adding another `-v` in the Makefile, or publish the repo and use the default URL.

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

GNOME runs `gnome-initial-setup`. Plasma uses the login screen. The root password is `root`. The hostname is `lapis`. USB networking comes from `lapis-configs`. SSH accepts the `tb520fu-host` key as root. Wi-Fi, Bluetooth, and the light and proximity sensors are set up on first boot. The accelerometer still reports orientation as undefined.

## What stays named TB520FU

The kernel is [linux-lapis](https://github.com/Lenovo-Yoga-Tab-Plus/linux-lapis). The local checkout is still `linux-tb520fu`. The device tree, the ADSP firmware directory `qcom/sm8650/lenovo/tb520fu`, the sound card `Lenovo-TB520FU`, and the pen-charger module `lenovo_tb520fu_pen` keep the product name because that is what the kernel and the firmware ask for.
