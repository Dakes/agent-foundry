#!/usr/bin/env bash
#
# Agent Foundry - Host Setup Script
#
# Sets up host system for running Agent Foundry.
# Detects OS, checks/installs dependencies, sets up networking,
# initializes configuration and registry.
#
# Usage:
#   ./scripts/setup-host.sh              # Interactive setup
#   ./scripts/setup-host.sh --no-install # Check only, don't install
#   ./scripts/setup-host.sh --force      # Force reinstall all
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility functions
# shellcheck source=lib/utils.sh
source "${PROJECT_ROOT}/lib/utils.sh"

# Enable color output for this script
COLOR_OUTPUT="${COLOR_OUTPUT:-true}"

# Flags
FORCE_INSTALL=false
NO_INSTALL=false
SKIP_NETWORK=false
SKIP_FIRECRACKER=false

# Required dependencies by package manager
declare -A PACMAN_DEPS=(
    [firecracker]="firecracker"
    [qemu-img]="qemu-img"
    [jq]="jq"
    [tmux]="tmux"
    [screen]="screen"
    [iproute2]="iproute2"
    [iptables]="iptables"
)

declare -A APT_DEPS=(
    [firecracker]="firecracker"
    [qemu-img]="qemu-utils"
    [jq]="jq"
    [tmux]="tmux"
    [screen]="screen"
    [iproute2]="iproute2"
    [iptables]="iptables"
)

declare -A DNF_DEPS=(
    [firecracker]="firecracker"
    [qemu-img]="qemu-img"
    [jq]="jq"
    [tmux]="tmux"
    [screen]="screen"
    [iproute2]="iproute2"
    [iptables]="iptables"
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print setup header
print_header() {
    log_info ""
    log_info "Agent Foundry - Host Setup"
    log_info "=========================================="
    log_info ""
}

# Print summary
print_summary() {
    local status="$1"
    log_info ""
    log_info "=========================================="
    log_info "Setup Summary"
    log_info "=========================================="
    log_info "Status: $status"
    log_info "Host OS: ${HOST_OS:-unknown}"
    log_info "KVM Support: ${KVM_AVAILABLE:-unknown}"
    log_info "Config Dir: ${FOUNDRY_CONFIG_DIR:-~/.config/foundry}"
    log_info "Data Dir: ${FOUNDRY_DATA_DIR:-~/.local/share/foundry}"
    log_info ""
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
    return 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-install)
                NO_INSTALL=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --skip-network)
                SKIP_NETWORK=true
                shift
                ;;
            --skip-firecracker)
                SKIP_FIRECRACKER=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help
show_help() {
    cat <<EOF
Agent Foundry Host Setup Script

Usage: $0 [OPTIONS]

Options:
  --no-install         Check dependencies only, don't install
  --force              Force reinstall all dependencies
  --skip-network       Skip network setup
  --skip-firecracker   Skip Firecracker installation
  --help               Show this help message

This script will:
  1. Detect host OS
  2. Check KVM support
  3. Check/install required dependencies
  4. Set up networking
  5. Install Firecracker (if needed)
  6. Initialize configuration
  7. Initialize registry
  8. Validate setup

EOF
}

# ============================================================================
# OS DETECTION
# ============================================================================

# Get the host OS using detect_os from utils
detect_host_os() {
    log_info "Detecting host OS..."

    HOST_OS=$(detect_os) || {
        log_error "Failed to detect host OS"
        return 1
    }

    case "$HOST_OS" in
        arch)
            log_info "Host OS: Arch Linux (pacman)"
            PKG_MANAGER="pacman"
            return 0
            ;;
        ubuntu)
            log_info "Host OS: Ubuntu/Debian (apt)"
            PKG_MANAGER="apt"
            return 0
            ;;
        fedora)
            log_info "Host OS: Fedora (dnf)"
            PKG_MANAGER="dnf"
            return 0
            ;;
        nixos)
            log_warn "NixOS detected - some features may need manual configuration"
            PKG_MANAGER="nix"
            return 0
            ;;
        *)
            log_error "Unsupported OS: $HOST_OS"
            return 1
            ;;
    esac
}

# ============================================================================
# KVM & HARDWARE CHECKS
# ============================================================================

# Check KVM support using check_kvm from utils
check_kvm_support() {
    log_info "Checking KVM support..."

    if check_kvm; then
        log_info "KVM support verified - /dev/kvm is accessible"
        KVM_AVAILABLE=true
        return 0
    else
        log_warn "KVM support not available or not accessible"
        KVM_AVAILABLE=false

        if [[ ! -e /dev/kvm ]]; then
            log_error "Your system does not support KVM (required for Firecracker)"
            return 1
        fi

        if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
            log_error "/dev/kvm exists but is not accessible"
            log_error "You may need to add your user to the kvm group:"
            log_error "  sudo usermod -aG kvm \$USER"
            return 1
        fi
    fi
}

