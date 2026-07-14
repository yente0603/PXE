#!/bin/bash
# =====================================================================================================================================================================
# PXE Patch for AIR-021 (L4T 36.4.3) aarch64 NFS boot
# Author      : Jasper.Lee
# Date        : 2026/05/21
# Description : Applying automation script/patch for AIR-021 can boot from PXEv4.
# Reference   : https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html#configuring-a-pxe-boot-server-for-uefi-bootloader-on-jetson
# =====================================================================================================================================================================
# ----- Config -----
set -eo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }
[[ -z "$1" ]] && { echo "Usage: sudo $0 <ROOTFS_PATH>"; exit 1; }

[[ -f /pxe/config.env ]] || { echo "ERROR: /pxe/config.env not found, install PXE first"; exit 1; }
source /pxe/config.env

ROOTFS="$(realpath "$1")"
[[ -d "$ROOTFS" ]] || { echo "ERROR: $ROOTFS not found"; exit 1; }
[[ -f "$ROOTFS/boot/Image" ]] || { echo "ERROR: Image not found in rootfs"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VER="5.15.148-tegra"
JETSON_TFTP="$TFTP_PATH/jetson"
GRUB_URL="http://ports.ubuntu.com/ubuntu-ports/dists/focal/main/uefi/grub2-arm64/current/grubnetaa64.efi.signed"
DRIVERS=(r8168 igc)
TFTP_DHCP_PATCH="jetson.patch"

GREEN=$'\e[32m'
YELLOW=$'\e[33m'
RED=$'\e[31m'
RESET=$'\e[0m'

# ---- Apply patch -----
echo "Applying PXE patch for AIR-021 (L4T 36.4.3) aarch64..."
echo "${GREEN}[1/7]${RESET} Installing dependencies..."
apt update -qq && apt install -y -qq qemu-user-static binfmt-support nfs-kernel-server

echo "${GREEN}[2/7]${RESET} Applying config patches..."
mkdir -p "$JETSON_TFTP"/{efi,grub}
# sed -i 's|^TFTP_DIRECTORY=.*|TFTP_DIRECTORY="/pxe/tftp/jetson"|' /etc/default/tftpd-hpa
if patch --dry-run -R -p1 -d / < "$SCRIPT_DIR/$TFTP_DHCP_PATCH" >/dev/null 2>&1; then
    echo "  ${YELLOW}[SKIP]${RESET} Patches already applied."
else
    patch -p1 -d / < "$SCRIPT_DIR/$TFTP_DHCP_PATCH"
fi

echo "${GREEN}[3/7]${RESET} Configuring NFS export..."
EXPORT_PATH="$ROOTFS *(rw,sync,insecure,no_subtree_check,no_root_squash)"
if ! grep -qF "$ROOTFS" /etc/exports; then
    echo "$EXPORT_PATH" >> /etc/exports
fi
exportfs -ra

echo "${GREEN}[4/7]${RESET} Rebuilding initrd inside rootfs..."
MOD_FILE="$ROOTFS/etc/initramfs-tools/modules"
for mod in "${DRIVERS[@]}"; do
    grep -qx "$mod" "$MOD_FILE" || echo "$mod" >> "$MOD_FILE"
done
chroot "$ROOTFS" /bin/bash -c "LC_ALL=C update-initramfs -u -k ${KERNEL_VER}"

echo "${GREEN}[5/7]${RESET} Downloading grubnetaa64.efi.signed..."
if [[ ! -f "$JETSON_TFTP/efi/grubnetaa64.efi.signed" ]]; then
    wget -q -O "$JETSON_TFTP/efi/grubnetaa64.efi.signed" "$GRUB_URL"
else
    echo "  ${YELLOW}[SKIP]${RESET} Already downloaded."
fi

echo "${GREEN}[6/7]${RESET} Deploying boot files..."
cp "$ROOTFS/boot/Image"                    "$JETSON_TFTP/"
cp "$ROOTFS/boot/initrd.img-${KERNEL_VER}" "$JETSON_TFTP/"

cat > "$JETSON_TFTP/grub/grub.cfg" <<EOF
set timeout_style=menu
set timeout=10

menuentry "Jetson" {
    linux /Image root=/dev/nfs rw netdevwait ip=dhcp \\
nfsroot=${PXE_SERVER_IPv4}:${ROOTFS} \\
console=ttyTCU0,115200 \\
fbcon=map:0 net.ifnames=0 \\
firmware_class.path=/etc/firmware
    initrd /initrd.img-${KERNEL_VER}
}

menuentry "Jetson (verbose)" {
    linux /Image root=/dev/nfs rw netdevwait ip=dhcp \\
nfsroot=${PXE_SERVER_IPv4}:${ROOTFS} \\
console=tty0 console=ttyTCU0,115200 \\
earlycon=tegra_comb_uart,mmio32,0x0c168000 \\
earlyprintk loglevel=7 ignore_loglevel \\
fbcon=map:0 net.ifnames=0 \\
firmware_class.path=/etc/firmware
    initrd /initrd.img-${KERNEL_VER}
}
EOF

echo "${GREEN}[7/7]${RESET} Restart the services and verification..."
systemctl restart isc-dhcp-server tftpd-hpa nfs-server
exportfs -v
chroot "$ROOTFS" /bin/bash -c \
    "lsinitramfs /boot/initrd.img-${KERNEL_VER} | grep -E '$(IFS='|'; echo "${DRIVERS[*]}")'" \
    || echo "WARNING: drivers not found in initrd"

echo "Applying patch done!!"