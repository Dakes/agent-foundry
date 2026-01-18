#!/usr/bin/env bash
#
# Agent Foundry - Installation Script
#
# Builds and installs Agent Foundry as a self-contained bundle.
#
# Usage:
#   ./install.sh                    # Interactive installation
#   ./install.sh --prefix /usr/local # Custom install location
#   ./install.sh --no-setup         # Skip host setup after installation
#   ./install.sh --uninstall        # Remove installation
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Temporary source utils for logging (before installation)
# shellcheck source=lib/utils.sh
source "${PROJECT_ROOT}/lib/utils.sh"

COLOR_OUTPUT="${COLOR_OUTPUT:-true}"

# Default installation prefix
INSTALL_PREFIX="${INSTALL_PREFIX:-}"
BIN_DIR=""
CONFIG_DIR="${HOME}/.config/foundry"
DATA_DIR="${HOME}/.local/share/foundry"

# Options
RUN_SETUP=true
UNINSTALL=false

# ============================================================================
# SHELL HELPERS
# ============================================================================

expand_user_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 1
    fi
    if [[ "$path" == "~" ]]; then
        printf '%s\n' "$HOME"
        return 0
    fi
    if [[ "$path" == "~/"* ]]; then
        printf '%s\n' "$HOME/${path:2}"
        return 0
    fi
    printf '%s\n' "$path"
}

detect_user_shell() {
    local shell_path="${SHELL:-}"
    if [[ -z "$shell_path" ]]; then
        shell_path="$(ps -p $$ -o comm= 2>/dev/null || true)"
    fi
    shell_path="${shell_path##*/}"
    shell_path="${shell_path#-}"
    printf '%s\n' "${shell_path:-sh}"
}

