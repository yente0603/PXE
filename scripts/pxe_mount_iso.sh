#!/bin/bash
# Script to mount ISO files for PXE boot
set -e
source /pxe/config.env

RUN_ID=$(date '+%Y%m%d-%H%M%S')
ISO_PATH="$ISO_PATH"
HTTP_PATH="$HTTP_PATH"
LOG_FILE="/pxe/log/pxe-mount-${RUN_ID}.log"

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] $message" | tee -a "$LOG_FILE"
}
error() {
    log "\e[31m[ERROR]\e[0m $1"
}
warning() {
    log "\e[33m[WARNING]\e[0m $1"
}
success() {
    log "\e[32m[SUCCESS]\e[0m $1"
}
skip() {
    log "\e[33m[SKIP]\e[0m $1"
}

SCRIPT_NAME=$(basename "$0")
if [ -t 0 ]; then  # tty > sudo
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run with sudo, not as a normal user. Usage: sudo ./$SCRIPT_NAME"
        exit 1
    fi
else
    # systemd > root
    if [[ $EUID -ne 0 ]]; then
        error "Systemd must run this script as root."
        exit 1
    fi
fi


log "Starting PXE ISO mounting process..."

if [ ! -d "$ISO_PATH" ]; then
    error "ISO directory '$ISO_PATH' does not exist"
    exit 1
fi
find "$ISO_PATH" -type f -name "*.iso" | while read -r iso; do
    rel_path="${iso#$ISO_PATH/}"            # ex: Windows/Win11.iso
    dirname=$(dirname "$rel_path")         # ex: Windows
    filename=$(basename "$iso" .iso)       # ex: Win11
    mount_point="$HTTP_PATH/$dirname/$filename"

    if [[ "$iso" == *"WinPE_with_Ethernet_driver_from_Win11_24H2_64-Bit"* ]]; then
        skip "WinPE ISO: $iso"
        continue
    fi

    log "Processing $filename..."
    mkdir -p "$mount_point"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        skip "$filename already mounted"
    else
        if mount -o loop,ro,mode=0755 "$iso" "$mount_point"; then
            success "Mounted $filename"
        else
            error "Failed to mount $filename"
        fi
    fi
done

log "All ISO files processed successfully!"
