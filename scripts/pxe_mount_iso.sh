#!/bin/bash

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RUN_ID=$(date '+%Y%m%d_%H%M%S')
RUN_TEMP_LOG="/tmp/pxe_mount_${RUN_ID}.log"

# If called from pxe_installer.sh, keep existing log file.
# Otherwise use temporary log first.
RUN_LOG_FILE="${RUN_LOG_FILE:-${RUN_TEMP_LOG}}"

readonly MAIN_PATH="${MAIN_PATH:-/opt/pxe}"
CONFIG_FILE=""

# ─── Output helpers ───────────────────────────────────────────────────────────
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

CURRENT_SECTION=""

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
    CURRENT_SECTION="$*"
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"
    echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}" | sed 's/\x1b\[[0-9;]*m//g' >> "${RUN_LOG_FILE}"
}

# ─── Check Environment ────────────────────────────────────────────────────────
check_execution_context() {
    section "Execution Context Check"

    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run with sudo."
    fi

    log_pass "Permission check completed."
}

# ─── Load Config (Standalone only) ────────────────────────────────────────────
load_config() {
    section "Load PXE Config"

    CONFIG_FILE="${MAIN_PATH}/pxe.conf"
    # CONFIG_FILE="${CONFIG_FILE:-${MAIN_PATH}/pxe.conf}"
    
    [[ ! -f "${CONFIG_FILE}" ]] || log_error "Configuration file not found: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    for var in ISO_PATH HTTP_PATH LOG_PATH; do
        if [[ -z "${!var:-}" ]]; then
            log_error "${var} is not defined in config."
        fi
    done

    RUN_LOG_DIR="${LOG_PATH}/pxe_manager_${RUN_ID}"
    RUN_LOG_FILE="${RUN_LOG_DIR}/mount_iso.log"

    mkdir -p "${RUN_LOG_DIR}"
    if [[ -f "${RUN_TEMP_LOG}" ]]; then
        cat "${RUN_TEMP_LOG}" >> "${RUN_LOG_FILE}"
        rm -f "${RUN_TEMP_LOG}"
    fi

    log_pass "PXE config load completed."
}

# ─── Mount ISO ────────────────────────────────────────────────────────────────
mount_iso() {
    section "Mount ISO Files"

    for var in ISO_PATH HTTP_PATH; do
        if [[ -z "${!var:-}" ]]; then
            log_error "${var} is not defined."
        fi
    done

    if [[ ! -d "${ISO_PATH}" ]]; then
        log_error "ISO directory '${ISO_PATH}' does not exist."
    fi

    local count=0
    while IFS= read -r iso; do
        ((count+=1))

        local rel_path
        local dirname
        local filename
        local mount_point

        rel_path="${iso#${ISO_PATH}/}"
        dirname=$(dirname "${rel_path}")
        filename=$(basename "${iso}" .iso)
        mount_point="${HTTP_PATH}/${dirname}/${filename}"

        if [[ "${iso}" == *"winpe_with_ethernet_driver_from_win11_24h2_64bits"* ]]; then
            log_warn "Skip WinPE ISO: ${iso}"
            continue
        fi

        log_info "Processing ${filename}"
        mkdir -p "${mount_point}" || log_error "Failed to create mount point: ${mount_point}"
        if mountpoint -q "${mount_point}" 2>/dev/null; then
            log_warn "${filename} already mounted."
        else
            if mount -o loop,ro,mode=0755 "${iso}" "${mount_point}"; then
                log_pass "Mounted ${filename}"
            else
                log_error "Failed to mount ${filename}"
            fi
        fi
    done < <(find "${ISO_PATH}" -type f -name "*.iso")

    if [[ ${count} -eq 0 ]]; then
        log_warn "No ISO files found."
    fi

    log_pass "ISO mount completed."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    check_execution_context

    # Called by pxe_installer.sh
    if [[ -n "${ISO_PATH:-}" && -n "${HTTP_PATH:-}" ]]; then
        log_info "Using PXE configuration from parent script."
    else
        log_info "Standalone execution detected."
        load_config
    fi
    mount_iso
}

main "$@"