# ============================================================================
# DEPENDENCY CHECKING & INSTALLATION
# ============================================================================

# Check if a command is available
is_installed() {
    local cmd="$1"
    check_command "$cmd"
}

# Get package name for given dependency
get_package_name() {
    local dep="$1"
    local pkg_manager="$2"

    case "$pkg_manager" in
        pacman)
            echo "${PACMAN_DEPS[$dep]:-$dep}"
            ;;
        apt)
            echo "${APT_DEPS[$dep]:-$dep}"
            ;;
        dnf)
            echo "${DNF_DEPS[$dep]:-$dep}"
            ;;
        nix)
            echo "$dep"
            ;;
        *)
            echo "$dep"
            ;;
    esac
}

# Install packages using package manager
install_packages() {
    local pkg_manager="$1"
    shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "All dependencies already installed"
        return 0
    fi

    log_info "Installing packages: ${packages[*]}"

    case "$pkg_manager" in
        pacman)
            pacman -Sy --noconfirm "${packages[@]}" || {
                log_error "Failed to install packages with pacman"
                return 1
            }
            ;;
        apt)
            apt-get update || log_warn "apt-get update failed"
            apt-get install -y "${packages[@]}" || {
                log_error "Failed to install packages with apt"
                return 1
            }
            ;;
        dnf)
            dnf install -y "${packages[@]}" || {
                log_error "Failed to install packages with dnf"
                return 1
            }
            ;;
        nix)
            log_error "NixOS package installation not yet implemented"
            log_error "Please install dependencies manually"
            return 1
            ;;
        *)
            log_error "Unknown package manager: $pkg_manager"
            return 1
            ;;
    esac
}

# Check and install dependencies
check_dependencies() {
    log_info ""
    log_info "Checking required dependencies..."

    # Dependencies to check
    # Note: tmux and screen are VM-only, not host dependencies
    local required_cmds=(firecracker qemu-img jq iptables)
    local optional_cmds=(iproute2)

    local missing_packages=()
    local all_missing_packages=()

    # Check required dependencies
    for cmd in "${required_cmds[@]}"; do
        if is_installed "$cmd"; then
            log_info "✓ $cmd is installed"
        else
            log_warn "✗ $cmd is NOT installed"
            local pkg_name
            pkg_name=$(get_package_name "$cmd" "$PKG_MANAGER")
            missing_packages+=("$pkg_name")
            all_missing_packages+=("$pkg_name")
        fi
    done

    # Check optional dependencies
    for cmd in "${optional_cmds[@]}"; do
        if is_installed "$cmd"; then
            log_info "✓ $cmd is installed"
        else
            log_warn "⚠ $cmd is optional but recommended"
        fi
    done

    # Handle missing packages
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_packages[*]}"

        if [[ "$NO_INSTALL" == true ]]; then
            log_error "Use without --no-install flag to install missing dependencies"
            return 1
        fi

        if ! confirm "Install missing dependencies with $PKG_MANAGER?"; then
            log_error "Cannot proceed without required dependencies"
            return 1
        fi

        if ! install_packages "$PKG_MANAGER" "${all_missing_packages[@]}"; then
            log_error "Failed to install dependencies"
            return 1
        fi

        # Verify installation
        log_info "Verifying installation..."
        for cmd in "${required_cmds[@]}"; do
            if ! is_installed "$cmd"; then
                log_error "Failed to install $cmd"
                return 1
            fi
        done
    fi

    log_info "All required dependencies are installed"
    return 0
}

# ============================================================================
# SETUP EXECUTION
# ============================================================================

# Run network setup script
run_network_setup() {
    if [[ "$SKIP_NETWORK" == true ]]; then
        log_warn "Skipping network setup (--skip-network)"
        return 0
    fi

    local network_script="${PROJECT_ROOT}/scripts/setup-network.sh"

    if [[ ! -f "$network_script" ]]; then
        log_warn "Network setup script not found: $network_script"
        log_warn "Skipping network setup"
        return 0
    fi

    log_info ""
    log_info "Running network setup..."

    if ! bash "$network_script"; then
        log_error "Network setup failed"
        return 1
    fi

    return 0
}

# Run Firecracker installation script
run_firecracker_install() {
    if [[ "$SKIP_FIRECRACKER" == true ]]; then
        log_warn "Skipping Firecracker installation (--skip-firecracker)"
        return 0
    fi

    local firecracker_script="${PROJECT_ROOT}/scripts/install-firecracker.sh"

    if [[ ! -f "$firecracker_script" ]]; then
        log_warn "Firecracker install script not found: $firecracker_script"
        log_warn "Skipping Firecracker installation"
        return 0
    fi

    log_info ""
    log_info "Running Firecracker installation..."

    if ! bash "$firecracker_script"; then
        log_error "Firecracker installation failed"
        return 1
    fi

    return 0
}

