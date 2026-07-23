#!/bin/bash

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RUN_ID=$(date '+%Y%m%d_%H%M%S')
RUN_TS=$(date +%s)

RUN_TEMP_LOG="/tmp/pxe_setup_${RUN_ID}.log"
RUN_LOG_FILE="${RUN_TEMP_LOG}"
RUN_LOG_DIR=""
APT_LOG=""
IPXE_BUILD_LOG=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAIN_PATH="/opt/pxe"
TEMP_CONFIG_PATH="${SCRIPT_DIR}/config/"
#TODO
PXE_CONFIG_FILE="pxe.conf"
METADATA_FILE="metadata.env"
DEFAULT_PXE_CONFIG="${TEMP_CONFIG_PATH}/pxe.conf"
EXAMPLE_PXE_CONFIG="${TEMP_CONFIG_PATH}/pxe.conf.example"

#TODO
# 由 .run 的啟動 wrapper 設為 1, TODO
# PXE_RUN_MODE="${PXE_RUN_MODE:-0}"
CONFIG_FILE=""
ACTIVE_CONFIG_FILE=""
GENERATED_CONFIG_FILE=""

SKIP_IPXE_BUILD=false

# ─── Output helpers ───────────────────────────────────────────────────────────
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
CURRENT_SECTION=""

cleanup() {
    if [[ -n "${GENERATED_CONFIG_FILE:-}" && -f "${GENERATED_CONFIG_FILE}" ]]; then
        rm -f "${GENERATED_CONFIG_FILE}"
    fi
}
trap cleanup EXIT

log() {
    local message="$1"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[${timestamp}] ${message}"
    echo -e "[${timestamp}] ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "${RUN_LOG_FILE}"
}

log_info() {
    log "${CYAN}[INFO]${RESET} $1"
}

log_pass() {
    log "${GREEN}[PASS]${RESET} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${RESET} $1"
}

log_error() {
    log "${RED}[ERROR]${RESET} $1"
    exit 1
}

section() {
    CURRENT_SECTION="$*"
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}" | sed 's/\x1b\[[0-9;]*m//g' >> "${RUN_LOG_FILE}"
}

# ─── Pre-check Functions ───────────────────────────────────────────────────────────
check_execution_context() {
    section "Execution Context Check"

    local script_name=$(basename "$0")
    
    [[ $EUID -eq 0 ]] || \
        log_error "This script must be run with sudo. Usage: sudo ./${script_name} [OPTIONS]"

    [[ -n "${SUDO_USER:-}" ]] || \
        log_warn "Running directly as root (not via sudo). Proceeding anyway."

    log_pass "Permission check completed."
}

check_os_info(){
    section "Check Operating System"

    OS_NAME="$(uname -s)"
    if [[ "$OS_NAME" != "Linux" ]]; then
        log_error "Not Linux (detected: $OS_NAME)."
    else
        DISTRO="unknown"
        if [[ -f /etc/os-release ]]; then
            DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
        elif [[ -f /etc/lsb-release ]]; then
            DISTRO="$(. /etc/lsb-release && echo "${DISTRIB_DESCRIPTION:-$DISTRIB_ID}")"
        fi

        # Jetson / L4T
        # if [[ -f /etc/nv_tegra_release ]] || grep -qi "tegra\|jetson\|l4t" /etc/os-release 2>/dev/null; then
        #     log_info "Linux — Jetson/L4T detected (${DISTRO})"
        # Yocto
        # elif grep -qi "yocto\|poky" /etc/os-release 2>/dev/null || [[ -f /etc/build ]]; then
        #     log_info "Linux — Yocto detected (${DISTRO})"
        # Ubuntu
        if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
            log_info "Linux — Ubuntu detected (${DISTRO})"
        else
            log_warn "Linux detected (${DISTRO}) — not Ubuntu; may work but untested."
        fi
    fi

    KERNEL="$(uname -r)"
    log_info "Kernel: ${KERNEL}  Arch: $(uname -m)"
    log_pass "OS check completed."
}

load_metadata() {
    section "Load Metadata"

    local metadata_file="${TEMP_CONFIG_PATH}/metadata.env"
    
    [[ -f "${metadata_file}" ]] || \
        log_error "Metadata file not found: ${metadata_file}"
    
    # shellcheck disable=SC1090
    source "${metadata_file}"
    log_pass "Metadata load completed."
}

load_pxe_config() {
    section "Load PXE Config"

    local config_file="${TEMP_CONFIG_PATH}/${PXE_CONFIG_FILE}"
    
    [[ -f "$config_file" ]] || \
        log_error "Configuration file '$config_file' not found."
    
    # shellcheck disable=SC1090
    source "$config_file"

    RUN_LOG_DIR="${LOG_PATH}/pxe_manager_${RUN_ID}"
    RUN_LOG_FILE="${RUN_LOG_DIR}/installer.log"
    APT_LOG="${RUN_LOG_DIR}/apt.log"
    IPXE_BUILD_LOG="${RUN_LOG_DIR}/ipxe_build.log"

    mkdir -p "${RUN_LOG_DIR}"
    if [[ -f "${RUN_TEMP_LOG}" ]]; then
        cat "${RUN_TEMP_LOG}" >> "${RUN_LOG_FILE}"
        rm -f "${RUN_TEMP_LOG}"
    fi
    
    log_pass "PXE config load completed. Logs save to: ${RUN_LOG_FILE}"
}

