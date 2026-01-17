#!/usr/bin/env bash
#
# Agent Foundry - Utility Functions
#
# Common utilities used across the framework
#

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Check if command exists
check_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Check KVM support
check_kvm() {
    # TODO: Implement KVM check
    return 0
}

# Detect host OS
detect_os() {
    # TODO: Implement OS detection
    echo "unknown"
}

# User confirmation
confirm() {
    local prompt="$1"
    read -r -p "${prompt} [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Cleanup on exit
cleanup_on_exit() {
    # TODO: Implement cleanup handlers
    :
}
