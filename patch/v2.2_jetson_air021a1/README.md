# Jetson AIR-021 PXE Patch

**Version**: v2.2_patch_jetson_air021a1  
**Release Date**: 2026/05/21  
**Author**: Jasper.Lee  

This patch adds PXE boot support for **Advantech AIR-021 (Jetson Orin NX, Orin Nano)** running **JetPack 6.2 / L4T 36.4.3** on **aarch64**.
It is designed for an existing PXE server environment and makes the Jetson boot its root filesystem over NFS through the PXE menu via IPv4.

## What this patch does

- Adds a DHCP rule for Jetson PXE clients and points them to `grubnetaa64.efi.signed`
- Moves the TFTP output directory to `/pxe/tftp/jetson`
- Exports the Jetson root filesystem over NFS
- Rebuilds the Jetson initrd and includes the required network drivers
- Deploys the boot image, initrd, and GRUB configuration for PXE boot

## Requirements

- An already installed PXE server with version 2.2
  
  Note: This patch is based on my PXE installer script **version 2.2** and other versions are not verified. If you use other version or built your own PXE server, you can refer the script and modify yourself.

- `pxe/config.env` must exist on the PXE host
- Advantech AIR-021A1 rootfs, you can get AIR-021A1 BSP from below:
  
  - Download from Advantech [BSP-Launcher](https://docs.aim-linux.advantech.com/docs/utility/bsplauncher/)
  - Refer [AIM-Linux](https://docs.aim-linux.advantech.com/docs/jetpack-6-2#getting-linux-source-code) website to download via command
  - Contact Advantech FAE or PAE

- Root or `sudo` access on the PXE host
- Network access for package installation and downloading `grubnetaa64.efi.signed`

## Files in this patch

- `patch_jetson_air021a1.sh`: automation script that applies the patch
- `jetson.patch`: DHCP and TFTP configuration patch
- `history.txt`: release notes for this patch version

## How to use

Run the script with the Jetson rootfs path as the only argument:

```bash
sudo ./patch_jetson_air021a1.sh <ROOTFS_PATH>
```

Example:

```bash
sudo ./patch_jetson_air021a1.sh /mnt/jetson-rootfs
```

The script will:

1. Install the required packages
2. Apply the DHCP and TFTP configuration patch
3. Add the Jetson rootfs to `/etc/exports`
4. Rebuild `initrd.img-5.15.148-tegra` inside the rootfs
5. Download `grubnetaa64.efi.signed`
6. Copy `Image` and `initrd.img-5.15.148-tegra` into the Jetson TFTP directory
7. Restart DHCP, TFTP, and NFS services

## Expected PXE flow

After the patch is applied, Jetson PXE clients should receive the ARM64 GRUB loader and enter a GRUB menu entry similar to:

- `Jetson`
- `Jetson (verbose)`

Both entries boot the kernel with `root=/dev/nfs` and mount the exported rootfs from the PXE server.

## Verification

After running the script, you can check:

```bash
exportfs -v
ls -l /pxe/tftp/jetson
```

You should also confirm that the rebuilt initrd contains the required drivers:

```bash
chroot <ROOTFS_PATH> /bin/bash -c "lsinitramfs /boot/initrd.img-5.15.148-tegra | grep -E 'r8168|igc'"
```

## Notes

- This patch is intended for the AIR-021 Jetson target only.
- The script assumes the kernel version is `5.15.148-tegra`.
- If your PXE host already has custom DHCP or TFTP settings, review the patch before applying it.
- If the Jetson boot fails, first check DHCP assignment, TFTP file availability, NFS export status, and serial console output.

## Demo

![AIR-021A1 demo with video](demo/boot_air021_20260520_video_gif_acc_compressed.gif)

## Reference
[NVIDIA Jetson Linux Developer Guide](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html#configuring-a-pxe-boot-server-for-uefi-bootloader-on-jetson)