# ─── Main Functions ───────────────────────────────────────────────────────────
show_welcome_info() {
    clear

    cat << EOF  | tee -a "${RUN_LOG_FILE}"
========================================================
    ${PRODUCT_NAME}
========================================================
    Version: ${VERSION}
    Author: ${AUTHOR}
    Release Date: ${RELEASE_DATE}

    OS: ${DISTRO} (${KERNEL})
    PXE Domain Name: ${PXE_DOMAIN_NAME}
    PXE Interface: ${PXE_INTERFACE}
    PXE BRIDGE: ${PXE_BRIDGE}
    PXE SERVER [IPv4]: ${PXE_SERVER_IPv4}
    PXE SERVER [IPv6]: ${PXE_SERVER_IPv6}
    Date/Time: $(date)
========================================================

EOF
}

install_dependency() {
    section "Install Dependency"

    apt update >> "${APT_LOG}" 2>&1
    apt install -y isc-dhcp-server tftpd-hpa tftp-hpa apache2 \
        syslinux-common syslinux-efi syslinux git gcc binutils \
        make perl liblzma-dev mtools genisoimage \
        isolinux tree curl networkd-dispatcher \
        libssl-dev ndisc6 radvd \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        nfs-kernel-server >> "${APT_LOG}" 2>&1    
    apt remove -y ipxe >> "${APT_LOG}" 2>&1 || true
    apt autoremove -y > /dev/null 2>&1

    log_pass "Dependency install completed."
}

