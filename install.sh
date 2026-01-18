#!/usr/bin/env bash
#
# Agent Foundry - Installation Script
#
# Installs Agent Foundry framework to the system.
#
# Usage:
#   ./install.sh                    # Interactive installation
#   ./install.sh --prefix /usr/local # Custom install location
#   ./install.sh --no-setup         # Skip host setup
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
LIB_DIR=""
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
  # System-wide installation (requires sudo)
  sudo ./install.sh --prefix /usr/local

  # User-local installation (no sudo)
  ./install.sh --prefix ~/.local

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
        LIB_DIR="${INSTALL_PREFIX}/lib/foundry"
        return 0
    fi

    # Auto-detect based on permissions
    if [[ $EUID -eq 0 ]]; then
        # Running as root - install system-wide
        INSTALL_PREFIX="/usr/local"
        BIN_DIR="/usr/local/bin"
        LIB_DIR="/usr/local/lib/foundry"
    else
        # Not root - install to user directory
        INSTALL_PREFIX="${HOME}/.local"
        BIN_DIR="${HOME}/.local/bin"
        LIB_DIR="${HOME}/.local/lib/foundry"
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

    if ! check_command git; then
        missing+=("git")
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
# INSTALLATION
# ============================================================================

install_foundry() {
    log_info "Installing Agent Foundry to: $INSTALL_PREFIX"
    echo ""

    # Create directories
    log_info "Creating directories..."
    mkdir -p "$BIN_DIR"
    mkdir -p "$LIB_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR/vms/templates"
    mkdir -p "$DATA_DIR/vms/instances"
    mkdir -p "$DATA_DIR/vms/kernels"
    mkdir -p "$DATA_DIR/logs"

    # Copy main binary
    log_info "Installing foundry binary..."
    cp -f "${PROJECT_ROOT}/bin/foundry" "$BIN_DIR/foundry"
    chmod +x "$BIN_DIR/foundry"

    # Copy library modules
    log_info "Installing library modules..."
    mkdir -p "$LIB_DIR"
    cp -f "${PROJECT_ROOT}"/lib/*.sh "$LIB_DIR/"

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

    # Update foundry binary to use correct lib path
    if [[ "$LIB_DIR" != */lib/foundry ]]; then
        sed -i "s|FOUNDRY_LIB_DIR=.*|FOUNDRY_LIB_DIR=\"$LIB_DIR\"|" "$BIN_DIR/foundry" 2>/dev/null || true
    fi

    log_info "Installation complete!"
    echo ""
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

uninstall_foundry() {
    log_info "Uninstalling Agent Foundry..."

    detect_install_prefix

    if [[ ! -f "$BIN_DIR/foundry" ]]; then
        log_warn "foundry binary not found at: $BIN_DIR/foundry"
        log_warn "Already uninstalled or never installed?"
        return 0
    fi

    if ! confirm "Remove Agent Foundry installation from $INSTALL_PREFIX?"; then
        log_info "Uninstall cancelled"
        return 0
    fi

    # Remove binary and lib
    log_info "Removing foundry binary..."
    rm -f "$BIN_DIR/foundry"

    if [[ -d "$LIB_DIR" ]]; then
        log_info "Removing library modules..."
        rm -rf "$LIB_DIR"
    fi

    log_info "Agent Foundry uninstalled"
    log_warn "Configuration and data preserved at:"
    log_warn "  Config: $CONFIG_DIR"
    log_warn "  Data:   $DATA_DIR"
    echo ""

    if confirm "Remove configuration and data as well?"; then
        rm -rf "$CONFIG_DIR"
        rm -rf "$DATA_DIR"
        log_info "Configuration and data removed"
    fi

    log_info "Uninstall complete"
    return 0
}

# ============================================================================
# POST-INSTALLATION
# ============================================================================

verify_installation() {
    log_info "Verifying installation..."

    # Check if foundry is in PATH
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

    # Try running foundry --version
    if foundry --version &>/dev/null; then
        log_info "Installation verified successfully!"
        echo ""
        foundry --version
        return 0
    else
        log_error "Installation verification failed"
        return 1
    fi
}

show_next_steps() {
    echo ""
    log_info "==================================================================="
    log_info "Agent Foundry Installation Complete!"
    log_info "==================================================================="
    echo ""
    log_info "Installation Details:"
    log_info "  Binary:  $BIN_DIR/foundry"
    log_info "  Libs:    $LIB_DIR"
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

    # Confirm installation
    echo ""
    log_info "Installation Configuration:"
    log_info "  Prefix:  $INSTALL_PREFIX"
    log_info "  Binary:  $BIN_DIR"
    log_info "  Libs:    $LIB_DIR"
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
            if [[ -f "${PROJECT_ROOT}/scripts/setup-host.sh" ]]; then
                exec "${PROJECT_ROOT}/scripts/setup-host.sh"
            else
                log_warn "Host setup script not found"
            fi
        fi
    fi
}

main "$@"
