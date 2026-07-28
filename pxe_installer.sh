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
TEMP_CONFIG_PATH="${SCRIPT_DIR}/config"
INSTALLED_CONFIG_PATH="${MAIN_PATH}/config"

PXE_CONFIG_FILE="pxe.conf"
METADATA_FILE="metadata.env"
MANAGED_FILES_SOURCE="${TEMP_CONFIG_PATH}/managed_files.list"
DEFAULT_PXE_CONFIG="${TEMP_CONFIG_PATH}/pxe.conf"
# Reserved for future feature:
# EXAMPLE_PXE_CONFIG="${TEMP_CONFIG_PATH}/pxe.conf.example"


ACTION=""
# Reserved for future feature:
# RUN_MODE="repository" # interactive, run-package
#TODO
# 由 .run 的啟動 wrapper 設為 1, TODO
# PXE_RUN_MODE="${PXE_RUN_MODE:-0}"
CONFIG_FILE=""
ACTIVE_CONFIG_FILE=""

SKIP_IPXE_BUILD=false

# Reserved for future feature:
# GENERATED_CONFIG_FILE=""

# ─── Output helpers ───────────────────────────────────────────────────────────
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# Reserved for future feature:
# cleanup() {
#     if [[ -n "${GENERATED_CONFIG_FILE:-}" && -f "${GENERATED_CONFIG_FILE}" ]]; then
#         rm -f "${GENERATED_CONFIG_FILE}"
#     fi
# }
# trap cleanup EXIT

log() {
    local message="$1"
    local timestamp 
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
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}" | sed 's/\x1b\[[0-9;]*m//g' >> "${RUN_LOG_FILE}"
}

# ─── Pre-check Functions ───────────────────────────────────────────────────────────
check_execution_context() {
    section "Execution Context Check"

    local script_name
    script_name=$(basename "$0")
    
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

    local repository_metadata="${TEMP_CONFIG_PATH}/${METADATA_FILE}"
    local installed_metadata="${INSTALLED_CONFIG_PATH}/${METADATA_FILE}"
    local metadata_file=""

    if [[ -f "${repository_metadata}" ]]; then
        metadata_file="${repository_metadata}"
    elif [[ -f "${installed_metadata}" ]]; then
        metadata_file="${installed_metadata}"
    else
        log_error \
            "Metadata file not found: ${repository_metadata} or ${installed_metadata}"
    fi
    
    # shellcheck source=config/metadata.env
    source "${metadata_file}"
    log_pass "Metadata load completed."
}

load_pxe_config() {
    section "Load PXE Config"

     case "${ACTION}" in
        install)
            ACTIVE_CONFIG_FILE="${CONFIG_FILE:-${DEFAULT_PXE_CONFIG}}"
            ;;

        uninstall|mount|umount)
            ACTIVE_CONFIG_FILE="${INSTALLED_CONFIG_PATH}/${PXE_CONFIG_FILE}"
            ;;

        *)
            log_error "PXE configuration is not required for action: ${ACTION}"
            ;;
    esac

    [[ -f "${ACTIVE_CONFIG_FILE}" ]] || \
        log_error "Configuration file not found: ${ACTIVE_CONFIG_FILE}"

    # The runtime config has the same schema as pxe.conf.example.
    # shellcheck source=config/pxe.conf.example
    source "${ACTIVE_CONFIG_FILE}"

    RUN_LOG_DIR="${LOG_PATH}/pxe_manager_${RUN_ID}"

    case "${ACTION}" in
        install)
            RUN_LOG_FILE="${RUN_LOG_DIR}/installer.log"
            ;;
        uninstall)
            RUN_LOG_FILE="${RUN_LOG_DIR}/uninstall.log"
            ;;
        mount)
            RUN_LOG_FILE="${RUN_LOG_DIR}/mount_iso.log"
            ;;
        umount)
            RUN_LOG_FILE="${RUN_LOG_DIR}/umount_iso.log"
            ;;
    esac

    APT_LOG="${RUN_LOG_DIR}/apt.log"
    IPXE_BUILD_LOG="${RUN_LOG_DIR}/ipxe_build.log"

    mkdir -p "${RUN_LOG_DIR}"
    if [[ -f "${RUN_TEMP_LOG}" ]]; then
        cat "${RUN_TEMP_LOG}" >> "${RUN_LOG_FILE}"
        rm -f "${RUN_TEMP_LOG}"
    fi
    
    log_pass "PXE config loaded from: ${ACTIVE_CONFIG_FILE}"
    log_pass "Logs save to: ${RUN_LOG_FILE}"
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
    Date/Time: $(LC_ALL=C date '+%Y-%m-%d %H:%M:%S $Z')
========================================================
EOF
}

install_dependency() {
    section "Install Dependency"

    apt update >> "${APT_LOG}" 2>&1
    apt install -y isc-dhcp-server tftpd-hpa tftp-hpa apache2 \
        syslinux-common syslinux-efi syslinux git gcc binutils \
        make perl liblzma-dev mtools genisoimage \
        isolinux tree curl \
        libssl-dev ndisc6 radvd \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        nfs-kernel-server >> "${APT_LOG}" 2>&1    

    log_pass "Dependency install completed."
}