setup_firewall() {
    section "Check Firewall Status"

    ufw status 2>&1 | tee -a "${RUN_LOG_FILE}"

    log_warn "Skip firewall setup."
    log_warn "Firewall setup is disabled in this version (${VERSION})."
    log_warn "Make sure this server is in a trusted network environment."

    # log "Setup Firewall..."
    # ========================================================
    # [IPv4 Rules] - Source: ${PXE_SUBNET_IPv4}/${PXE_PREFIX_IPv4}
    # ========================================================
    # ufw allow from ${PXE_SUBNET_IPv4}/${PXE_PREFIX_IPv4} to any port 22 proto tcp
    # ufw allow from ${PXE_SUBNET_IPv4}/${PXE_PREFIX_IPv4} to any port 67 proto udp
    # ufw allow from ${PXE_SUBNET_IPv4}/${PXE_PREFIX_IPv4} to any port 69 proto udp
    # ufw allow from ${PXE_SUBNET_IPv4}/${PXE_PREFIX_IPv4} to any port 80 proto tcp

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
    section "Setup Essential Directory"

    local dirs=(
        "${HTTP_PATH}"
        "${TFTP_PATH}"/{ipxe,efi,bios}
        "${BIN_PATH}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}" || log_error "Failed to create directory: ${dir}"
        log_pass "Directory setup completed: ${dir}"
    done
}

# ─── Network Functions ───────────────────────────────────────────────────────────
setup_networkmanager() {
    section "Setup Static IPv4 and IPv6 Configuration"
    
    if [[ -f "/etc/netplan/02-pxe.yaml" ]]; then
        log_warn "Back up existing netplan."
        cp "/etc/netplan/02-pxe.yaml" "/etc/netplan/02-pxe.yaml.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi
    
    tee /etc/netplan/02-pxe.yaml > /dev/null << EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    ${PXE_INTERFACE}:
      dhcp4: false
      dhcp6: false
      optional: true
  bridges:
    ${PXE_BRIDGE}:
      interfaces: [${PXE_INTERFACE}]
      addresses:
        - ${PXE_SERVER_IPv4}/${PXE_PREFIX_IPv4}
        - ${PXE_SERVER_IPv6}/${PXE_PREFIX_IPv6}
      parameters:
        stp: false
        forward-delay: 0
      dhcp4: false
      dhcp6: false
EOF
    sed 's/^/[NETPLAN] /' "/etc/netplan/02-pxe.yaml" >> "${RUN_LOG_FILE}"

    log "Apply NetworkManager configuration..."
    chmod 600 /etc/netplan/02-pxe.yaml
    nmcli connection reload || true
    if netplan apply 2>&1 | tee -a "${RUN_LOG_FILE}"; then
        log_pass "NetworkManager setup completed. (PXE Bridge: ${PXE_BRIDGE})"
    else
        log_error "Fail to apply netplan configuration."
    fi
    # sleep 3
    # ip addr show "${PXE_BRIDGE}" | grep -E "inet |inet6 |state" 2>&1 | tee -a "${RUN_LOG_FILE}"
}

setup_dhcp() {
    section "Setup DHCP Server"

    if [[ -f "/etc/dhcp/dhcpd.conf" ]]; then
        log_warn "Back up existing dhcp configuration."
        cp "/etc/dhcp/dhcpd.conf" "/etc/dhcp/dhcpd.conf.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi
    if [[ -f "/etc/dhcp/dhcpd6.conf" ]]; then
        log_warn "Back up existing dhcp6 configuration."
        cp "/etc/dhcp/dhcpd6.conf" "/etc/dhcp/dhcpd6.conf.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi

    tee /etc/dhcp/dhcpd.conf > /dev/null << EOF
# DHCPv4 Configuration
option domain-name "${PXE_DOMAIN_NAME}";
option domain-name-servers ${DNS_SERVER_IPv4};
default-lease-time ${DHCP_LEASE_TIME};
max-lease-time ${DHCP_MAX_LEASE_TIME};
authoritative;

# IPv4 subnet
subnet ${PXE_SUBNET_IPv4} netmask ${PXE_NETMASK_IPv4} {
    range ${PXE_DHCP_RANGE_START_IPv4} ${PXE_DHCP_RANGE_END_IPv4};
    option routers ${PXE_SERVER_IPv4};
    # option broadcast-address ${PXE_SUBNET_IPv4%.*}.255; # dhcpd will automatically calculate based on netmask.
    
    # IPv4 Boot
    next-server ${PXE_SERVER_IPv4};
    
    if exists user-class and option user-class = "iPXE" {
        filename "http://${PXE_SERVER_IPv4}/ipxe/boot.ipxe";
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
    sed 's/^/[DHCP] /' /etc/dhcp/dhcpd.conf >> "${RUN_LOG_FILE}"

    tee /etc/dhcp/dhcpd6.conf > /dev/null << EOF
# DHCPv6 Configuration
log-facility local7;
default-lease-time ${DHCP_LEASE_TIME};
max-lease-time ${DHCP_MAX_LEASE_TIME};

# IPv6 Subnet
subnet6 ${PXE_SUBNET_IPv6}/${PXE_PREFIX_IPv6} {
    range6 ${PXE_DHCP_RANGE_START_IPv6} ${PXE_DHCP_RANGE_END_IPv6};
    option dhcp6.name-servers ${PXE_SERVER_IPv6};

    # PXE Boot over IPv6 (RFC 5970)
    if exists user-class and option user-class = "iPXE" {
        option dhcp6.bootfile-url "http://[${PXE_SERVER_IPv6}]/ipxe/boot.ipxe";
    } elsif option dhcp6.client-arch-type = 00:09 {
        option dhcp6.bootfile-url "tftp://[${PXE_SERVER_IPv6}]/ipxe/ipxe-x86.efi";
    } elsif option dhcp6.client-arch-type = 00:0B {
        option dhcp6.bootfile-url "tftp://[${PXE_SERVER_IPv6}]/ipxe/snp-arm64.efi";
    } else {
        option dhcp6.bootfile-url "tftp://[${PXE_SERVER_IPv6}]/ipxe/undionly-legacy.kpxe";
    }
}
EOF
    sed 's/^/[DHCP6] /' /etc/dhcp/dhcpd6.conf >> "${RUN_LOG_FILE}"

    tee  /etc/default/isc-dhcp-server > /dev/null << EOF
INTERFACESv4="${PXE_BRIDGE}"
INTERFACESv6="${PXE_BRIDGE}"
EOF
    sed 's/^/[isc-dhcp-server] /' "/etc/default/isc-dhcp-server" >> "${RUN_LOG_FILE}"

    log_pass "DHCP setup completed. (PXE Bridge: ${PXE_BRIDGE})"
}

setup_radvd() {
    section "Setup Router Advertisement Daemon (radvd)"

    if [[ -f "/etc/radvd.conf" ]]; then
        log_warn "Back up existing radvd configuration."
        cp "/etc/radvd.conf" "/etc/radvd.conf.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi

    tee /etc/radvd.conf > /dev/null << EOF
interface ${PXE_BRIDGE}
{
    AdvSendAdvert on;
    AdvManagedFlag on;
    AdvOtherConfigFlag on;

    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    prefix ${PXE_SUBNET_IPv6}/${PXE_PREFIX_IPv6}
    {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
    };
};
EOF
    sed 's/^/[radvd] /' /etc/radvd.conf >> "${RUN_LOG_FILE}"
    
    echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-radvd.conf # Modify sysctl to allow forwarding (although PXE Server typically does not forward, radvd sometimes requires this setting to take effect).
    sysctl -p /etc/sysctl.d/99-radvd.conf >> "${RUN_LOG_FILE}" 2>&1

    log_pass "Radvd setup completed."
}

# ─── TFTP Functions ───────────────────────────────────────────────────────────
setup_tftp() {
    section "Setup TFTP Server"

    if [[ -f "/etc/default/tftpd-hpa" ]]; then
        log_warn "Back up existing tftp configuration."
        cp "/etc/default/tftpd-hpa" "/etc/default/tftpd-hpa.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi
    
    tee /etc/default/tftpd-hpa > /dev/null << EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${TFTP_PATH}"
TFTP_ADDRESS="[::]:69"
TFTP_OPTIONS="--secure --verbose"
EOF
    sed 's/^/[TFTP] /' "/etc/default/tftpd-hpa" >> "${RUN_LOG_FILE}"

    log_pass "TFTP setup completed."
}

# ─── iPXE Functions ───────────────────────────────────────────────────────────
build_ipxe() {
    section "Build iPXE from Local Source Code (v1.21.1)"

    local original_dir=$(pwd)
    local ipxe_tarball="ipxe_${IPXE_VERSION}.tgz"
    local ipxe_sha256="ipxe_${IPXE_VERSION}.tgz.sha256"

    cd "${SCRIPT_DIR}/third_party/" || log_error "third_party dir not found."
    # git clone -b v1.21.1 --depth 1 https://github.com/ipxe/ipxe.git ipxe-v1.21.1
    if [ ! -d "ipxe_${IPXE_VERSION}" ]; then
        [ -f "${ipxe_tarball}" ] || log_error "Missing iPXE source archive: ${ipxe_tarball}"
        [ -f "${ipxe_sha256}" ] || log_error "Missing checksum file: ${ipxe_sha256}"
        sha256sum -c "${ipxe_sha256}" || log_error "SHA256 checksum failed for ${ipxe_tarball}"
        tar xzf "${ipxe_tarball}" || log_error "Failed to extract ${ipxe_tarball}"
    fi
    cd "${SCRIPT_DIR}/third_party/ipxe_${IPXE_VERSION}/src" || log_error "iPXE source directory not found."
    
    local ipxe_config="config/general.h"
    # Check ipxe/src/config/general.h enable IPv6
    if grep -q '^[[:space:]]*//\s*#define\s*NET_PROTO_IPV6' "${ipxe_config}"; then
        log_info "Enabling NET_PROTO_IPV6 in ${ipxe_config}..."
        if sed -i 's|^[[:space:]]*//[[:space:]]*#define[[:space:]]\+NET_PROTO_IPV6|#define NET_PROTO_IPV6|' "${ipxe_config}"; then
            log_info "NET_PROTO_IPV6 enabled successfully."
        else
            log_warn "Failed to enable NET_PROTO_IPV6."
        fi
    else
        log_info "NET_PROTO_IPV6 is already enabled or not found."
    fi

    # Check ipxe/src/config/general.h enable PING command
    if grep -q '^[[:space:]]*//\s*#define\s*PING_CMD' "${ipxe_config}"; then
        log_info "Enabling PING_CMD in ${ipxe_config}..."
        if sed -i 's/^[[:space:]]*\/\/#define\s*PING_CMD/#define PING_CMD/' "${ipxe_config}"; then
            log_info "PING_CMD enabled successfully."
        else
            log_warn "Failed to enable PING_CMD."
        fi
    else
        log_info "PING_CMD is already enabled or not found."
    fi

    # Disable autoexec function in script
    ipxe_config="interface/efi/efiprefix.c"
    if grep -q '^[[:space:]]*efi_autoexec_load()' "${ipxe_config}"; then
        log_info "Disabling efi_autoexec_load() in ${ipxe_config}..."
        if sed -i 's/^[[:space:]]*efi_autoexec_load()/\/\/ &/' "${ipxe_config}"; then
            log_info "efi_autoexec_load() disabled successfully."
        else
            log_warn "Failed to disable efi_autoexec_load()."
        fi
    else
        log_info "efi_autoexec_load() is already disabled or not found."
    fi

    make distclean >> "${RUN_LOG_FILE}" 2>&1 || true
    rm -rf /usr/local/lib/ipxe/ 2>/dev/null || true

    log_info "Build iPXE BIOS version (undionly.kpxe)..."
    if ! make bin/undionly.kpxe -j$(nproc) >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_error "Failed to build iPXE BIOS version!"
    fi
    log_info "Build iPXE UEFI version (ipxe.efi with IPv6 support)..."
    if ! make bin-x86_64-efi/ipxe.efi -j$(nproc) >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_error "Failed to build iPXE UEFI version!"
    fi
   
    mkdir -p /usr/local/lib/ipxe
    cp "bin/undionly.kpxe" "/usr/local/lib/ipxe/undionly-legacy.kpxe" 2>&1 | tee -a "${RUN_LOG_FILE}"
    cp "bin-x86_64-efi/ipxe.efi" "/usr/local/lib/ipxe/ipxe-x86.efi"  2>&1 | tee -a "${RUN_LOG_FILE}"

    # ==================== V2.2: aarch64 function ====================
    # log_info "Build iPXE ARM64 UEFI version ..."
    # if ! make bin-arm64-efi/ipxe.efi -j$(nproc) \
    #     CROSS_COMPILE=aarch64-linux-gnu- >> "${RUN_LOG_FILE}" 2>&1; then
    #     log_warn "Failed to build iPXE ARM64 UEFI version!"
    # fi
    # cp "bin-arm64-efi/ipxe.efi" "/usr/local/lib/ipxe/ipxe-arm64.efi" 2>&1 | tee -a "${RUN_LOG_FILE}"

    # Use snp.efi for ARM64 UEFI clients (e.g. Jetson)
    # snp.efi leverages UEFI Simple Network Protocol,
    # which is more compatible than ipxe.efi on ARM platforms.
    log_info "Build iPXE ARM64 UEFI version ..."
    if ! make bin-arm64-efi/snp.efi -j$(nproc) \
        CROSS_COMPILE=aarch64-linux-gnu- >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_warn "Failed to build iPXE ARM64 UEFI version!"
    fi
    cp "bin-arm64-efi/snp.efi" "/usr/local/lib/ipxe/snp-arm64.efi" 2>&1 | tee -a "${RUN_LOG_FILE}"
    # ===============================================================

    cd "${original_dir}"

    log_pass "iPXE setup completed."
}

setup_pxe_files() {
    section "Setup PXE Files"
    
    # config
    cp "${TEMP_CONFIG_PATH}/${PXE_CONFIG_FILE}" "${MAIN_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
    cp "${TEMP_CONFIG_PATH}/${METADATA_FILE}" "${MAIN_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
    log_pass "Config files copy completed."
    
    # iPXE binary files (x86)
    cp "/usr/local/lib/ipxe/undionly-legacy.kpxe" "${TFTP_PATH}/ipxe/" 2>&1 | tee -a "${RUN_LOG_FILE}"
    cp "/usr/local/lib/ipxe/ipxe-x86.efi" "${TFTP_PATH}/ipxe/" 2>&1 | tee -a "${RUN_LOG_FILE}"

    # ==================== V2.2: aarch64 function ====================
    # iPXE binary files (aarch64)
    cp "/usr/local/lib/ipxe/snp-arm64.efi" "${TFTP_PATH}/ipxe/" 2>&1 | tee -a "${RUN_LOG_FILE}"
    # ===============================================================

    # SYSLUNUX modules
    cp /usr/lib/syslinux/modules/bios/*.c32 "${TFTP_PATH}/bios" 2>&1 | tee -a "${RUN_LOG_FILE}"
    cp "/usr/lib/SYSLINUX.EFI/efi64/syslinux.efi" "${TFTP_PATH}/efi" 2>&1 | tee -a "${RUN_LOG_FILE}"

    log_pass "iPXE related files copy completed."
    
    # EFI shell files
    if [[ -f "${SCRIPT_DIR}/assets/efi/BOOT/Shellx64.efi" ]]; then
        cp -r "assets/efi/BOOT/" "${TFTP_PATH}/efi/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        log_pass "EFI Shell setup completed."
    else
        log_warn "EFI shell files not found! EFI shell Will not be installed in PXE system."
        log_warn "Manually install: sudo cp /path/to/you/efi/ ${TFTP_PATH}/efi"
    fi
    
    # WinPE files
    if [[ -f "${SCRIPT_DIR}/assets/winpe/tftp/winpe/wimboot" ]]; then
        cp -r "assets/winpe/tftp/winpe" "${TFTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        cp -r "assets/winpe/http/winpe" "${HTTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        if grep -Eq "<IP>|<SMB_MOUNT_POINT\?>" ${HTTP_PATH}/winpe/startup.bat; then
            log_warn "You should modify ${HTTP_PATH}/winpe/startup.bat to mount your SMB server; otherwise, WinPE may break"
        fi
        log_pass "WinPE env setup completed."
    else
        log_warn "WinPE files not found! WinPE env Will not be installed in PXE system."
        log_warn "Manually copy WinPE related files in ${TFTP_PATH}/winpe and ${HTTP_PATH}/winpe"
    fi
    
    # Ghost files for WinPE
    if [[ -f "${SCRIPT_DIR}/assets/ghost/Ghost/12.0.0.10618/ghost64.dmp" ]]; then
        cp -r "${SCRIPT_DIR}"/assets/ghost/* "${HTTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        log_pass "Ghost in WinPE env setup completed. You can execute Ghost.bat to launch Ghost in WinPE."
    else
        log_warn "Ghost files not found! Ghost Will not be installed in PXE system."
        log_warn "Manually install: sudo cp /path/to/you/Ghost/ ${HTTP_PATH}/Ghost"
    fi


    if [[ -f "${BIN_PATH}/pxe_umount_iso.sh" ]]; then 
        log_warn "Remove already mounted iso first."
        "${BIN_PATH}/pxe_umount_iso.sh" >> "${RUN_LOG_FILE}" 2>&1
    fi

    chown -R tftp:tftp "${TFTP_PATH}"
    chown -R www-data:www-data "${HTTP_PATH}"
    chmod -R 755 "${MAIN_PATH}"

    log_pass "PXE files setup completed."
}

create_ipxe_menu() {
    # NOTE: Menu entries are hardcoded for the bundled ISO set in assets/iso/.
    # If you replace ISOs, please update :ubuntu-24.04.3 / :ubuntu-22.04.5 sections.

    section "Setup PXE Boot Menu"
    
    tee ${TFTP_PATH}/ipxe/boot.ipxe > /dev/null << EOF
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
chain tftp://\${pxeip}/efi/boot/Shellx64.efi

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

    chown tftp:tftp ${TFTP_PATH}/ipxe/boot.ipxe
    chmod 755 ${TFTP_PATH}/ipxe/boot.ipxe
    sed 's/^/[iPXE Menu] /' ${TFTP_PATH}/ipxe/boot.ipxe >> "${RUN_LOG_FILE}"

    log_pass "PXE menu setup completed."
}

# ─── Apache Functions ───────────────────────────────────────────────────────────
setup_apache() {
    section "Setup Apache Web Server"
    
    if [[ -f "/etc/apache2/sites-available/pxe_apache.conf" ]]; then
        log_warn "Back up existing apache configuration."
        cp "/etc/apache2/sites-available/pxe_apache.conf" "/etc/apache2/sites-available/pxe_apache.conf.backup.${RUN_ID}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    fi
    
    tee /etc/apache2/sites-available/pxe_apache.conf > /dev/null << EOF
<VirtualHost *:80 [::]:80>
    DocumentRoot ${HTTP_PATH}
    
    <Directory ${HTTP_PATH}>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    
    Alias /ipxe ${TFTP_PATH}/ipxe
    <Directory ${TFTP_PATH}/ipxe>
        Options Indexes
        AllowOverride None
        Require all granted
    </Directory>
    
    Alias /iso ${ISO_PATH}
    <Directory ${ISO_PATH}>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF
    sed 's/^/[Apache2] /' /etc/apache2/sites-available/pxe_apache.conf >> "${RUN_LOG_FILE}"

    # enable site and modules
    a2ensite pxe_apache.conf 2>&1 | tee -a "${RUN_LOG_FILE}"
    a2dissite 000-default.conf 2>/dev/null || true
    a2enmod headers 2>&1 | tee -a "${RUN_LOG_FILE}"
    systemctl reload apache2 2>&1 | tee -a "${RUN_LOG_FILE}"
    systemctl daemon-reload 2>&1 | tee -a "${RUN_LOG_FILE}"

    # test apache configuration
    apache2ctl configtest 2>&1 | tee -a "${RUN_LOG_FILE}"

    log_pass "Apache setup completed."
}

# ─── Scripts And Systemd Functions ───────────────────────────────────────────────────────────
create_helper_scripts() {
    section "Setup Scripts"

    cp "${SCRIPT_DIR}"/scripts/* ${BIN_PATH} 2>&1 | tee -a "${RUN_LOG_FILE}"
    chmod +x "${BIN_PATH}"/*.sh 2>&1 | tee -a "${RUN_LOG_FILE}"

    log_pass "Scripts setup completed."
}

setup_services() {
    section "Setup Systemd Services"
    
    # log "Force cleanup old masked unit if exists..."
    # rm -f /etc/systemd/system/pxe-mount.service
    # rm -f /etc/systemd/system/pxe-tftp-on-link.service
    # systemctl unmask pxe-mount.service pxe-tftp-on-link.service >> "${RUN_LOG_FILE}" 2>&1 || true

    # auto-mount service when boot up
    tee /etc/systemd/system/pxe-mount.service > /dev/null << EOF 
[Unit]
Description=PXE ISO Auto Mount Service
After=network.target apache2.service
Requires=apache2.service

[Service]
Type=oneshot
ExecStart=${BIN_PATH}/pxe_mount_iso.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sed 's/^/[pxe-mount.service] /' /etc/systemd/system/pxe-mount.service >> "${RUN_LOG_FILE}"

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
    sed 's/^/[pxe-tftp-on-link.service] /' /etc/systemd/system/pxe-tftp-on-link.service >> "${RUN_LOG_FILE}"

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
    sed 's/^/[start-dhcp-on-link] /' /etc/networkd-dispatcher/routable.d/start-dhcp-on-link >> "${RUN_LOG_FILE}"

    systemctl daemon-reload 
    local services=(pxe-mount.service pxe-tftp-on-link.service apache2 tftpd-hpa isc-dhcp-server isc-dhcp-server6 radvd)
    for var in "${services[@]}"; do
        systemctl enable "${var}" 2>&1 | tee -a "${RUN_LOG_FILE}"
        if ! systemctl start "${var}" 2>&1 | tee -a "${RUN_LOG_FILE}"; then
            log_warn "${var} failed to start"
            log_warn "Please use command below to restart the service when you connect the PXE interface."
            log_warn "   $ sudo systemctl restart ${var}"
        fi
    done

    log_pass "Services setup completed"
}

# ─── ISO Functions ───────────────────────────────────────────────────────────
mount_iso() {
    section "Mount Existing ISO Files"
    
    # if [ -d "${ISO_PATH}" ] && [ "$(ls -A ${ISO_PATH}/*.iso 2>/dev/null)" ]; then
    if compgen -G "${ISO_PATH}/*.iso" > /dev/null; then

        export ISO_PATH
        export HTTP_PATH
        export RUN_LOG_FILE
        
        "${BIN_PATH}/pxe_mount_iso.sh" 2>&1 | tee -a "${RUN_LOG_FILE}"
        
        log_pass "ISO mount process completed."
    else
        log_warn "No ISO files found in ${ISO_PATH}"
        log_warn "Please add your ISO files in ${ISO_PATH} and execute following command:"
        log_warn "  sudo ${BIN_PATH}/pxe_mount_iso.sh"
    fi
}

umount_iso() {
    section "Unmount Existing ISO Files"


    export HTTP_PATH
    export RUN_LOG_FILE
    
    if [[ ! -x "${BIN_PATH}/pxe_umount_iso.sh" ]]; then
        log_warn "Umount script not found, skipping..."
    #TODO 檔案必定存在
    elif "${BIN_PATH}/pxe_umount_iso.sh" 2>&1 | tee -a "${RUN_LOG_FILE}"; then
        log_pass "ISO unmount process completed."
    else
        log_error "ISO unmount failed."
    fi
}

# ─── Final Chcek ───────────────────────────────────────────────────────────
final_status() {
    log ""
    cat << EOF | tee -a "${RUN_LOG_FILE}"
========================================================
    ${PRODUCT_NAME} Setup Complete! 
========================================================
EOF
    log "Build PXE Script Version: ${VERSION}"
    log "OS: ${DISTRO} (${KERNEL})"

    log "Service Status:"
    local services=(pxe-mount.service pxe-tftp-on-link.service apache2 tftpd-hpa isc-dhcp-server isc-dhcp-server6 radvd)
    for var in "${services[@]}"; do
        if systemctl is-active --quiet "$var"; then
            log "${var}: active"
        else
            log_warn "${var}: failed" 2>&1 | tee -a "${RUN_LOG_FILE}"
            systemctl status $var 2>&1 | tee -a "${RUN_LOG_FILE}"
        fi
    done
    
    log ""
    log "Network Configuration: ${PXE_BRIDGE}"
    ip addr show "${PXE_BRIDGE}" | grep -E "inet |inet6 |state" 2>&1 | tee -a "${RUN_LOG_FILE}"
    ip addr show "${PXE_INTERFACE}" | grep -E "inet |inet6 |state" 2>&1 | tee -a "${RUN_LOG_FILE}"

    log ""
    log "Test URLs:"
    log "  > IPv4 HTTP: http://${PXE_SERVER_IPv4}/"
    log "  > IPv4 iPXE: http://${PXE_SERVER_IPv4}/ipxe/boot.ipxe"
    log "  > IPv6 HTTP: http://[${PXE_SERVER_IPv6}]/"
    log "  > IPv6 iPXE: http://[${PXE_SERVER_IPv6}]/ipxe/boot.ipxe"
    log "  > TFTP Root: ${TFTP_PATH}"
    log "  > HTTP Root: ${HTTP_PATH}"
    log ""
    log "All Setup Logs Saved to: ${RUN_LOG_DIR}"
    log ""

    END_TS=$(date +%s)
    ELAPSED=$((END_TS - RUN_TS))
    H=$((ELAPSED / 3600))
    M=$(( (ELAPSED % 3600) / 60 ))
    S=$((ELAPSED % 60))

    printf -v DURATION "%02d:%02d:%02d" "$H" "$M" "$S"
    log "Spend Time: $DURATION"

    cat << EOF | tee -a "${RUN_LOG_FILE}" 
========================================================
EOF
}

# ─── Uninstall ───────────────────────────────────────────────────────────
uninstall() {
    # shellcheck disable=SC1091
    source "${MAIN_PATH}/${PXE_CONFIG_FILE}" || log_error "Failed to load ${MAIN_PATH}/${PXE_CONFIG_FILE}"

    if [[ ! -f ${MAIN_PATH}/${PXE_CONFIG_FILE} ]]; then
        log_error "${MAIN_PATH}/${PXE_CONFIG_FILE} not found. Cannot determine PXE paths for safe uninstall."
    fi    
    
    for v in HTTP_PATH TFTP_PATH BIN_PATH LOG_PATH; do
        if [[ -z "${!v:-}" || "${!v}" == "/" ]]; then
            log_error "Variable $v is empty or unsafe. Aborting uninstall."
        fi
    done
    
    if [[ -d "${LOG_PATH}" ]]; then
        RUN_LOG_FILE="${LOG_PATH}/pxe_uninstall_${RUN_ID}.log"
    fi

    section "Uninstall PXE Server"

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
            systemctl stop "$var" >> "${RUN_LOG_FILE}" 2>&1 || log_warn "Failed to stop $var"
        fi
        if systemctl is-enabled --quiet "$var" 2>/dev/null; then
            log "Disabling $var..."
            systemctl disable "$var" >> "${RUN_LOG_FILE}" 2>&1 || log_warn "Failed to disable $var"
        fi
    done

    rm -f /etc/netplan/02-pxe.yaml* ; netplan apply >> "${RUN_LOG_FILE}" 2>&1 || log_warn "Failed to apply netplan"
    rm -f /etc/dhcp/dhcpd.conf* >> "${RUN_LOG_FILE}" 2>&1 
    rm -f /etc/dhcp/dhcpd6.conf* >> "${RUN_LOG_FILE}" 2>&1
    rm -f /etc/radvd.conf* >> "${RUN_LOG_FILE}" 2>&1
    rm -f /etc/default/tftpd-hpa* >> "${RUN_LOG_FILE}" 2>&1
    if [[ -d "/usr/local/lib/ipxe" ]]; then rm -rf /usr/local/lib/ipxe/ >> "${RUN_LOG_FILE}" 2>&1; fi
    a2dissite pxe_apache.conf 2>&1 | tee -a "${RUN_LOG_FILE}"
    rm -f /etc/apache2/sites-available/pxe_apache.conf* >> "${RUN_LOG_FILE}" 2>&1
    a2ensite 000-default.conf 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to enable Apache site 000-default.conf"
    systemctl daemon-reload 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to reload systemd daemon"
    systemctl reload apache2 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to reload Apache"
    rm -f /etc/systemd/system/pxe-mount.service >> "${RUN_LOG_FILE}" 2>&1
    rm -f /etc/systemd/system/pxe-tftp-on-link.service >> "${RUN_LOG_FILE}" 2>&1
    rm -f /etc/networkd-dispatcher/routable.d/start-dhcp-on-link >> "${RUN_LOG_FILE}" 2>&1
    if [[ -d ${MAIN_PATH} ]]; then
        rm -f "${MAIN_PATH}/${PXE_CONFIG_FILE}" 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to remove ${MAIN_PATH}/${PXE_CONFIG_FILE}"
        rm -rf "${HTTP_PATH}"/* 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to remove ${HTTP_PATH}"
        rm -rf "${TFTP_PATH}"/* 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to remove ${TFTP_PATH}"
        rm -rf "${BIN_PATH}"/* 2>&1 | tee -a "${RUN_LOG_FILE}" || log_warn "Failed to remove ${BIN_PATH}"
    fi

    log_pass "Remove PXE server done!"
    log ""

    read -r -p "Do you want to reboot now? Y/[N]: " REPLY
    echo
    REPLY="${REPLY:-N}"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "System will reboot in 5 seconds..."
        sleep 5
        reboot
    else
        log_info "Please reboot manually to complete the uninstallation."
    fi
}

usage() {
    cat >&2 <<EOF
${PRODUCT_NAME} (${VERSION})

Usage: sudo $0 [OPTIONS]

Options:
  (NULL)                Install PXE ${VERSION}
  -h, --help            Show this help message and exit
  -r, --remove, --uninstall
                        Uninstall PXE server and remove all configurations
  -m, --mount           Only mount ISO files (call pxe_mount_iso.sh)
  -u, --umount          Only unmount ISO files (call pxe_umount_iso.sh)
  --no-ipxe-build       Skip iPXE build (use existing binaries)

Examples:
  sudo $0               # Full PXE server installation
  sudo $0 --uninstall   # Remove PXE server and all files
  sudo $0 --mount       # Only mount ISO files from ISO_PATH
EOF
}

main() {
    check_execution_context
    cleanup
    check_os_info
    load_metadata

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -r|--remove|--uninstall)
                echo; echo "Do You want to uninstall PXE server?"
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
                load_pxe_config
                mount_iso
                exit 0
                ;;
            -u|--umount)
                load_pxe_config
                umount_iso
                exit 0
                ;;
            --no-ipxe-build)
                SKIP_IPXE_BUILD=true
                ;;
            *)
                log_error "Invalid input: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    load_pxe_config

    echo; echo "\nDo you want to install PXE server?"
    echo "   [Y] Yes (Default) [N] No "
    read -r REPLY
    REPLY="${REPLY:-Y}"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborting install."
        exit 1
    fi 

    log "Starting PXE Server Setup in 3 seconds..."
    sleep 3

    show_welcome_info  
    install_dependency
    setup_firewall
    setup_dir
    setup_networkmanager
    setup_dhcp
    setup_radvd
    setup_tftp
    [[ "$SKIP_IPXE_BUILD" != true ]] && build_ipxe
    setup_apache
    setup_pxe_files
    create_ipxe_menu
    create_helper_scripts
    setup_services
    mount_iso
    final_status
    log "PXE Server setup completed successfully!"
}
main "$@"