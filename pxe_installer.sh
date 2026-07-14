#!/bin/bash

# version: v2.2
# Author: Jasper.Lee
# Description: 
#   a. Refactor: Folder logic for case-insensitive
#   b. Refactor: Re-name "undionly.kpxe" and "ipxe.efi" for corresponding platform
#   c. Support aarch64 booting to PXE menu
#   d. Update pxe-system-type for x86_64 and aarch64

set -eo pipefail
VERSION="v2.2"
UPDATE_DATE="2026/05/19"
RUN_ID=$(date '+%Y%m%d-%H%M%S')
RUN_TS=$(date +%s)
TEMP_LOG="/tmp/pxe_setup_${RUN_ID}.log"
LOG_FILE="$TEMP_LOG"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
IPXE_VERSION="v1.21.1_20260121_g0abef79a2"

# ----- Utility -----
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # echo -e "[$timestamp] $message" | tee -a "$LOG_FILE"
    # stdout
    echo -e "[$timestamp] $message"
    # log file
    echo -e "[$timestamp] $message" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}
error_exit() {
    log "${RED}[ERROR]${RESET} $1"
    exit 1
}
warning() {
    log "${YELLOW}[WARNING]${RESET} $1"
}

check_permission() {
    local SCRIPT_NAME=$(basename "$0")
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run with sudo, not as a normal user. Usage: sudo ./$SCRIPT_NAME [OPTIONS]"
    fi
    if [[ -z "${SUDO_USER:-}" ]]; then
        warning "Running as root directly (not via sudo). Proceeding anyway."
    fi
}

set_color(){
    RED='\e[31m'    # error
    GREEN='\e[32m'  # ipxe patch
    YELLOW='\e[33m' # warning
    RESET='\e[0m'   # reset
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file '$CONFIG_FILE' not found! Please refer 'config.env.example' to '$CONFIG_FILE' and configure it before running."
    fi
    log "Loading configuration from $CONFIG_FILE..."

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip white line and command
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z $(echo "$key" | xargs) ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | sed 's/^["'\'']\|["'\'']$//g')

        # source config.env
        case "$key" in
            PXE_INTERFACE|PXE_DOMAIN_NAME|PXE_BRIDGE|\
            PXE_SERVER_IPv4|PXE_PREFIX_IPv4|PXE_SUBNET_IPv4|PXE_NETMASK_IPv4|PXE_DHCP_RANGE_START_IPv4|PXE_DHCP_RANGE_END_IPv4|DNS_SERVER_IPv4|\
            PXE_SERVER_IPv6|PXE_PREFIX_IPv6|PXE_SUBNET_IPv6|PXE_DHCP_RANGE_START_IPv6|PXE_DHCP_RANGE_END_IPv6|DNS_SERVER_IPv6|\
            ISO_PATH|HTTP_PATH|TFTP_PATH|LOG_PATH|BIN_PATH|\
            DHCP_LEASE_TIME|DHCP_MAX_LEASE_TIME)
                if [[ -z "$value" ]]; then
                    error_exit "Variable '$key' in $CONFIG_FILE is empty! All required fields must have a value."
                fi
                export "$key=$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    if [[ ! -d "$LOG_PATH" ]]; then
        mkdir -p "$LOG_PATH"
    fi

    FINAL_LOG="${LOG_PATH}/logs-${RUN_ID}.log"
    cat "$TEMP_LOG" >> "$FINAL_LOG" 
    rm -f "$TEMP_LOG"
    LOG_FILE="$FINAL_LOG"
    log "Configuration loaded successfully. All logs will be saved to $LOG_FILE"
}