detect_shell_rc_file() {
    local shell_name rc_candidates=()
    shell_name="$(detect_user_shell)"
    case "$shell_name" in
        bash)
            rc_candidates=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
            ;;
        zsh)
            rc_candidates=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile")
            ;;
        fish)
            rc_candidates=("$HOME/.config/fish/config.fish")
            ;;
        *)
            rc_candidates=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish")
            ;;
    esac

    local rc_file
    for rc_file in "${rc_candidates[@]}"; do
        local resolved
        resolved="$(expand_user_path "$rc_file")"
        if [[ -f "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    rc_file="${rc_candidates[0]:-${HOME}/.profile}"
    printf '%s\n' "$(expand_user_path "$rc_file")"
    return 0
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    cat <<EOF
Agent Foundry - Installation Script

Usage: $(basename "$0") [OPTIONS]

Options:
  --prefix <path>     Installation prefix (default: /usr/local or ~/.local)
  --no-setup          Skip host setup after installation
  --uninstall         Remove Agent Foundry installation
  -h, --help          Show this help and exit

Examples:
  # User-local installation (no sudo)
  ./install.sh --prefix ~/.local

  # System-wide installation (requires sudo)
  sudo ./install.sh --prefix /usr/local

  # Install without running host setup
  ./install.sh --no-setup

  # Uninstall
  ./install.sh --uninstall
EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                shift
                if [[ $# -eq 0 ]]; then
                    log_error "--prefix requires a value"
                    usage
                    exit 1
                fi
                INSTALL_PREFIX="$1"
                shift
                ;;
            --prefix=*)
                INSTALL_PREFIX="${1#*=}"
                shift
                ;;
            --no-setup)
                RUN_SETUP=false
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# INSTALLATION PREFIX DETECTION
# ============================================================================

detect_install_prefix() {
    if [[ -n "$INSTALL_PREFIX" ]]; then
        # User specified prefix
        INSTALL_PREFIX=$(realpath -m "$INSTALL_PREFIX")
        BIN_DIR="${INSTALL_PREFIX}/bin"
        return 0
    fi

    # Auto-detect based on permissions
    if [[ $EUID -eq 0 ]]; then
        # Running as root - install system-wide
        INSTALL_PREFIX="/usr/local"
        BIN_DIR="/usr/local/bin"
    else
        # Not root - install to user directory
        INSTALL_PREFIX="${HOME}/.local"
        BIN_DIR="${HOME}/.local/bin"
    fi
}

# ============================================================================
# DEPENDENCY CHECKING
# ============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=()

    if ! check_command bash; then
        missing+=("bash")
    fi

    if ! check_command tar; then
        missing+=("tar")
    fi

    if ! check_command ssh; then
        missing+=("ssh")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install these packages and try again"
        return 1
    fi

    log_info "All required dependencies are installed"
    return 0
}

# ============================================================================
# BUNDLE BUILDING
# ============================================================================

build_bundle() {
    if [[ ! -f "${PROJECT_ROOT}/scripts/build-release.sh" ]]; then
        log_error "Build script not found: scripts/build-release.sh"
        return 1
    fi

    log_info "Building release bundle..."
    if ! "${PROJECT_ROOT}/scripts/build-release.sh"; then
        log_error "Failed to build release bundle"
        return 1
    fi
}

# ============================================================================
# INSTALLATION
# ============================================================================

install_foundry() {
    local bundle_file="${PROJECT_ROOT}/bin/foundry-release"

    if [[ ! -f "$bundle_file" ]]; then
        log_error "Release bundle not found: $bundle_file"
        return 1
    fi

    log_info "Installing Agent Foundry to: $INSTALL_PREFIX"
    echo ""

    # Create directories
    log_info "Creating directories..."
    mkdir -p "$BIN_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR/vms/templates"
    mkdir -p "$DATA_DIR/vms/instances"
    mkdir -p "$DATA_DIR/vms/kernels"
    mkdir -p "$DATA_DIR/logs"

    # Install binary from bundle
    log_info "Installing foundry binary..."
    cp -f "$bundle_file" "$BIN_DIR/foundry"
    chmod +x "$BIN_DIR/foundry"

    # Copy configuration files (only if they don't exist)
    log_info "Installing default configuration..."
    if [[ -f "${PROJECT_ROOT}/config/default.conf" ]]; then
        if [[ ! -f "${CONFIG_DIR}/config.conf" ]]; then
            cp "${PROJECT_ROOT}/config/default.conf" "${CONFIG_DIR}/config.conf"
        else
            log_info "Configuration already exists, skipping"
        fi
    fi

    if [[ -f "${PROJECT_ROOT}/config/packages.txt" ]]; then
        if [[ ! -f "${CONFIG_DIR}/packages.txt" ]]; then
            cp "${PROJECT_ROOT}/config/packages.txt" "${CONFIG_DIR}/packages.txt"
        fi
    fi

    # Copy template files if they exist
    if [[ -d "${PROJECT_ROOT}/templates" ]]; then
        log_info "Installing template files..."
        cp -r "${PROJECT_ROOT}"/templates/* "$CONFIG_DIR/" 2>/dev/null || true
    fi

    # Create registry file if it doesn't exist
    if [[ ! -f "${CONFIG_DIR}/vms.json" ]]; then
        echo '{"vms":{}}' > "${CONFIG_DIR}/vms.json"
    fi

    log_info "Installation complete!"
    echo ""
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

uninstall_foundry() {
    log_info "Uninstalling Agent Foundry..."

    # Remove binary
    if [[ -f "$BIN_DIR/foundry" ]]; then
        rm -f "$BIN_DIR/foundry"
        log_info "Removed binary: $BIN_DIR/foundry"
    fi

    # Keep config and data directories (user may want to preserve data)
    log_info "Configuration and data preserved in:"
    log_info "  $CONFIG_DIR"
    log_info "  $DATA_DIR"
    log_info "Remove these directories manually if desired"

    log_info "Uninstallation complete"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_installation() {
    if ! command -v foundry &>/dev/null; then
        local shell_rc shell_name
        shell_rc="$(detect_shell_rc_file)"
        shell_name="$(detect_user_shell)"

        log_warn "foundry command not found in PATH"
        log_warn "Detected shell: $shell_name"
        log_warn "Add $BIN_DIR to your PATH in $shell_rc:"
        echo ""
        echo "  export PATH=\"\$PATH:$BIN_DIR\""
        echo ""
        echo "  source \"$shell_rc\""
        if [[ ! -f "$shell_rc" ]]; then
            log_warn "Create $shell_rc before sourcing it if it does not exist"
        fi
        return 1
    fi

    return 0
}

# ============================================================================
# NEXT STEPS
# ============================================================================

show_next_steps() {
    log_info "==================================================================="
    log_info "Agent Foundry Installation Complete!"
    log_info "==================================================================="
    echo ""
    log_info "Installation Details:"
    log_info "  Binary:  $BIN_DIR/foundry"
    log_info "  Config:  $CONFIG_DIR"
    log_info "  Data:    $DATA_DIR"
    echo ""
    log_info "Next Steps:"
    echo ""
    local shell_rc
    shell_rc="$(detect_shell_rc_file)"
    echo "  1. Add to PATH (if not already in PATH):"
    echo "     export PATH=\"\$PATH:$BIN_DIR\""
    echo ""
    echo "     source \"$shell_rc\""
    if [[ ! -f "$shell_rc" ]]; then
        echo "     # Create $shell_rc if it does not exist yet"
    fi
    echo ""
    echo "  2. Set up your host system:"
    echo "     sudo foundry host setup"
    echo ""
    echo "  3. Build VM templates:"
    echo "     sudo foundry template build base"
    echo "     sudo foundry template build golden"
    echo ""
    echo "  4. Create your first VM:"
    echo "     foundry vm create my-project"
    echo ""
    echo "  5. Initialize a workspace:"
    echo "     foundry workspace init my-project config.json"
    echo ""
    echo "  6. Start an agent:"
    echo "     foundry agent start my-project ralph"
    echo ""
    log_info "Documentation: See README.md and docs/ for more information"
    log_info "==================================================================="
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_args "$@"

    echo "Agent Foundry Installation"
    echo "=========================="
    echo ""

    # Handle uninstall
    if $UNINSTALL; then
        uninstall_foundry
        exit 0
    fi

    # Detect installation prefix
    detect_install_prefix

    # Check dependencies
    check_dependencies || exit 1

    # Build release bundle if needed
    if [[ ! -f "${PROJECT_ROOT}/bin/foundry-release" ]]; then
        echo ""
        build_bundle || exit 1
    fi

    # Confirm installation
    echo ""
    log_info "Installation Configuration:"
    log_info "  Prefix:  $INSTALL_PREFIX"
    log_info "  Binary:  $BIN_DIR"
    log_info "  Config:  $CONFIG_DIR"
    log_info "  Data:    $DATA_DIR"
    echo ""

    if ! confirm "Proceed with installation?"; then
        log_info "Installation cancelled"
        exit 0
    fi

    # Install
    install_foundry

    # Verify
    if ! verify_installation; then
        log_warn "Installation completed but verification failed"
        log_warn "You may need to add $BIN_DIR to your PATH"
    fi

    # Show next steps
    show_next_steps

    # Optionally run host setup
    if $RUN_SETUP; then
        echo ""
        if confirm "Run host setup now? (Recommended)"; then
            if [[ -x "${PROJECT_ROOT}/scripts/setup-host.sh" ]]; then
                exec "${PROJECT_ROOT}/scripts/setup-host.sh"
            else
                log_warn "Host setup script not found"
            fi
        fi
    fi
}

main "$@"