# Initialize configuration
init_configuration() {
    log_info ""
    log_info "Initializing configuration..."

    # Source config module
    # shellcheck source=lib/config.sh
    source "${PROJECT_ROOT}/lib/config.sh"

    # Run config_init function
    if ! config_init; then
        log_error "Failed to initialize configuration"
        return 1
    fi

    log_info "Configuration initialized successfully"
    return 0
}

# Initialize registry
init_registry() {
    log_info ""
    log_info "Initializing VM registry..."

    # Source registry module
    # shellcheck source=lib/registry.sh
    source "${PROJECT_ROOT}/lib/registry.sh"

    # Run registry_init function
    if ! registry_init; then
        log_error "Failed to initialize VM registry"
        return 1
    fi

    log_info "VM registry initialized successfully"
    return 0
}

# Validate the setup
validate_setup() {
    log_info ""
    log_info "Validating setup..."

    local validation_passed=true

    # Check config directory
    local config_dir="${FOUNDRY_CONFIG_DIR:-${HOME}/.config/foundry}"
    if [[ ! -d "$config_dir" ]]; then
        log_error "Config directory not found: $config_dir"
        validation_passed=false
    else
        log_info "✓ Config directory exists: $config_dir"
    fi

    # Check data directory
    local data_dir="${FOUNDRY_DATA_DIR:-${HOME}/.local/share/foundry}"
    if [[ ! -d "$data_dir" ]]; then
        log_error "Data directory not found: $data_dir"
        validation_passed=false
    else
        log_info "✓ Data directory exists: $data_dir"
    fi

    # Check registry file
    local registry_file="${config_dir}/vms.json"
    if [[ ! -f "$registry_file" ]]; then
        log_error "Registry file not found: $registry_file"
        validation_passed=false
    else
        log_info "✓ Registry file exists: $registry_file"

        # Validate JSON
        if ! jq empty "$registry_file" 2>/dev/null; then
            log_error "Registry file is not valid JSON"
            validation_passed=false
        else
            log_info "✓ Registry file is valid JSON"
        fi
    fi

    # Check config file
    local config_file="${config_dir}/config.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        validation_passed=false
    else
        log_info "✓ Config file exists: $config_file"
    fi

    # Verify Firecracker
    if ! is_installed firecracker; then
        log_error "Firecracker is not installed"
        validation_passed=false
    else
        log_info "✓ Firecracker is installed"
    fi

    # Verify KVM
    if [[ "$KVM_AVAILABLE" != true ]]; then
        log_error "KVM support not available"
        validation_passed=false
    else
        log_info "✓ KVM support verified"
    fi

    if [[ "$validation_passed" == true ]]; then
        log_info "All validation checks passed"
        return 0
    else
        log_error "Some validation checks failed"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse arguments
    parse_args "$@"

    # Print header
    print_header

    # Check if running as root
    if ! check_root; then
        print_summary "FAILED (requires root)"
        exit 1
    fi

    # Detect host OS
    if ! detect_host_os; then
        print_summary "FAILED (OS detection failed)"
        exit 1
    fi

    # Check KVM support
    if ! check_kvm_support; then
        print_summary "FAILED (KVM not available)"
        exit 1
    fi

    # Check dependencies
    if ! check_dependencies; then
        print_summary "FAILED (dependency check failed)"
        exit 1
    fi

    # Run network setup
    if ! run_network_setup; then
        print_summary "FAILED (network setup failed)"
        exit 1
    fi

    # Run Firecracker installation
    if ! run_firecracker_install; then
        print_summary "FAILED (Firecracker installation failed)"
        exit 1
    fi

    # Initialize configuration
    if ! init_configuration; then
        print_summary "FAILED (configuration initialization failed)"
        exit 1
    fi

    # Initialize registry
    if ! init_registry; then
        print_summary "FAILED (registry initialization failed)"
        exit 1
    fi

    # Validate setup
    if ! validate_setup; then
        print_summary "FAILED (validation failed)"
        exit 1
    fi

    # Success
    print_summary "SUCCESS"
    log_info "Host setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Review configuration: cat ${FOUNDRY_CONFIG_DIR:-~/.config/foundry}/config.conf"
    log_info "2. Build VM templates: ./scripts/build-arch-base.sh"
    log_info "3. Create your first VM: foundry vm create <project-name>"
    log_info ""

    return 0
}

# Run main function
main "$@"