validate_config() {
    log "Validating configuration values..."

    local required_vars=(
        "PXE_INTERFACE" "PXE_SERVER_IPv4" "PXE_SERVER_IPv6" "PXE_BRIDGE" "ISO_PATH" 
        "HTTP_PATH" "TFTP_PATH" "LOG_PATH" "BIN_PATH"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Critical configuration missing: $var. Please check your $CONFIG_FILE."
        fi
    done
    for var in HTTP_PATH TFTP_PATH LOG_PATH BIN_PATH; do
        if [[ "${!var}" != /pxe/* ]]; then
            warning "$var is not under /pxe. The script may not work correctly."
        fi
    done
    if [[ ! -d "/sys/class/net/$PXE_INTERFACE" ]]; then
        error_exit "Network interface '$PXE_INTERFACE' does not exist! Use 'ip link' to check your interface name."
    fi
    if [[ ! -d "$ISO_PATH" ]]; then
        error_exit "ISO_PATH '$ISO_PATH' is not a directory or not mounted. Please check your external drive."
    fi
    log "Configuration validation passed."
}

welcomeinfo() {
    clear
    cat << EOF  | tee -a "$LOG_FILE"
========================================================
Ubuntu Desktop PXE Server Installation
========================================================
Version: $VERSION
Author: Jasper.Lee
Last Update: $UPDATE_DATE

OS Version: $(lsb_release -d | cut -f2- | tr -d '\n'; echo -n " "; uname -r)
PXE Domain Name: $PXE_DOMAIN_NAME
PXE Interface: $PXE_INTERFACE
PXE BRIDGE: $PXE_BRIDGE
PXE SERVER [IPv4]: $PXE_SERVER_IPv4
PXE SERVER [IPv6]: $PXE_SERVER_IPv6
Date/Time: $(date)
========================================================
EOF
}

dependency() {
    log "Installing required packages..."
    apt update >> "$LOG_FILE" 2>&1
    apt install -y isc-dhcp-server tftpd-hpa tftp-hpa apache2 \
        syslinux-common syslinux-efi syslinux git gcc binutils \
        make perl liblzma-dev mtools genisoimage \
        isolinux tree curl networkd-dispatcher \
        libssl-dev ndisc6 radvd \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        nfs-kernel-server >> "$LOG_FILE" 2>&1    
    apt remove -y ipxe >> "$LOG_FILE" 2>&1 || true
    apt autoremove -y > /dev/null 2>&1
    log "Package installation completed."
}

firewall() {
    log "Check firewall status..."
    ufw status 2>&1 | tee -a "$LOG_FILE"

    warning "Skipping firewall setup..."
    warning "Firewall setup is disabled in this script."
    warning "Make sure this server is in a trusted network environment."
    warning "To enable firewall protection, uncomment the following rules in script."

    # log "Setup Firewall..."
    # ========================================================
    # [IPv4 Rules] - Source: $PXE_SUBNET_IPv4/$PXE_PREFIX_IPv4
    # ========================================================
    # ufw allow from $PXE_SUBNET_IPv4/$PXE_PREFIX_IPv4 to any port 22 proto tcp
    # ufw allow from $PXE_SUBNET_IPv4/$PXE_PREFIX_IPv4 to any port 67 proto udp
    # ufw allow from $PXE_SUBNET_IPv4/$PXE_PREFIX_IPv4 to any port 69 proto udp
    # ufw allow from $PXE_SUBNET_IPv4/$PXE_PREFIX_IPv4 to any port 80 proto tcp

    # ========================================================
    # [IPv6 Rules] - Source: ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6}
    # ========================================================
    # ufw allow from ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6} to any port 22 proto tcp
    # ufw allow from ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6} to any port 547 proto udp
    # ufw allow from ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6} to any port 69 proto udp
    # ufw allow from ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6} to any port 80 proto tcp

    # [Special Note for IPv6]
    # IPv6 requires ICMPv6 for Neighbor Discovery. 
    # UFW allows this by default, but DO NOT block it in '/etc/ufw/before6.rules'.
}

setup_dir() {
    log "Creating essential directory..."

    local dirs=(
        "$HTTP_PATH"
        "$TFTP_PATH"/{ipxe,EFI,BIOS}
        "$BIN_PATH"
    )

    for dir in "${dirs[@]}"; do mkdir -p "$dir"; log "Creating directory: $dir"; done
}

setup_network() {
    log "Setup static IPv4 and IPv6 configuration..."
    
    if [[ -f "/etc/netplan/02-pxe.yaml" ]]; then
        warning "Backing up existing netplan"
        cp "/etc/netplan/02-pxe.yaml" "/etc/netplan/02-pxe.yaml.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    tee /etc/netplan/02-pxe.yaml > /dev/null << EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $PXE_INTERFACE:
      dhcp4: false
      dhcp6: false
      optional: true
  bridges:
    $PXE_BRIDGE:
      interfaces: [$PXE_INTERFACE]
      addresses:
        - $PXE_SERVER_IPv4/$PXE_PREFIX_IPv4
        - ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6}
      parameters:
        stp: false
        forward-delay: 0
      dhcp4: false
      dhcp6: false
EOF
    sed 's/^/[NETPLAN] /' "/etc/netplan/02-pxe.yaml" >> "$LOG_FILE"
    log "Applying network configuration..."
    chmod 600 /etc/netplan/02-pxe.yaml
    nmcli connection reload || true
    if netplan apply 2>&1 | tee -a "$LOG_FILE"; then
        log "Network configuration applied successfully for $PXE_INTERFACE"
    else
        error_exit "Failed to apply netplan configuration!"
    fi
    sleep 3
    
    log "Current Network Status (Bridge $PXE_BRIDGE):"
    ip addr show $PXE_BRIDGE | grep -E "inet |inet6 |state" 2>&1 | tee -a "$LOG_FILE"
}
setup_dhcp() {
    log "Setup DHCP server..."
    if [[ -f "/etc/dhcp/dhcpd.conf" ]]; then
        warning "Backing up existing dhcp configuration"
        cp "/etc/dhcp/dhcpd.conf" "/etc/dhcp/dhcpd.conf.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi
    if [[ -f "/etc/dhcp/dhcpd6.conf" ]]; then
        warning "Backing up existing IPv6 dhcp configuration"
        cp "/etc/dhcp/dhcpd6.conf" "/etc/dhcp/dhcpd6.conf.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi

    tee /etc/dhcp/dhcpd.conf > /dev/null << EOF
# DHCPv4 Configuration
option domain-name "$PXE_DOMAIN_NAME";
option domain-name-servers $DNS_SERVER_IPv4;
default-lease-time $DHCP_LEASE_TIME;
max-lease-time $DHCP_MAX_LEASE_TIME;
authoritative;

# IPv4 subnet
subnet $PXE_SUBNET_IPv4 netmask $PXE_NETMASK_IPv4 {
    range $PXE_DHCP_RANGE_START_IPv4 $PXE_DHCP_RANGE_END_IPv4;
    option routers $PXE_SERVER_IPv4;
    # option broadcast-address ${PXE_SUBNET_IPv4%.*}.255; # dhcpd will automatically calculate based on netmask.
    
    # IPv4 Boot
    next-server $PXE_SERVER_IPv4;
    
    if exists user-class and option user-class = "iPXE" {
        filename "http://$PXE_SERVER_IPv4/ipxe/boot.ipxe";
    } elsif substring(option vendor-class-identifier, 0, 9) = "PXEClient" {
        if option pxe-system-type = 00:07 {
            filename "ipxe/ipxe-x86.efi";           # EFI Byte Code (64-bit UEFI)
        } elsif option pxe-system-type = 00:09 {
            filename "ipxe/ipxe-x86.efi";           # EFI x86_64 (64-bit UEFI)
        } elsif option pxe-system-type = 00:0B {
            filename "ipxe/snp-arm64.efi";          # ARM 64-bit UEFI
        } else {
            filename "ipxe/undionly-legacy.kpxe";   # Legacy BIOS
        }
    } else {
        filename "ipxe/undionly-legacy.kpxe";       # Legacy BIOS
    }
}
EOF
    sed 's/^/[DHCP] /' /etc/dhcp/dhcpd.conf >> "$LOG_FILE"

    tee /etc/dhcp/dhcpd6.conf > /dev/null << EOF
# DHCPv6 Configuration
log-facility local7;
default-lease-time $DHCP_LEASE_TIME;
max-lease-time $DHCP_MAX_LEASE_TIME;

# IPv6 Subnet
subnet6 $PXE_SUBNET_IPv6/$PXE_PREFIX_IPv6 {
    range6 $PXE_DHCP_RANGE_START_IPv6 $PXE_DHCP_RANGE_END_IPv6;
    option dhcp6.name-servers $PXE_SERVER_IPv6;

    # PXE Boot over IPv6 (RFC 5970)
    if exists user-class and option user-class = "iPXE" {
        option dhcp6.bootfile-url "http://[$PXE_SERVER_IPv6]/ipxe/boot.ipxe";
    } elsif option dhcp6.client-arch-type = 00:09 {
        option dhcp6.bootfile-url "tftp://[$PXE_SERVER_IPv6]/ipxe/ipxe-x86.efi";
    } elsif option dhcp6.client-arch-type = 00:0B {
        option dhcp6.bootfile-url "tftp://[$PXE_SERVER_IPv6]/ipxe/snp-arm64.efi";
    } else {
        option dhcp6.bootfile-url "tftp://[$PXE_SERVER_IPv6]/ipxe/undionly-legacy.kpxe";
    }
}
EOF
    sed 's/^/[DHCP6] /' /etc/dhcp/dhcpd6.conf >> "$LOG_FILE"

    tee  /etc/default/isc-dhcp-server > /dev/null << EOF
INTERFACESv4="$PXE_BRIDGE"
INTERFACESv6="$PXE_BRIDGE"
EOF
    sed 's/^/[isc-dhcp-server] /' "/etc/default/isc-dhcp-server" >> "$LOG_FILE"
    log "DHCP configuration setup $PXE_BRIDGE done."
}

setup_radvd() {
    log "Setup Router Advertisement Daemon (radvd)..."
    if [[ -f "/etc/radvd.conf" ]]; then
        warning "Backing up existing radvd configuration"
        cp "/etc/radvd.conf" "/etc/radvd.conf.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi

    tee /etc/radvd.conf > /dev/null << EOF
interface $PXE_BRIDGE
{
    AdvSendAdvert on;
    AdvManagedFlag on;
    AdvOtherConfigFlag on;

    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    prefix $PXE_SUBNET_IPv6/$PXE_PREFIX_IPv6
    {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
    };
};
EOF
    sed 's/^/[radvd] /' /etc/radvd.conf >> "$LOG_FILE"
    
    # Modify sysctl to allow forwarding (although PXE Server typically does not forward, radvd sometimes requires this setting to take effect).
    echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-radvd.conf
    sysctl -p /etc/sysctl.d/99-radvd.conf >> "$LOG_FILE" 2>&1

    log "radvd configuration setup done."
}

setup_tftp() {
    log "Setup TFTP server..."
    if [[ -f "/etc/default/tftpd-hpa" ]]; then
        warning "Backing up existing tftp configuration"
        cp "/etc/default/tftpd-hpa" "/etc/default/tftpd-hpa.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    tee /etc/default/tftpd-hpa > /dev/null << EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_PATH"
TFTP_ADDRESS="[::]:69"
TFTP_OPTIONS="--secure --verbose"
EOF
    sed 's/^/[TFTP] /' "/etc/default/tftpd-hpa" >> "$LOG_FILE"
    log "TFTP configuration setup done."
}

build_ipxe() {
    log "Build iPXE from local source code (v1.21.1)..."
    local original_dir=$(pwd)
    cd third_party/ || error_exit "third_party dir not found"
    # git clone -b v1.21.1 --depth 1 https://github.com/ipxe/ipxe.git ipxe-v1.21.1
    if [ ! -d ipxe_${IPXE_VERSION} ]; then
        tar xzf ipxe_${IPXE_VERSION}.tgz || error_exit "Failed to extract ipxe_${IPXE_VERSION}.tgz"
    fi
    cd ipxe_${IPXE_VERSION}/src || error_exit "iPXE source directory not found"
    
    local ipxe_config="config/general.h"
    # Check ipxe/src/config/general.h enable IPv6
    if grep -q '^[[:space:]]*//\s*#define\s*NET_PROTO_IPV6' "$ipxe_config"; then
        log "${GREEN}[iPXE PATCH]${RESET} Enabling NET_PROTO_IPV6 in $ipxe_config..."
        if sed -i 's|^[[:space:]]*//[[:space:]]*#define[[:space:]]\+NET_PROTO_IPV6|#define NET_PROTO_IPV6|' "$ipxe_config"; then
            log "${GREEN}[iPXE PATCH]${RESET} NET_PROTO_IPV6 enabled successfully"
        else
            warning "${GREEN}[iPXE PATCH]${RESET} Failed to enable NET_PROTO_IPV6"
        fi
    else
        log "${GREEN}[iPXE PATCH]${RESET} NET_PROTO_IPV6 is already enabled or not found."
    fi

    # Check ipxe/src/config/general.h enable PING command
    if grep -q '^[[:space:]]*//\s*#define\s*PING_CMD' "$ipxe_config"; then
        log "${GREEN}[iPXE PATCH]${RESET} Enabling PING_CMD in $ipxe_config..."
        if sed -i 's/^[[:space:]]*\/\/#define\s*PING_CMD/#define PING_CMD/' "$ipxe_config"; then
            log "${GREEN}[iPXE PATCH]${RESET} PING_CMD enabled successfully"
        else
            warning "${GREEN}[iPXE PATCH]${RESET} Failed to enable PING_CMD"
        fi
    else
        log "${GREEN}[iPXE PATCH]${RESET} PING_CMD is already enabled or not found."
    fi

    # Disable autoexec function in script
    ipxe_config="interface/efi/efiprefix.c"
    if grep -q '^[[:space:]]*efi_autoexec_load()' "$ipxe_config"; then
        log "${GREEN}[iPXE PATCH]${RESET} Disabling efi_autoexec_load() in $ipxe_config..."
        if sed -i 's/^[[:space:]]*efi_autoexec_load()/\/\/ &/' "$ipxe_config"; then
            log "${GREEN}[iPXE PATCH]${RESET} efi_autoexec_load() disabled successfully"
        else
            warning "${GREEN}[iPXE PATCH]${RESET} Failed to disable efi_autoexec_load()"
        fi
    else
        log "${GREEN}[iPXE PATCH]${RESET} efi_autoexec_load() is already disabled or not found."
    fi

    make distclean >> "$LOG_FILE" 2>&1 || true
    rm -rf /usr/local/lib/ipxe/ 2>/dev/null || true

    log "Build iPXE BIOS version (undionly.kpxe)..."
    if ! make bin/undionly.kpxe -j$(nproc) >> "$LOG_FILE" 2>&1; then
        error_exit "Failed to build iPXE BIOS version!"
    fi
    log "Build iPXE UEFI version (ipxe.efi with IPv6 support)..."
    if ! make bin-x86_64-efi/ipxe.efi -j$(nproc) >> "$LOG_FILE" 2>&1; then
        error_exit "Failed to build iPXE UEFI version!"
    fi
   
    mkdir -p /usr/local/lib/ipxe
    cp bin/undionly.kpxe /usr/local/lib/ipxe/undionly-legacy.kpxe 2>&1 | tee -a "$LOG_FILE" # Re-name for corresponding platform in v2.2
    cp bin-x86_64-efi/ipxe.efi /usr/local/lib/ipxe/ipxe-x86.efi  2>&1 | tee -a "$LOG_FILE" # Re-name for corresponding platform in v2.2

    # ==================== ADD: aarch64 function ====================
    # log "Build iPXE ARM64 UEFI version ..."
    # if ! make bin-arm64-efi/ipxe.efi -j$(nproc) \
    #     CROSS_COMPILE=aarch64-linux-gnu- >> "$LOG_FILE" 2>&1; then
    #     warning "Failed to build iPXE ARM64 UEFI version!"
    # fi
    # cp bin-arm64-efi/ipxe.efi /usr/local/lib/ipxe/ipxe-arm64.efi 2>&1 | tee -a "$LOG_FILE"

    # Use snp.efi for ARM64 UEFI clients (e.g. Jetson)
    # snp.efi leverages UEFI Simple Network Protocol,
    # which is more compatible than ipxe.efi on ARM platforms.
    log "Build iPXE ARM64 UEFI version ..."
    if ! make bin-arm64-efi/snp.efi -j$(nproc) \
        CROSS_COMPILE=aarch64-linux-gnu- >> "$LOG_FILE" 2>&1; then
        warning "Failed to build iPXE ARM64 UEFI version!"
    fi
    cp bin-arm64-efi/snp.efi /usr/local/lib/ipxe/snp-arm64.efi 2>&1 | tee -a "$LOG_FILE"
    # ===============================================================

    cd "$original_dir"
    log "iPXE build completed."
}

setup_pxe_files() {
    log "Setup PXE files..."
    
    # configuration
    cp "$CONFIG_FILE" /pxe/config.env 2>&1 | tee -a "$LOG_FILE"
    # iPXE binary files (x86)
    cp /usr/local/lib/ipxe/undionly-legacy.kpxe "$TFTP_PATH/ipxe/" 2>&1 | tee -a "$LOG_FILE"
    cp /usr/local/lib/ipxe/ipxe-x86.efi "$TFTP_PATH/ipxe" 2>&1 | tee -a "$LOG_FILE"
    # SYSLUNUX modules
    cp /usr/lib/syslinux/modules/bios/*.c32 "$TFTP_PATH/BIOS" 2>&1 | tee -a "$LOG_FILE"
    cp /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi "$TFTP_PATH/EFI" 2>&1 | tee -a "$LOG_FILE"
    # EFI shell files
    if [[ -f assets/efi/BOOT/Shellx64.efi ]]; then
        cp -r assets/efi/BOOT/ $TFTP_PATH/EFI/ 2>&1 | tee -a "$LOG_FILE"
        log "EFI Shell setup done."
    else
        warning "EFI shell files not found! Will not install EFI Shell in PXE system"
        warning "Manually install: sudo cp /path/to/you/efi/ $TFTP_PATH/EFI"
    fi
    # WinPE files
    if [[ -f assets/winpe/tftp/winpe/wimboot ]]; then
        cp -r assets/winpe/tftp/winpe $TFTP_PATH/ 2>&1 | tee -a "$LOG_FILE"
        cp -r assets/winpe/http/winpe $HTTP_PATH/ 2>&1 | tee -a "$LOG_FILE"
        if grep -Eq "<IP>|<SMB_MOUNT_POINT\?>" $HTTP_PATH/winpe/startup.bat; then
            warning "You should modify $HTTP_PATH/winpe/startup.bat to mount your SMB server; otherwise, WinPE may break"
        fi
        log "WinPE environment setup done."
    else
        warning "WinPE files not found! Will not install WinPE in PXE system"
    fi
    # Ghost files for WinPE
    if [[ -f assets/ghost/Ghost/12.0.0.10618/ghost64.dmp ]]; then
        cp -r assets/ghost/* $HTTP_PATH/ 2>&1 | tee -a "$LOG_FILE"
        log "Ghost for WinPE setup done. You can execute Ghost.bat to launch Ghost."
    else
        warning "Ghost files not found! Will not install Ghost in PXE system"
        warning "Manually install: sudo cp /path/to/you/Ghost/ $HTTP_PATH/Ghost"
    fi

    # ==================== ADD: aarch64 function ====================
    # iPXE binary files (aarch64)
    cp /usr/local/lib/ipxe/snp-arm64.efi "$TFTP_PATH/ipxe/" 2>&1 | tee -a "$LOG_FILE"
    # ===============================================================

    if [[ -f $BIN_PATH/pxe-umount-iso.sh ]]; then 
        $BIN_PATH/pxe-umount-iso.sh >> "$LOG_FILE" 2>&1
    fi
    chown -R tftp:tftp "$TFTP_PATH"
    chown -R www-data:www-data $HTTP_PATH
    chmod -R 755 /pxe
    log "PXE files setup done."
}

setup_apache() {
    log "Setup Apache web server..."
    
    if [[ -f "/etc/apache2/sites-available/pxe.conf" ]]; then
        warning "Backing up existing apache configuration"
        cp "/etc/apache2/sites-available/pxe.conf" "/etc/apache2/sites-available/pxe.conf.backup.$RUN_ID" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    tee /etc/apache2/sites-available/pxe.conf > /dev/null << EOF
<VirtualHost *:80 [::]:80>
    DocumentRoot $HTTP_PATH
    
    <Directory $HTTP_PATH>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    
    Alias /ipxe $TFTP_PATH/ipxe
    <Directory $TFTP_PATH/ipxe>
        Options Indexes
        AllowOverride None
        Require all granted
    </Directory>
    
    Alias /iso $ISO_PATH
    <Directory $ISO_PATH>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF
    sed 's/^/[Apache2] /' /etc/apache2/sites-available/pxe.conf >> "$LOG_FILE"

    # enable site and modules
    a2ensite pxe.conf 2>&1 | tee -a "$LOG_FILE"
    a2dissite 000-default.conf 2>/dev/null || true
    a2enmod headers 2>&1 | tee -a "$LOG_FILE"
    systemctl reload apache2 2>&1 | tee -a "$LOG_FILE"
    systemctl daemon-reload 2>&1 | tee -a "$LOG_FILE"

    # test Apache configuration
    apache2ctl configtest 2>&1 | tee -a "$LOG_FILE"
    log "Apache configuration setup done."
}
create_ipxe_menu() {
    # NOTE: Menu entries are hardcoded for the bundled ISO set in assets/iso/.
    # If you replace ISOs, please update :ubuntu-24.04.3 / :ubuntu-22.04.5 sections.

    log "Setup PXE boot menu..."
    tee $TFTP_PATH/ipxe/boot.ipxe > /dev/null << EOF
#!ipxe
ifconf -c dhcp && goto netv4 || ifconf -c ipv6 && goto netv6 || goto dhcperror

:dhcperror
prompt --key s --timeout 10000 DHCP failed, hit 's' for the iPXE shell; reboot in 10 seconds && shell || reboot

:netv6
set pxeip [${PXE_SERVER_IPv6}] && goto arch_dispatch

:netv4
set pxeip ${PXE_SERVER_IPv4} && goto arch_dispatch

:arch_dispatch
iseq \${buildarch} arm64 && goto menu_arm64 || goto menu_x86

# ============================================================
# x86 / x86_64 Menu
# ============================================================
:menu_x86
menu PXE Boot Menu
item --gap --             | Working Versions |
item ubuntu-24.04.3       Ubuntu 24.04.3 Desktop, kernel 6.14
item ubuntu-22.04.5       Ubuntu 22.04.5 Desktop, kernel 6.8
item --gap --
item --gap --             | Verifying Versions |
item WinPE                WinPE System
item --gap --
item --gap --             | Advanced Options |
item ipxe_shell           iPXE Shell
item efi_shell            EFI Shellx64
item reboot               Reboot
item exit                 Exit to BIOS
choose selected && goto \${selected}

:ubuntu-24.04.3
echo Loading Ubuntu 24.04.3...
kernel http://\${pxeip}/ubuntu-24.04.3-desktop-amd64/casper/vmlinuz
initrd http://\${pxeip}/ubuntu-24.04.3-desktop-amd64/casper/initrd
imgargs vmlinuz boot=casper netboot=url url=http://\${pxeip}/iso/ubuntu-24.04.3-desktop-amd64.iso ip=dhcp toram debug nomodeset --
boot

:ubuntu-22.04.5
echo Loading Ubuntu 22.04.5...
kernel http://\${pxeip}/ubuntu-22.04.5-desktop-amd64/casper/vmlinuz
initrd http://\${pxeip}/ubuntu-22.04.5-desktop-amd64/casper/initrd
imgargs vmlinuz boot=casper url=http://\${pxeip}/iso/ubuntu-22.04.5-desktop-amd64.iso ip=dhcp toram debug nomodeset --
boot

:WinPE
echo Loading WinPE...
kernel tftp://\${pxeip}/winpe/wimboot
initrd http://\${pxeip}/winpe/bootmgr            bootmgr
initrd http://\${pxeip}/winpe/boot/bcd           boot/BCD
initrd http://\${pxeip}/winpe/boot/boot.sdi      boot/boot.sdi
initrd http://\${pxeip}/winpe/sources/boot.wim   boot/boot.wim
initrd http://\${pxeip}/winpe/winpeshl.ini       winpeshl.ini
initrd http://\${pxeip}/winpe/startup.bat        startup.bat
boot

:efi_shell
echo Loading EFI Shell...
chain tftp://\${pxeip}/EFI/BOOT/Shellx64.efi

# ============================================================
# ARM64 Menu
# ============================================================
:menu_arm64
menu PXE Boot Menu (ARM64)
item --gap --             | Jetson Targets |
item jetson-placeholder   Jetson Test Env (TBD)
item --gap --
item --gap --             | Advanced Options |
item ipxe_shell           iPXE Shell
item reboot               Reboot
item exit                 Exit to UEFI
choose selected && goto \${selected}

:jetson-placeholder
echo ============================================
echo  Jetson PXE chain SUCCESS!
echo  pxeip = \${pxeip}
echo  buildarch = \${buildarch}
echo  platform = \${platform}
echo ============================================
echo Press any key to return to menu...
prompt --timeout 10000 || goto menu_arm64
goto menu_arm64

# ============================================================
# Common targets
# ============================================================
:ipxe_shell
shell

:reboot
reboot

:exit
exit
EOF
    chown tftp:tftp $TFTP_PATH/ipxe/boot.ipxe
    chmod 755 $TFTP_PATH/ipxe/boot.ipxe
    sed 's/^/[iPXE Menu] /' $TFTP_PATH/ipxe/boot.ipxe >> "$LOG_FILE"
    log "PXE menu setup done."
}

create_helper_scripts() {
    log "Setup scripts..."
    cp scripts/* $BIN_PATH 2>&1 | tee -a "$LOG_FILE"
    chmod +x $BIN_PATH/*.sh 2>&1 | tee -a "$LOG_FILE"
    log "Script setup done."
}

setup_services() {
    log "Setup systemd services..."
    # log "Force cleanup old masked unit if exists..."
    # rm -f /etc/systemd/system/pxe-mount.service
    # rm -f /etc/systemd/system/pxe-tftp-on-link.service
    # systemctl unmask pxe-mount.service pxe-tftp-on-link.service >> "$LOG_FILE" 2>&1 || true

    # auto-mount service when boot up
    tee /etc/systemd/system/pxe-mount.service > /dev/null << EOF 
[Unit]
Description=PXE ISO Auto Mount Service
After=network.target apache2.service
Requires=apache2.service

[Service]
Type=oneshot
ExecStart=$BIN_PATH/pxe-mount-iso.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sed 's/^/[pxe-mount.service] /' /etc/systemd/system/pxe-mount.service >> "$LOG_FILE"

    tee /etc/systemd/system/pxe-tftp-on-link.service > /dev/null << EOF 
[Unit]
Description=Start TFTP server when PXE Interface link is up
BindsTo=sys-subsystem-net-devices-${PXE_BRIDGE}.device
After=sys-subsystem-net-devices-${PXE_BRIDGE}.device network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl start tftpd-hpa.service
ExecStop=/bin/systemctl stop tftpd-hpa.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    # chmod +x /etc/systemd/system/pxe-tftp-on-link.service
    sed 's/^/[pxe-tftp-on-link.service] /' /etc/systemd/system/pxe-tftp-on-link.service >> "$LOG_FILE"

    tee /etc/networkd-dispatcher/routable.d/start-dhcp-on-link > /dev/null << EOF
#!/bin/bash
if [ "\$IFACE" = "${PXE_INTERFACE}" ]; then
    echo "Connection to PXE Interface detected, starting isc-dhcp-server..."
    systemctl is-active --quiet isc-dhcp-server || systemctl start isc-dhcp-server
    systemctl is-active --quiet isc-dhcp-server6 || systemctl start isc-dhcp-server6
    systemctl is-active --quiet radvd || systemctl start radvd
fi
EOF
    chmod +x /etc/networkd-dispatcher/routable.d/start-dhcp-on-link
    sed 's/^/[start-dhcp-on-link] /' /etc/networkd-dispatcher/routable.d/start-dhcp-on-link >> "$LOG_FILE"

    systemctl daemon-reload 
    local services=(pxe-mount.service pxe-tftp-on-link.service apache2 tftpd-hpa isc-dhcp-server isc-dhcp-server6 radvd)
    for var in "${services[@]}"; do
        systemctl enable "$var" 2>&1 | tee -a "$LOG_FILE"
        if ! systemctl start "$var" 2>&1 | tee -a "$LOG_FILE"; then
            warning "$var failed to start (maybe NIC down)"
            warning "Please use command below to restart the DHCP service when you connect the PXE DHCP port."
            warning "   $ sudo systemctl restart isc-dhcp-server.service"
        fi
    done
    
    # systemctl status pxe-mount.service pxe-tftp-on-link.service \
    # apache2 tftpd-hpa isc-dhcp-server isc-dhcp-server6
    log "Services configuration setup done and started"
}

mount_iso() {
    log "Mount existing ISO files..."
    
    # if [ -d "$ISO_PATH" ] && [ "$(ls -A $ISO_PATH/*.iso 2>/dev/null)" ]; then
    if compgen -G "$ISO_PATH/*.iso" > /dev/null; then
        $BIN_PATH/pxe-mount-iso.sh 2>&1 | tee -a "$LOG_FILE"
    else
        warning "No ISO files found in $ISO_PATH"
        warning "Please add your ISO files in your $ISO_PATH. Run: sudo $BIN_PATH/pxe-mount-iso.sh"
    fi

    log "ISO mounted."
}

final_status() {
    log "Checking service status..."
    
    cat << EOF | tee -a "$LOG_FILE"
========================================================
PXE Server Setup Complete! 
========================================================
EOF
    log "Build PXE Script Version: $VERSION"
    log "OS Version: $(lsb_release -d | cut -f2- | tr -d '\n'; echo -n " "; uname -r)"

    log "Service status:"
    local services=(pxe-mount.service pxe-tftp-on-link.service apache2 tftpd-hpa isc-dhcp-server isc-dhcp-server6 radvd)
    for var in "${services[@]}"; do
        if systemctl is-active --quiet "$var"; then
            log "$var: active"
        else
            warning "$var: failed" 2>&1 | tee -a "$LOG_FILE"
            systemctl status $var 2>&1 | tee -a "$LOG_FILE"
        fi
    done
    log ""
    log "Network Configuration: $PXE_BRIDGE"
    ip addr show "$PXE_BRIDGE" | grep -E "inet |inet6 |state" 2>&1 | tee -a "$LOG_FILE"
    ip addr show "$PXE_INTERFACE" | grep -E "inet |inet6 |state" 2>&1 | tee -a "$LOG_FILE"

    log ""
    log "Test URLs:"
    log "  > IPv4 HTTP: http://$PXE_SERVER_IPv4/"
    log "  > IPv4 iPXE: http://$PXE_SERVER_IPv4/ipxe/boot.ipxe"
    log "  > IPv6 HTTP: http://[$PXE_SERVER_IPv6]/"
    log "  > IPv6 iPXE: http://[$PXE_SERVER_IPv6]/ipxe/boot.ipxe"
    log "  > TFTP Root: $TFTP_PATH"
    log "  > HTTP Root: $HTTP_PATH"
    log ""
    log "All setup logs saved to: $LOG_FILE"
    log ""

    END_TS=$(date +%s)
    ELAPSED=$((END_TS - RUN_TS))
    H=$((ELAPSED / 3600))
    M=$(( (ELAPSED % 3600) / 60 ))
    S=$((ELAPSED % 60))

    printf -v DURATION "%02d:%02d:%02d" "$H" "$M" "$S"
    log "Spend Time: $DURATION"

    cat << EOF | tee -a "$LOG_FILE" 
========================================================
EOF
}

umount_iso() {
    if [[ -x $BIN_PATH/pxe-umount-iso.sh ]]; then
        $BIN_PATH/pxe-umount-iso.sh
    else
        warning "Umount script not found, skipping..."
    fi
}

uninstall() {
    if [[ ! -f /pxe/config.env ]]; then
        error_exit "/pxe/config.env not found. Cannot determine PXE paths for safe uninstall."
    fi
    
    # shellcheck disable=SC1091
    source /pxe/config.env || error_exit "Failed to load /pxe/config.env"
    
    for v in HTTP_PATH TFTP_PATH BIN_PATH LOG_PATH; do
        if [[ -z "${!v:-}" || "${!v}" == "/" ]]; then
            error_exit "Variable $v is empty or unsafe. Aborting uninstall."
        fi
    done
    
    if [[ -d "$LOG_PATH" ]]; then
        LOG_FILE="$LOG_PATH/logs-uninstall-${RUN_ID}.log"
    fi

    log "Starting uninstallation..."
    umount_iso || true
    local services=(
        "pxe-mount.service"
        "pxe-tftp-on-link.service"
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "tftpd-hpa.service"
        "radvd.service"  
    )
    for var in "${services[@]}"; do
        if systemctl is-active --quiet "$var" 2>/dev/null; then
            log "Stopping $var..."
            systemctl stop "$var" >> "$LOG_FILE" 2>&1 || warning "Failed to stop $var"
        fi
        if systemctl is-enabled --quiet "$var" 2>/dev/null; then
            log "Disabling $var..."
            systemctl disable "$var" >> "$LOG_FILE" 2>&1 || warning "Failed to disable $var"
        fi
    done
    rm -f /etc/netplan/02-pxe.yaml* ; netplan apply >> "$LOG_FILE" 2>&1 || warning "Failed to apply netplan"
    rm -f /etc/dhcp/dhcpd.conf* >> "$LOG_FILE" 2>&1 
    rm -f /etc/dhcp/dhcpd6.conf* >> "$LOG_FILE" 2>&1
    rm -f /etc/radvd.conf* >> "$LOG_FILE" 2>&1
    rm -f /etc/default/tftpd-hpa* >> "$LOG_FILE" 2>&1
    if [[ -d "/usr/local/lib/ipxe" ]]; then rm -rf /usr/local/lib/ipxe/ >> "$LOG_FILE" 2>&1; fi
    a2dissite pxe.conf 2>&1 | tee -a "$LOG_FILE"
    rm -f /etc/apache2/sites-available/pxe.conf* >> "$LOG_FILE" 2>&1
    a2ensite 000-default.conf 2>&1 | tee -a "$LOG_FILE" || warning "Failed to enable Apache site 000-default.conf"
    systemctl daemon-reload 2>&1 | tee -a "$LOG_FILE" || warning "Failed to reload systemd daemon"
    systemctl reload apache2 2>&1 | tee -a "$LOG_FILE" || warning "Failed to reload Apache"
    rm -f /etc/systemd/system/pxe-mount.service >> "$LOG_FILE" 2>&1
    rm -f /etc/systemd/system/pxe-tftp-on-link.service >> "$LOG_FILE" 2>&1
    rm -f /etc/networkd-dispatcher/routable.d/start-dhcp-on-link >> "$LOG_FILE" 2>&1
    if [[ -d /pxe ]]; then
        rm -f /pxe/config.env 2>&1 | tee -a "$LOG_FILE" || warning "Failed to remove /pxe/config.env"
        rm -rf "$HTTP_PATH"/* 2>&1 | tee -a "$LOG_FILE" || warning "Failed to remove /pxe/http"
        rm -rf "$TFTP_PATH"/* 2>&1 | tee -a "$LOG_FILE" || warning "Failed to remove $TFTP_PATH"
        rm -rf "$BIN_PATH"/* 2>&1 | tee -a "$LOG_FILE" || warning "Failed to remove $BIN_PATH"
    fi
    log "Remove PXE server done!"
    read -r -p "Do you want to reboot now? Y/[N]: " REPLY
    echo
    REPLY="${REPLY:-N}"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "System will reboot in 5 seconds..."
        sleep 5
        reboot
    else
        log "Please reboot manually to complete the uninstallation."
    fi
}

usage() {
    cat >&2 <<EOF
PXE Server Setup Script ($VERSION)

Usage: sudo $0 [OPTIONS]

Options:
  (NULL)            Install PXE $VERSION
  -h, --help        Show this help message and exit
  -r, --remove, --uninstall
                    Uninstall PXE server and remove all configurations
  -m, --mount       Only mount ISO files (call pxe-mount-iso.sh)
  -u, --umount      Only unmount ISO files (call pxe-umount-iso.sh)
  --no-ipxe-build   Skip iPXE build (use existing binaries)

Examples:
  sudo $0             # Full PXE server installation
  sudo $0 --uninstall # Remove PXE server and all files
  sudo $0 --mount     # Only mount ISO files from ISO_PATH
EOF
}

main() {
    set_color
    check_permission
    SKIP_IPXE_BUILD=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -r|--remove|--uninstall)
                echo "Do You want to uninstall PXE server?"
                echo "   [Y] Yes [N] No (Default)"
                read -r REPLY
                REPLY="${REPLY:-N}"
                if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                   echo "Aborting uninstall."
                    exit 1
                fi
                uninstall
                exit 0
                ;;
            -m|--mount)
                load_config
                validate_config
                mount_iso
                exit 0
                ;;
            -u|--umount)
                load_config
                umount_iso
                exit 0
                ;;
            --no-ipxe-build)
                SKIP_IPXE_BUILD=true
                ;;
            *)
                warning "Invalid input: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
    load_config
    validate_config 

    echo "Do you want to install PXE server?"
    echo "   [Y] Yes (Default) [N] No "
    read -r REPLY
    REPLY="${REPLY:-Y}"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborting install."
        exit 1
    fi 
    log "Starting PXE Server Setup in 3 seconds..."
    sleep 3
    welcomeinfo  
    dependency
    firewall
    setup_dir
    setup_network
    setup_dhcp
    setup_radvd
    setup_tftp
    [[ "$SKIP_IPXE_BUILD" != true ]] && build_ipxe
    setup_pxe_files
    setup_apache
    create_ipxe_menu
    create_helper_scripts
    setup_services
    mount_iso
    final_status
    log "PXE Server setup completed successfully!"
}
main "$@"