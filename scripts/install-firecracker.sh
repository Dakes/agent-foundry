#!/usr/bin/env bash
#
# Agent Foundry - Firecracker Installation Script
#
# Checks for an existing Firecracker install and, if missing, installs it
# using the host OS package manager.
#
# Usage:
#   ./scripts/install-firecracker.sh
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/utils.sh
source "${PROJECT_ROOT}/lib/utils.sh"

COLOR_OUTPUT="${COLOR_OUTPUT:-true}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

report_existing_firecracker() {
    if ! check_command firecracker; then
        return 1
    fi

    local path
    path="$(command -v firecracker 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
        log_info "Firecracker already installed at ${path}"
    else
        log_info "Firecracker already installed"
    fi

    local version
    if version="$(firecracker --version 2>/dev/null)"; then
        log_info "Firecracker version: ${version}"
    else
        log_warn "Unable to determine Firecracker version"
    fi

    return 0
}

get_privilege_prefix() {
    if [[ $EUID -eq 0 ]]; then
        echo ""
        return 0
    fi

    if check_command sudo; then
        echo "sudo"
        return 0
    fi

    log_error "Root privileges are required to install Firecracker"
    log_error "Re-run this script as root or install sudo"
    return 1
}

run_install_command() {
    local manager="$1"
    shift
    local -a cmd=("$@")

    log_info "Install command: ${cmd[*]}"

    if ! confirm "Install Firecracker using ${manager}?"; then
        log_warn "Installation cancelled by user"
        return 1
    fi

    if ! "${cmd[@]}"; then
        log_error "Installation failed: ${cmd[*]}"
        return 1
    fi

    return 0
}

handle_nixos() {
    log_warn "NixOS uses declarative package management"
    log_info "Add 'firecracker' to environment.systemPackages in /etc/nixos/configuration.nix"
    log_info "Then run: sudo nixos-rebuild switch"
    return 1
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    log_info "Agent Foundry - Firecracker Installer"

    if report_existing_firecracker; then
        return 0
    fi

    log_info "Firecracker not found; detecting host OS..."

    local host_os
    if ! host_os="$(detect_os)"; then
        log_error "Unable to detect supported host OS"
        return 1
    fi

    if [[ "$host_os" == "nixos" ]]; then
        handle_nixos
        return 1
    fi

    local sudo_prefix
    if ! sudo_prefix="$(get_privilege_prefix)"; then
        return 1
    fi

    case "$host_os" in
        arch)
            run_install_command "pacman" ${sudo_prefix:+$sudo_prefix} pacman -S firecracker
            ;;
        ubuntu)
            run_install_command "apt" ${sudo_prefix:+$sudo_prefix} apt install firecracker
            ;;
        fedora)
            run_install_command "dnf" ${sudo_prefix:+$sudo_prefix} dnf install firecracker
            ;;
        *)
            log_error "Unsupported OS: $host_os"
            return 1
            ;;
    esac

    if ! check_command firecracker; then
        log_error "Firecracker is still not available after installation"
        return 1
    fi

    local version
    if version="$(firecracker --version 2>/dev/null)"; then
        log_info "Firecracker installed successfully: ${version}"
    else
        log_info "Firecracker installed successfully"
    fi

    return 0
}

main "$@"
