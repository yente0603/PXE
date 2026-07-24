#!/bin/bash

# MODE:
#   0 - Child process           : Uses PXE configuration from the parent script.
#   1 - Standalone execution    : Loads configuration from pxe.conf.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RUN_ID=$(date '+%Y%m%d_%H%M%S')
RUN_TEMP_LOG="/tmp/pxe_umount_${RUN_ID}.log"
MODE=0

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
    if [[ "${MODE}" -eq 0 ]]; then return; fi

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

# ─── Load Config (Standalone only) ───────────────────────────────────────────
load_config() {
    section "Load PXE Config"

    CONFIG_FILE="${MAIN_PATH}/pxe.conf"

    [[ -f "${CONFIG_FILE}" ]] || log_error "Configuration file not found: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    for var in HTTP_PATH LOG_PATH; do
        if [[ -z "${!var:-}" ]]; then
            log_error "${var} is not defined in config."
        fi
    done

    RUN_LOG_DIR="${LOG_PATH}/pxe_manager_${RUN_ID}"
    RUN_LOG_FILE="${RUN_LOG_DIR}/umount_iso.log"

    mkdir -p "${RUN_LOG_DIR}"

    if [[ -f "${RUN_TEMP_LOG}" ]]; then
        cat "${RUN_TEMP_LOG}" >> "${RUN_LOG_FILE}"
        rm -f "${RUN_TEMP_LOG}"
    fi

    log_pass "PXE config load completed."
}


# ─── Umount ISO ───────────────────────────────────────────────────────────────
umount_iso() {
    section "Unmount ISO Files"

    if [[ -z "${HTTP_PATH:-}" ]]; then
        log_error "HTTP_PATH is not defined."
    fi

    if [[ ! -d "${HTTP_PATH}" ]]; then
        log_error "HTTP directory '${HTTP_PATH}' does not exist."
    fi

    local count=0
    while IFS='' read -r mount_point; do
        if mountpoint -q "${mount_point}" 2>/dev/null; then
            ((count+=1))

            if umount "${mount_point}" 2>/dev/null; then
                log_pass "Unmounted ${mount_point}"
            else
                log_warn "Normal umount failed, trying lazy umount."
                if umount -l "${mount_point}" 2>/dev/null; then
                    log_pass "Lazy unmounted ${mount_point}"
                else
                    log_warn "Failed to unmount ${mount_point}"
                fi
            fi
        fi
    done < <(find "${HTTP_PATH}" -depth -type d)


    if [[ ${count} -eq 0 ]]; then
        log_warn "No mounted ISO found."
    fi
}


# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Called by pxe_installer.sh
    if [[ -n "${HTTP_PATH:-}" ]]; then
        log_info "Using PXE configuration from parent script."
    else
        MODE=1
        log_info "Standalone execution detected."
        check_execution_context
        load_config
    fi
    umount_iso
}

main "$@"