backup_original_state() {
    section "Back Up Original System State"

    local state_manifest="${STATE_PATH}/managed_files.list"
    local target
    local relative_path
    local backup_path
    local absent_marker
    local service

    # Reinstallation must not overwrite the first installation state.
    if [[ -f "${STATE_PATH}/recorded" ]]; then
        log_info "Original system state is already recorded. Skip."
        return 0
    fi
    [[ -f "${MANAGED_FILES_SOURCE}" ]] || log_error "Managed files list not found: ${MANAGED_FILES_SOURCE}"

    mkdir -p \
        "${STATE_PATH}/original" \
        "${STATE_PATH}/absent" \
        "${STATE_PATH}/apache" \
        "${STATE_PATH}/services"
    chmod 700 "${STATE_PATH}"

    # Save the exact file list used by this installation.
    [[ ! -f "${state_manifest}" ]] && install -m 600 "${MANAGED_FILES_SOURCE}" "${state_manifest}"
    
    while IFS='' read -r target || [[ -n "${target}" ]]; do
        # Ignore empty lines and comments.
        [[ -z "${target}" ]] && continue
        [[ "${target}" =~ ^[[:space:]]*# ]] && continue

        # Only allow absolute paths.
        [[ "${target}" == /* ]] || \
            log_error "Invalid managed file path: ${target}"

        relative_path="${target#/}"
        backup_path="${STATE_PATH}/original/${relative_path}"
        absent_marker="${STATE_PATH}/absent/${relative_path}"

        # Preserve completed entries if a previous backup was interrupted.
        if [[ -e "${backup_path}" ||
              -L "${backup_path}" ||
              -e "${absent_marker}" ]]; then
            continue
        fi

        if [[ -e "${target}" || -L "${target}" ]]; then
            mkdir -p "$(dirname "${backup_path}")"

            cp -a -- "${target}" "${backup_path}" || \
                log_error "Failed to back up: ${target}"

            log_pass "Backed up: ${target}"
        else
            mkdir -p "$(dirname "${absent_marker}")"
            : > "${absent_marker}"

            log_info "Originally absent: ${target}"
        fi
    done < "${state_manifest}"

    # Record Apache default site state.
    if [[ -e "/etc/apache2/sites-enabled/000-default.conf" ]]; then
        printf '%s\n' "enabled" \
            > "${STATE_PATH}/apache/default-site"
    else
        printf '%s\n' "disabled" \
            > "${STATE_PATH}/apache/default-site"
    fi

    # Record PXE Apache site state in case the same site existed previously.
    if [[ -e "/etc/apache2/sites-enabled/pxe_apache.conf" ]]; then
        printf '%s\n' "enabled" \
            > "${STATE_PATH}/apache/pxe-site"
    else
        printf '%s\n' "disabled" \
            > "${STATE_PATH}/apache/pxe-site"
    fi

    # Record Apache headers module state.
    if [[ -e "/etc/apache2/mods-enabled/headers.load" ]]; then
        printf '%s\n' "enabled" \
            > "${STATE_PATH}/apache/headers-module"
    else
        printf '%s\n' "disabled" \
            > "${STATE_PATH}/apache/headers-module"
    fi

    # These services may be started by the installation.
    local tracked_services=(
        "apache2.service"
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "tftpd-hpa.service"
        "radvd.service"
        "pxe-mount.service"
    )

    for service in "${tracked_services[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            printf '%s\n' "active" \
                > "${STATE_PATH}/services/${service}.active"
        else
            printf '%s\n' "inactive" \
                > "${STATE_PATH}/services/${service}.active"
        fi
    done

    # Only pxe-mount.service is explicitly enabled by this project.
    if systemctl is-enabled --quiet pxe-mount.service 2>/dev/null; then
        printf '%s\n' "enabled" \
            > "${STATE_PATH}/services/pxe-mount.service.enabled"
    else
        printf '%s\n' "disabled" \
            > "${STATE_PATH}/services/pxe-mount.service.enabled"
    fi

    : > "${STATE_PATH}/recorded"
    chmod -R go-rwx "${STATE_PATH}"

    log_pass "Original system state recorded in: ${STATE_PATH}"
}

setup_firewall() {
    section "Check Firewall Status"

    local status=""

    if command -v ufw >/dev/null 2>&1; then
        status="$(ufw status | head -n1 | cut -d':' -f2- | xargs)"
        log_info "Firewall Status: ${status}"
        log_warn "Skip firewall setup."
        log_warn "Firewall setup is disabled in this version (${VERSION})."
        log_warn "Make sure this server is in a trusted network environment."
    else
        log_warn "UFW is not installed."
    fi

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
        "${INSTALLED_CONFIG_PATH}"
        "${HTTP_PATH}"
        "${TFTP_PATH}"/{ipxe,efi,bios}
        "${BIN_PATH}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}" || log_error "Failed to create directory: ${dir}"
        log_pass "Directory setup completed: ${dir}"
    done
}

setup_config() {
    section "Setup Essential Config"

    install -m 600 "${ACTIVE_CONFIG_FILE}" "${INSTALLED_CONFIG_PATH}/${PXE_CONFIG_FILE}"
    install -m 644 "${TEMP_CONFIG_PATH}/${METADATA_FILE}" "${INSTALLED_CONFIG_PATH}/${METADATA_FILE}"
    install -m 755 "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" "${MAIN_PATH}/pxe_installer.sh"

    log_pass "Essential files setup completed."
}

# ─── Network Functions ───────────────────────────────────────────────────────────
setup_networkmanager() {
    section "Setup Static IPv4 and IPv6 Configuration"
    
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

    chmod 600 /etc/netplan/02-pxe.yaml
    nmcli connection reload || true
    if netplan apply 2>&1 | tee -a "${RUN_LOG_FILE}"; then
        log_pass "NetworkManager setup completed. (PXE Bridge: ${PXE_BRIDGE})"
    else
        log_error "Fail to apply netplan configuration."
    fi
}

setup_dhcp() {
    section "Setup DHCP Server"

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
    
    # Enable IPv6 forwarding for router advertisement environment.
    # Required in some configurations when using radvd.
    echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-pxe-ipv6.conf
    if sysctl --system >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "IPv6 forwarding configuration applied."
    else
        log_warn "Failed to apply IPv6 forwarding configuration."
    fi

    log_pass "Radvd setup completed."
}

# ─── TFTP Functions ───────────────────────────────────────────────────────────
setup_tftp() {
    section "Setup TFTP Server"
 
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

    local original_dir
    original_dir=$(pwd)
    local ipxe_tarball="ipxe_${IPXE_VERSION}.tgz"
    local ipxe_sha256="ipxe_${IPXE_VERSION}.tgz.sha256"

    cd "${SCRIPT_DIR}/third_party/" || log_error "third_party dir not found."
    # git clone -b v1.21.1 --depth 1 https://github.com/ipxe/ipxe.git ipxe-v1.21.1
    if [ ! -d "ipxe_${IPXE_VERSION}" ]; then
        [ -f "${ipxe_tarball}" ] || log_error "Missing iPXE source archive: ${ipxe_tarball}"
        [ -f "${ipxe_sha256}" ] || log_error "Missing checksum file: ${ipxe_sha256}"
        if sha256sum -c --quiet "${ipxe_sha256}" >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "iPXE source checksum verified."
        else
            log_error "SHA256 checksum failed for ${ipxe_tarball}"
        fi
        if tar xzf "${ipxe_tarball}" >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "iPXE source extracted."
        else
            log_error "Failed to extract ${ipxe_tarball}"
        fi
    fi
    cd "${SCRIPT_DIR}/third_party/ipxe_${IPXE_VERSION}/src" || log_error "iPXE source directory not found."
    
    local ipxe_config="config/general.h"
    # Check ipxe/src/config/general.h enable IPv6
    if grep -q '^[[:space:]]*//\s*#define\s*NET_PROTO_IPV6' "${ipxe_config}"; then
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
        if sed -i 's/^[[:space:]]*efi_autoexec_load()/\/\/ &/' "${ipxe_config}"; then
            log_info "efi_autoexec_load() disabled successfully."
        else
            log_warn "Failed to disable efi_autoexec_load()."
        fi
    else
        log_info "efi_autoexec_load() is already disabled or not found."
    fi

    make distclean >> "${IPXE_BUILD_LOG}" 2>&1 || true
    # rm -rf /usr/local/lib/ipxe/ 2>/dev/null || true

    log_info "Build iPXE BIOS version (undionly.kpxe)"
    if ! make bin/undionly.kpxe -j"$(nproc)" >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_error "Failed to build iPXE BIOS version!"
    fi
    log_info "Build iPXE UEFI version (ipxe.efi with IPv6 support)"
    if ! make bin-x86_64-efi/ipxe.efi -j"$(nproc)" >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_error "Failed to build iPXE UEFI version!"
    fi
   
    mkdir -p /usr/local/lib/ipxe
    cp "bin/undionly.kpxe" "/usr/local/lib/ipxe/undionly-legacy.kpxe" 2>&1 | tee -a "${RUN_LOG_FILE}"
    cp "bin-x86_64-efi/ipxe.efi" "/usr/local/lib/ipxe/ipxe-x86.efi"  2>&1 | tee -a "${RUN_LOG_FILE}"

    # ==================== V2.2: aarch64 function ====================
    # log_info "Build iPXE ARM64 UEFI version"
    # if ! make bin-arm64-efi/ipxe.efi -j"$(nproc)" \
    #     CROSS_COMPILE=aarch64-linux-gnu- >> "${IPXE_BUILD_LOG}" 2>&1; then
    #     log_warn "Failed to build iPXE ARM64 UEFI version!"
    # fi
    # cp "bin-arm64-efi/ipxe.efi" "/usr/local/lib/ipxe/ipxe-arm64.efi" 2>&1 | tee -a "${RUN_LOG_FILE}"

    # Use snp.efi for ARM64 UEFI clients (e.g. Jetson)
    # snp.efi leverages UEFI Simple Network Protocol,
    # which is more compatible than ipxe.efi on ARM platforms.
    log_info "Build iPXE ARM64 UEFI version"
    if ! make bin-arm64-efi/snp.efi -j"$(nproc)" \
        CROSS_COMPILE=aarch64-linux-gnu- >> "${IPXE_BUILD_LOG}" 2>&1; then
        log_error "Failed to build iPXE ARM64 UEFI version!"
    fi
    cp "bin-arm64-efi/snp.efi" "/usr/local/lib/ipxe/snp-arm64.efi" 2>&1 | tee -a "${RUN_LOG_FILE}"
    # ===============================================================

    cd "${original_dir}"

    log_pass "iPXE setup completed."
}

setup_pxe_files() {
    section "Setup PXE Files"
    

    local required_ipxe_files=(
        "/usr/local/lib/ipxe/undionly-legacy.kpxe"
        "/usr/local/lib/ipxe/ipxe-x86.efi"
        "/usr/local/lib/ipxe/snp-arm64.efi"
    )
    local file

    for file in "${required_ipxe_files[@]}"; do
        [[ -f "${file}" ]] || \
            log_error "Required iPXE binary not found: ${file}"
    done

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
        cp -r "${SCRIPT_DIR}/assets/efi/BOOT/" "${TFTP_PATH}/efi/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        log_pass "EFI Shell setup completed."
    else
        log_warn "EFI shell files not found! EFI shell Will not be installed in PXE system."
        log_warn "Manually install: sudo cp /path/to/you/efi/ ${TFTP_PATH}/efi"
    fi
    
    # WinPE files
    if [[ -f "${SCRIPT_DIR}/assets/winpe/tftp/winpe/wimboot" ]]; then
        cp -r "${SCRIPT_DIR}/assets/winpe/tftp/winpe" "${TFTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        cp -r "${SCRIPT_DIR}/assets/winpe/http/winpe" "${HTTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        if grep -Eq "<IP>|<SMB_MOUNT_POINT\?>" "${HTTP_PATH}/winpe/startup.bat"; then
            log_warn "You should modify ${HTTP_PATH}/winpe/startup.bat to mount your SMB server; otherwise, WinPE may break"
        fi
        log_pass "WinPE env setup completed."
    else
        log_warn "WinPE files not found! WinPE env will not be installed in PXE system."
        log_warn "Manually copy WinPE related files in ${TFTP_PATH}/winpe and ${HTTP_PATH}/winpe"
    fi
    
    # Ghost files for WinPE
    if [[ -f "${SCRIPT_DIR}/assets/ghost/Ghost/12.0.0.10618/ghost64.dmp" ]]; then
        cp -r "${SCRIPT_DIR}"/assets/ghost/* "${HTTP_PATH}/" 2>&1 | tee -a "${RUN_LOG_FILE}"
        log_pass "Ghost in WinPE env setup completed. You can execute Ghost.bat to launch Ghost in WinPE."
    else
        log_warn "Ghost files not found! Ghost will not be installed in PXE system."
        log_warn "Manually install: sudo cp /path/to/you/Ghost/ ${HTTP_PATH}/Ghost"
    fi

    chown tftp:tftp "${TFTP_PATH}"
    chown www-data:www-data "${HTTP_PATH}"

    chmod 755 "${MAIN_PATH}"
    chmod 755 "${HTTP_PATH}" "${TFTP_PATH}" "${BIN_PATH}" "${INSTALLED_CONFIG_PATH}"
    chmod 600 "${INSTALLED_CONFIG_PATH}/${PXE_CONFIG_FILE}"
    chmod 644 "${INSTALLED_CONFIG_PATH}/${METADATA_FILE}"
    [[ -d "${STATE_PATH}" ]] && chmod -R go-rwx "${STATE_PATH}"
    
    log_pass "PXE files setup completed."
}

create_ipxe_menu() {
    # NOTE: Menu entries are hardcoded for the bundled ISO set in assets/iso/.
    # If you replace ISOs, please update :ubuntu-24.04.3 / :ubuntu-22.04.5 sections.

    section "Setup PXE Boot Menu"
    
    tee "${TFTP_PATH}/ipxe/boot.ipxe" > /dev/null << EOF
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

    chown tftp:tftp "${TFTP_PATH}/ipxe/boot.ipxe"
    chmod 755 "${TFTP_PATH}/ipxe/boot.ipxe"
    sed 's/^/[iPXE Menu] /' "${TFTP_PATH}/ipxe/boot.ipxe" >> "${RUN_LOG_FILE}"

    log_pass "PXE menu setup completed."
}

# ─── Apache Functions ───────────────────────────────────────────────────────────
setup_apache() {
    section "Setup Apache Web Server"
    
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
    if a2ensite pxe_apache.conf >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Apache site enabled."
    else
        log_error "Failed to enable Apache site."
    fi

    a2dissite 000-default.conf >> "${RUN_LOG_FILE}" 2>&1 || true

    if a2enmod headers >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Apache headers module enabled."
    else
        log_error "Failed to enable Apache headers module."
    fi

    # test apache configuration
    if apache2ctl configtest >> "${RUN_LOG_FILE}" 2>&1; then
        if systemctl is-active --quiet apache2; then
            if systemctl reload apache2 >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Apache configuration reloaded."
            else
                log_error "Failed to reload Apache."
            fi
        else
            if systemctl start apache2 >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Apache service started."
            else
                log_error "Failed to start Apache."
            fi
        fi

        log_pass "Apache setup completed."
    else
        log_error "Apache configuration test failed."
    fi
}

# ─── Scripts And Systemd Functions ───────────────────────────────────────────────────────────
create_helper_scripts() {
    section "Setup Scripts"

    cp "${SCRIPT_DIR}"/scripts/* "${BIN_PATH}" 2>&1 | tee -a "${RUN_LOG_FILE}"
    chmod +x "${BIN_PATH}"/*.sh 2>&1 | tee -a "${RUN_LOG_FILE}"

    log_pass "Scripts setup completed."
}

setup_services() {
    section "Setup Systemd Services"

    # auto-mount service when boot up
    tee /etc/systemd/system/pxe-mount.service > /dev/null << EOF 
[Unit]
Description=PXE ISO Auto Mount Service
After=local-fs.target
Before=apache2.service

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

    mkdir -p /etc/NetworkManager/dispatcher.d
    tee /etc/NetworkManager/dispatcher.d/50-pxe-services > /dev/null << EOF
#!/bin/bash

INTERFACE="\$1"
ACTION="\$2"

if [ "\${INTERFACE}" = "${PXE_INTERFACE}" ] && [ "\${ACTION}" = "up" ]; then
    echo "Connection to PXE Interface detected, starting PXE services..."

    systemctl is-active --quiet tftpd-hpa.service || systemctl start tftpd-hpa.service
    systemctl is-active --quiet isc-dhcp-server.service || systemctl start isc-dhcp-server.service
    systemctl is-active --quiet isc-dhcp-server6.service || systemctl start isc-dhcp-server6.service
    systemctl is-active --quiet radvd.service || systemctl start radvd.service
fi
EOF
    chmod 755 /etc/NetworkManager/dispatcher.d/50-pxe-services
    sed 's/^/[start-dhcp-on-link] /' /etc/NetworkManager/dispatcher.d/50-pxe-services >> "${RUN_LOG_FILE}"

    if systemctl daemon-reload >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Reloaded systemd configuration."
    else
        log_error "Failed to reload systemd configuration."
    fi

    # Only enable the project-created service.
    if systemctl enable pxe-mount.service >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Enabled pxe-mount.service."
    else
        log_error "Failed to enable pxe-mount.service."
    fi

    # Start PXE services immediately.
    # Dispatcher will handle future interface-up events.
    local pxe_services=(
        "tftpd-hpa.service"
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "radvd.service"
    )
    local service
    for service in "${pxe_services[@]}"; do
        if systemctl restart "${service}" >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Started ${service}."
        else
            log_warn "${service} failed to start."
            log_warn "The PXE interface may not be ready."
        fi
    done

    log_pass "Systemd services setup completed."
}

# ─── ISO Functions ───────────────────────────────────────────────────────────
mount_iso() {
    section "Mount Existing ISO Files"
    
    if [[ ! -x "${BIN_PATH}/pxe_mount_iso.sh" ]]; then
        log_warn "Mount script not found, skipping..."
    elif ISO_PATH="${ISO_PATH}" \
        HTTP_PATH="${HTTP_PATH}" \
        RUN_LOG_FILE="${RUN_LOG_FILE}" \
        "${BIN_PATH}/pxe_mount_iso.sh"; then      
            log_pass "ISO mount process completed."
    else
        log_warn "ISO mount failed"
    fi
}

umount_iso() {
    section "Unmount Existing ISO Files"
    
    if [[ ! -x "${BIN_PATH}/pxe_umount_iso.sh" ]]; then
        log_warn "Umount script not found, skipping..."
    elif HTTP_PATH="${HTTP_PATH}" \
        RUN_LOG_FILE="${RUN_LOG_FILE}" \
        "${BIN_PATH}/pxe_umount_iso.sh"; then
        log_pass "ISO unmount process completed."
    else
        log_warn "ISO unmount failed."
    fi
}

# ─── Final Check ───────────────────────────────────────────────────────────
final_status() {
    cat << EOF | tee -a "${RUN_LOG_FILE}"

========================================================
    ${PRODUCT_NAME} Complete
========================================================
    Version: ${VERSION}
    OS: ${DISTRO} (${KERNEL})

    PXE Network:
        Bridge: ${PXE_BRIDGE}
        Interface: ${PXE_INTERFACE}
EOF

    if ip link show "${PXE_BRIDGE}" | grep -q "<.*UP"; then
        echo "        Status: UP" | tee -a "${RUN_LOG_FILE}"

        local ipv4
        local ipv6

        ipv4=$(ip -4 addr show "${PXE_BRIDGE}" | awk '/inet / {print $2}')
        ipv6=$(ip -6 addr show "${PXE_BRIDGE}" | awk '/inet6 / && !/scope link/ {print $2}')

        echo "        IPv4: ${ipv4:-N/A}" | tee -a "${RUN_LOG_FILE}"
        echo "        IPv6: ${ipv6:-N/A}" | tee -a "${RUN_LOG_FILE}"
    else
        echo "        Status: DOWN" | tee -a "${RUN_LOG_FILE}"
    fi

    echo "" | tee -a "${RUN_LOG_FILE}"
    echo "    PXE Services:" | tee -a "${RUN_LOG_FILE}"
    local services=(
        "apache2"
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "tftpd-hpa.service"
        "radvd.service")

    for var in "${services[@]}"; do
        if systemctl is-active --quiet "$var"; then
            echo "        ${var}: active" | tee -a "${RUN_LOG_FILE}"
        else
            echo "        ${var}: failed" | tee -a "${RUN_LOG_FILE}"
            systemctl status "${var}" --no-pager 2>&1 | tee -a "${RUN_LOG_FILE}" || true
        fi
    done

    if systemctl is-failed --quiet pxe-mount.service 2>/dev/null; then
        echo "        pxe-mount.service: failed" | tee -a "${RUN_LOG_FILE}"
        systemctl status pxe-mount.service --no-pager 2>&1 | tee -a "${RUN_LOG_FILE}" || true
    elif systemctl is-enabled --quiet "pxe-mount.service"; then
        echo "        pxe-mount.service: enabled for next boot" | tee -a "${RUN_LOG_FILE}"
    else
        echo "        pxe-mount.service: not enabled" | tee -a "${RUN_LOG_FILE}"
    fi

    cat << EOF | tee -a "${RUN_LOG_FILE}"

    Access Information:
        IPv4 HTTP: http://${PXE_SERVER_IPv4}/
        IPv4 iPXE: http://${PXE_SERVER_IPv4}/ipxe/boot.ipxe
        IPv6 HTTP: http://[${PXE_SERVER_IPv6}]/
        IPv6 iPXE: http://[${PXE_SERVER_IPv6}]/ipxe/boot.ipxe
        TFTP Root: ${TFTP_PATH}
        HTTP Root: ${HTTP_PATH}

    All Setup Logs Saved to: ${RUN_LOG_DIR}
EOF

    END_TS=$(date +%s)
    ELAPSED=$((END_TS - RUN_TS))

    H=$((ELAPSED / 3600))
    M=$(( (ELAPSED % 3600) / 60 ))
    S=$((ELAPSED % 60))

    printf -v DURATION "%02d:%02d:%02d" "$H" "$M" "$S"

    cat << EOF | tee -a "${RUN_LOG_FILE}" 

    Elapsed Time: ${DURATION}
========================================================

EOF
    log "PXE Server setup completed successfully!"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall() {
    section "Uninstall PXE Server"

    local installed_config="${INSTALLED_CONFIG_PATH}/${PXE_CONFIG_FILE}"
    local state_manifest="${STATE_PATH}/managed_files.list"
    local normalized_main_path
    local normalized_http_path
    local path_name
    local path_value
    local normalized_path
    local service
    local target
    local relative_path
    local original_path
    local absent_marker
    local saved_state
    local enabled_state
    local active_state
    local restore_failed=false

    # -------------------------------------------------------------------------
    # Validate loaded configuration and saved state
    # -------------------------------------------------------------------------
    [[ "${ACTIVE_CONFIG_FILE}" == "${installed_config}" ]] || \
        log_error "Uninstall must use installed config: ${installed_config}"

    [[ -f "${STATE_PATH}/recorded" ]] || \
        log_error "Original system state backup is incomplete: ${STATE_PATH}"

    [[ -f "${state_manifest}" ]] || \
        log_error "Managed files manifest not found: ${state_manifest}"

    normalized_main_path="$(realpath -m "${MAIN_PATH}")"
    normalized_http_path="$(realpath -m "${HTTP_PATH}")"

    # Validate all paths used by destructive operations.
    for path_name in HTTP_PATH TFTP_PATH BIN_PATH LOG_PATH STATE_PATH; do
        path_value="${!path_name:-}"

        [[ -n "${path_value}" ]] || \
            log_error "${path_name} is empty. Aborting uninstall."

        [[ "${path_value}" == /* ]] || \
            log_error "${path_name} must be an absolute path: ${path_value}"

        normalized_path="$(realpath -m "${path_value}")"

        [[ "${normalized_path}" != "/" ]] || \
            log_error "${path_name} resolves to '/'. Aborting uninstall."

        [[ "${normalized_path}" != "${normalized_main_path}" ]] || \
            log_error "${path_name} must not equal MAIN_PATH."

        [[ "${normalized_path}" == "${normalized_main_path}/"* ]] || \
            log_error "${path_name} is outside MAIN_PATH: ${normalized_path}"
    done

    # -------------------------------------------------------------------------
    # Stop the current PXE auto-mount service
    # -------------------------------------------------------------------------
    if systemctl is-active --quiet pxe-mount.service 2>/dev/null; then
        if systemctl stop pxe-mount.service \
            >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Stopped pxe-mount.service."
        else
            log_warn "Failed to stop pxe-mount.service."
            restore_failed=true
        fi
    fi

    if systemctl is-enabled --quiet pxe-mount.service 2>/dev/null; then
        if systemctl disable pxe-mount.service \
            >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Disabled pxe-mount.service."
        else
            log_warn "Failed to disable pxe-mount.service."
            restore_failed=true
        fi
    fi

    # -------------------------------------------------------------------------
    # Unmount PXE ISO files using the shared wrapper
    # -------------------------------------------------------------------------
    if ! umount_iso; then
        log_warn "ISO unmount helper reported a failure."
    fi

    # Do not continue if a filesystem remains mounted below HTTP_PATH.
    if findmnt -rn -o TARGET |
       awk -v path="${normalized_http_path}" '
           $0 == path || index($0, path "/") == 1 {
               found = 1
           }
           END {
               exit !found
           }
       '; then
        log_error \
            "Mounted filesystems remain under ${HTTP_PATH}. Aborting uninstall."
    fi

    # -------------------------------------------------------------------------
    # Prevent the dispatcher from restarting PXE services during uninstall
    # -------------------------------------------------------------------------
    if [[ -e "/etc/NetworkManager/dispatcher.d/50-pxe-services" ]]; then
        if rm -f "/etc/NetworkManager/dispatcher.d/50-pxe-services"; then
            log_pass "Removed current PXE NetworkManager dispatcher."
        else
            log_warn "Failed to remove current PXE dispatcher."
            restore_failed=true
        fi
    fi

    # -------------------------------------------------------------------------
    # Stop services which may use the generated configurations
    # -------------------------------------------------------------------------
    local pxe_services=(
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "tftpd-hpa.service"
        "radvd.service"
    )

    for service in "${pxe_services[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            if systemctl stop "${service}" \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Stopped ${service}."
            else
                log_warn "Failed to stop ${service}."
                restore_failed=true
            fi
        fi
    done

    # -------------------------------------------------------------------------
    # Disable the current PXE Apache site
    # -------------------------------------------------------------------------
    if [[ -e "/etc/apache2/sites-enabled/pxe_apache.conf" ]]; then
        if a2dissite pxe_apache.conf \
            >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Disabled current PXE Apache site."
        else
            log_warn "Failed to disable current PXE Apache site."
            restore_failed=true
        fi
    fi

    # Remove the current project-created unit before restoring the original.
    if [[ -e "/etc/systemd/system/pxe-mount.service" ]]; then
        if rm -f "/etc/systemd/system/pxe-mount.service"; then
            log_pass "Removed current pxe-mount.service."
        else
            log_warn "Failed to remove current pxe-mount.service."
            restore_failed=true
        fi
    fi

    # -------------------------------------------------------------------------
    # Restore files listed in the installation-time manifest
    # -------------------------------------------------------------------------
    while IFS='' read -r target || [[ -n "${target}" ]]; do
        # Ignore empty lines and comments.
        [[ -z "${target}" ]] && continue
        [[ "${target}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${target}" != /* ]]; then
            log_warn "Invalid path in managed files manifest: ${target}"
            restore_failed=true
            continue
        fi

        relative_path="${target#/}"
        original_path="${STATE_PATH}/original/${relative_path}"
        absent_marker="${STATE_PATH}/absent/${relative_path}"

        if [[ -e "${original_path}" || -L "${original_path}" ]]; then
            if ! mkdir -p "$(dirname "${target}")"; then
                log_warn "Failed to create parent directory for: ${target}"
                restore_failed=true
                continue
            fi

            if ! rm -rf -- "${target}"; then
                log_warn "Failed to remove current file before restore: ${target}"
                restore_failed=true
                continue
            fi

            if cp -a -- "${original_path}" "${target}"; then
                log_pass "Restored original file: ${target}"
            else
                log_warn "Failed to restore original file: ${target}"
                restore_failed=true
            fi

        elif [[ -e "${absent_marker}" ]]; then
            if rm -rf -- "${target}"; then
                log_pass "Removed installer-created file: ${target}"
            else
                log_warn "Failed to remove installer-created file: ${target}"
                restore_failed=true
            fi

        else
            log_warn "Original state was not recorded: ${target}"
            restore_failed=true
        fi
    done < "${state_manifest}"

    # -------------------------------------------------------------------------
    # Reload systemd after restoring or removing unit files
    # -------------------------------------------------------------------------
    if systemctl daemon-reload >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Reloaded systemd configuration."
    else
        log_warn "Failed to reload systemd configuration."
        restore_failed=true
    fi

    # -------------------------------------------------------------------------
    # Apply restored Netplan configuration
    # -------------------------------------------------------------------------
    if command -v netplan >/dev/null 2>&1; then
        if netplan generate >> "${RUN_LOG_FILE}" 2>&1; then
            if netplan apply >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Applied restored Netplan configuration."
            else
                log_warn "Failed to apply restored Netplan configuration."
                restore_failed=true
            fi
        else
            log_warn "Restored Netplan configuration is invalid."
            restore_failed=true
        fi
    else
        log_warn "netplan command not found."
        restore_failed=true
    fi

    # -------------------------------------------------------------------------
    # Reload restored sysctl configuration
    # -------------------------------------------------------------------------
    if sysctl --system >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Reloaded sysctl configuration."
    else
        log_warn "Failed to reload sysctl configuration."
        restore_failed=true
    fi

    # -------------------------------------------------------------------------
    # Restore Apache site and module states
    # -------------------------------------------------------------------------

    # Restore the Apache default site state.
    saved_state="$(
        cat "${STATE_PATH}/apache/default-site" 2>/dev/null ||
        printf '%s' "disabled"
    )"

    if [[ "${saved_state}" == "enabled" ]]; then
        if a2ensite 000-default.conf \
            >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Restored Apache default site to enabled."
        else
            log_warn "Failed to enable Apache default site."
            restore_failed=true
        fi
    else
        a2dissite 000-default.conf \
            >> "${RUN_LOG_FILE}" 2>&1 || true

        log_pass "Restored Apache default site to disabled."
    fi

    # Restore the previous PXE Apache site state.
    saved_state="$(
        cat "${STATE_PATH}/apache/pxe-site" 2>/dev/null ||
        printf '%s' "disabled"
    )"

    if [[ "${saved_state}" == "enabled" ]]; then
        if [[ -f "/etc/apache2/sites-available/pxe_apache.conf" ]]; then
            if a2ensite pxe_apache.conf \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored previous PXE Apache site to enabled."
            else
                log_warn "Failed to restore previous PXE Apache site."
                restore_failed=true
            fi
        else
            log_warn \
                "Previous PXE Apache site should be enabled, but its config is missing."
            restore_failed=true
        fi
    else
        rm -f "/etc/apache2/sites-enabled/pxe_apache.conf"
        log_pass "Restored previous PXE Apache site to disabled."
    fi

    # Restore the Apache headers module state.
    saved_state="$(
        cat "${STATE_PATH}/apache/headers-module" 2>/dev/null ||
        printf '%s' "disabled"
    )"

    if [[ "${saved_state}" == "enabled" ]]; then
        if a2enmod headers >> "${RUN_LOG_FILE}" 2>&1; then
            log_pass "Restored Apache headers module to enabled."
        else
            log_warn "Failed to enable Apache headers module."
            restore_failed=true
        fi
    else
        a2dismod headers >> "${RUN_LOG_FILE}" 2>&1 || true
        log_pass "Restored Apache headers module to disabled."
    fi

    # -------------------------------------------------------------------------
    # Remove PXE-managed runtime directories
    # -------------------------------------------------------------------------
    for path_name in HTTP_PATH TFTP_PATH BIN_PATH; do
        path_value="${!path_name}"

        if [[ -d "${path_value}" ]]; then
            if rm -rf -- "${path_value}"; then
                log_pass "Removed ${path_name}: ${path_value}"
            else
                log_warn "Failed to remove ${path_name}: ${path_value}"
                restore_failed=true
            fi
        else
            log_info "${path_name} does not exist: ${path_value}"
        fi
    done

    # -------------------------------------------------------------------------
    # Restore package service active states
    #
    # Their enabled states are not changed by setup_services(), so only restore
    # whether they were active before installation.
    # -------------------------------------------------------------------------
    local tracked_services=(
        "isc-dhcp-server.service"
        "isc-dhcp-server6.service"
        "tftpd-hpa.service"
        "radvd.service"
    )

    for service in "${tracked_services[@]}"; do
        saved_state="$(
            cat "${STATE_PATH}/services/${service}.active" 2>/dev/null ||
            printf '%s' "inactive"
        )"

        if [[ "${saved_state}" == "active" ]]; then
            if systemctl start "${service}" \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored active state: ${service}"
            else
                log_warn "Failed to restore active state: ${service}"
                restore_failed=true
            fi
        else
            if systemctl stop "${service}" \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored inactive state: ${service}"
            else
                log_warn "Failed to restore inactive state: ${service}"
                restore_failed=true
            fi
        fi
    done

    # -------------------------------------------------------------------------
    # Restore Apache runtime state
    # -------------------------------------------------------------------------
    active_state="$(
        cat "${STATE_PATH}/services/apache2.service.active" 2>/dev/null ||
        printf '%s' "inactive"
    )"

    if apache2ctl configtest >> "${RUN_LOG_FILE}" 2>&1; then
        log_pass "Restored Apache configuration is valid."

        if [[ "${active_state}" == "active" ]]; then
            if systemctl is-active --quiet apache2.service; then
                if systemctl reload apache2.service \
                    >> "${RUN_LOG_FILE}" 2>&1; then
                    log_pass "Reloaded restored Apache configuration."
                else
                    log_warn "Failed to reload restored Apache configuration."
                    restore_failed=true
                fi
            else
                if systemctl start apache2.service \
                    >> "${RUN_LOG_FILE}" 2>&1; then
                    log_pass "Restored active state: apache2.service"
                else
                    log_warn "Failed to restore active state: apache2.service"
                    restore_failed=true
                fi
            fi
        else
            if systemctl stop apache2.service \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored inactive state: apache2.service"
            else
                log_warn "Failed to restore inactive state: apache2.service"
                restore_failed=true
            fi
        fi
    else
        log_warn "Restored Apache configuration test failed."
        restore_failed=true
    fi

    # -------------------------------------------------------------------------
    # Restore the original pxe-mount.service state
    #
    # Correct order:
    #   1. Unit file has already been restored from the manifest
    #   2. daemon-reload has already completed
    #   3. Restore enabled state
    #   4. Restore active state
    # -------------------------------------------------------------------------
    if [[ -f "/etc/systemd/system/pxe-mount.service" ]]; then
        enabled_state="$(
            cat "${STATE_PATH}/services/pxe-mount.service.enabled" \
                2>/dev/null ||
            printf '%s' "disabled"
        )"

        active_state="$(
            cat "${STATE_PATH}/services/pxe-mount.service.active" \
                2>/dev/null ||
            printf '%s' "inactive"
        )"

        # Restore boot-time enabled state first.
        if [[ "${enabled_state}" == "enabled" ]]; then
            if systemctl enable pxe-mount.service \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored enabled state: pxe-mount.service"
            else
                log_warn "Failed to restore enabled state: pxe-mount.service"
                restore_failed=true
            fi
        else
            if systemctl disable pxe-mount.service \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored disabled state: pxe-mount.service"
            else
                log_warn "Failed to restore disabled state: pxe-mount.service"
                restore_failed=true
            fi
        fi

        # Restore current runtime active state second.
        if [[ "${active_state}" == "active" ]]; then
            if systemctl start pxe-mount.service \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored active state: pxe-mount.service"
            else
                log_warn "Failed to restore active state: pxe-mount.service"
                restore_failed=true
            fi
        else
            if systemctl stop pxe-mount.service \
                >> "${RUN_LOG_FILE}" 2>&1; then
                log_pass "Restored inactive state: pxe-mount.service"
            else
                log_warn "Failed to restore inactive state: pxe-mount.service"
                restore_failed=true
            fi
        fi
    else
        log_info \
            "Original pxe-mount.service did not exist; no state restoration required."
    fi

    # -------------------------------------------------------------------------
    # Remove installed state only after every restoration succeeds
    # -------------------------------------------------------------------------
    if [[ "${restore_failed}" == false ]]; then
        rm -rf -- "${STATE_PATH}"
        rm -f "${INSTALLED_CONFIG_PATH}/${METADATA_FILE}"
        rm -f "${installed_config}"
        rmdir "${INSTALLED_CONFIG_PATH}" 2>/dev/null || true
        rm -f "${MAIN_PATH}/pxe_installer.sh"

        log_pass "Removed saved original system state."
        log_pass "Removed installed PXE configuration and metadata."
    else
        log_warn "Uninstall completed with restoration warnings."
        log_warn "Original system state was preserved in: ${STATE_PATH}"
        log_warn \
            "Installed config was preserved for uninstall retry: ${installed_config}"
    fi

    log_warn "PXE packages were preserved."
    log_warn "PXE logs were preserved in: ${LOG_PATH}"

    if [[ "${restore_failed}" == false ]]; then
        log_pass "PXE server uninstall completed."
    else
        log_warn "PXE server uninstall completed with warnings."
    fi

    log_info "Uninstall log saved to: ${RUN_LOG_FILE}"

    echo
    read -r -p "Do you want to reboot now? [y/N]: " REPLY
    REPLY="${REPLY:-N}"

    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
        log_info "System will reboot in 5 seconds..."
        sleep 5
        reboot
    else
        log_info "Please reboot manually to complete the uninstallation."
    fi
}

help() {
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

set_action() {
    local requested_action="$1"

    if [[ -n "${ACTION}" && "${ACTION}" != "${requested_action}" ]]; then
        log_error "Conflicting actions: ${ACTION} and ${requested_action}"
    fi

    ACTION="${requested_action}"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                set_action "help"
                ;;

            -r|--remove|--uninstall)
                set_action "uninstall"
                ;;

            -m|--mount)
                set_action "mount"
                ;;

            -u|--umount)
                set_action "umount"
                ;;

            --no-ipxe-build)
                SKIP_IPXE_BUILD=true
                ;;

            --config)
                shift
                [[ $# -gt 0 ]] || log_error "--config requires a file path."
                CONFIG_FILE="$1"
                ;;

            --config=*)
                CONFIG_FILE="${1#*=}"
                ;;

            *)
                log_error "Invalid option: $1"
                ;;
        esac

        shift
    done

    ACTION="${ACTION:-install}"

    if [[ "${SKIP_IPXE_BUILD}" == true &&
          "${ACTION}" != "install" ]]; then
        log_error "--no-ipxe-build can only be used with installation."
    fi

    if [[ -n "${CONFIG_FILE}" &&
          "${ACTION}" != "install" ]]; then
        log_error "--config can only be used with installation."
    fi
}

main() {
    # Reserved for future feature:
    # cleanup
    parse_arguments "$@"
    
    if [[ "${ACTION}" == "help" ]]; then
        load_metadata > /dev/null
        help
        exit 0
    fi
    
    load_metadata
    check_execution_context
    check_os_info
    load_pxe_config

    if [[ "${ACTION}" == "install" &&
        "${SKIP_IPXE_BUILD}" == true ]]; then
        log_warn "iPXE build is disabled by --no-ipxe-build."
        log_warn "Existing iPXE binaries in /usr/local/lib/ipxe will be used."
    fi

    case "${ACTION}" in
        install)
            echo
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

            show_welcome_info
            install_dependency
            setup_firewall
            setup_dir
            setup_config
            backup_original_state
            setup_networkmanager
            setup_dhcp
            setup_radvd
            setup_tftp
            [[ "${SKIP_IPXE_BUILD}" != true ]] && build_ipxe
            setup_apache
            create_helper_scripts
            umount_iso
            setup_pxe_files
            create_ipxe_menu
            mount_iso
            setup_services
            final_status
            ;;

        uninstall)
            echo
            echo "Do You want to uninstall PXE server?"
            echo "   [Y] Yes [N] No (Default)"
            read -r REPLY
            REPLY="${REPLY:-N}"
            if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                echo "Aborting uninstall."
                exit 1
            fi

            uninstall
            ;;

        mount)
            mount_iso
            ;;

        umount)
            umount_iso
            ;;

        *)
            log_error "Unsupported action: ${ACTION}"
            ;;
    esac
}
main "$@"