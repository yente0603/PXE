#!/bin/bash
# Script to umount ISO files
set -e
source /pxe/config.env

RUN_ID=$(date '+%Y%m%d-%H%M%S')
HTTP_PATH="$HTTP_PATH" 
LOG_FILE="/pxe/log/pxe-umount-${RUN_ID}.log"

log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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

SCRIPT_NAME=$(basename "$0")
if [[ $EUID -ne 0 ]]; then
    error "This script must be run with sudo, not as a normal user. Usage: sudo ./$SCRIPT_NAME"
    exit 1
fi
if [[ -z "$SUDO_USER" ]]; then
    error "Do not run this script as root directly. Please use sudo."
    exit 1
fi

log "Umounting all PXE ISOs..."

find "$HTTP_PATH" -depth -type d | while read -r mount_point; do
     if mountpoint -q "$mount_point" 2>/dev/null; then
        if umount "$mount_point" 2>/dev/null; then
            success "Unmounted $mount_point"
        else
            warning "Normal umount failed, trying lazy umount: $mount_point"
            umount -l "$mount_point" && success "Lazy unmounted $mount_point"
        fi
    fi
done

log "All ISO umounting process completed!"