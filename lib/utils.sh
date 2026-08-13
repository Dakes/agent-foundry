#!/usr/bin/env bash
#
# Agent Foundry - Utility Functions
#
# Common utilities used across the framework.
# Provides logging, system checks, OS detection, and cleanup handlers.
#

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
# Logging functions output to stderr and respect COLOR_OUTPUT and VERBOSE flags.
# All messages are prefixed with timestamp and level.

# Print info level message
# Usage: log_info "Your message here"
log_info() {
    local color_prefix="" color_suffix=""
    if [[ "${COLOR_OUTPUT:-false}" == "true" ]]; then
        color_prefix=$'\033[0;32m'  # Green
        color_suffix=$'\033[0m'     # Reset
    fi
    printf "%s[INFO]%s %s\n" "$color_prefix" "$color_suffix" "$*" >&2
}

# Print warning level message
# Usage: log_warn "Warning message here"
log_warn() {
    local color_prefix="" color_suffix=""
    if [[ "${COLOR_OUTPUT:-false}" == "true" ]]; then
        color_prefix=$'\033[0;33m'  # Yellow
        color_suffix=$'\033[0m'     # Reset
    fi
    printf "%s[WARN]%s %s\n" "$color_prefix" "$color_suffix" "$*" >&2
}

# Print error level message
# Usage: log_error "Error message here"
log_error() {
    local color_prefix="" color_suffix=""
    if [[ "${COLOR_OUTPUT:-false}" == "true" ]]; then
        color_prefix=$'\033[0;31m'  # Red
        color_suffix=$'\033[0m'     # Reset
    fi
    printf "%s[ERROR]%s %s\n" "$color_prefix" "$color_suffix" "$*" >&2
}

# Print debug level message (only if VERBOSE=true)
# Usage: log_debug "Debug message here"
log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        local color_prefix="" color_suffix=""
        if [[ "${COLOR_OUTPUT:-false}" == "true" ]]; then
            color_prefix=$'\033[0;36m'  # Cyan
            color_suffix=$'\033[0m'     # Reset
        fi
        printf "%s[DEBUG]%s %s\n" "$color_prefix" "$color_suffix" "$*" >&2
    fi
}

# ============================================================================
# SYSTEM CHECKS
# ============================================================================

# Check if a command exists in PATH
# Returns 0 if command exists, 1 otherwise
# Handles NixOS per-user profiles when running with elevated privileges
# Usage: check_command "firecracker" && log_info "Firecracker found"
check_command() {
    local cmd="$1"

    if [[ -z "$cmd" ]]; then
        log_error "check_command: command name required"
        return 1
    fi

    # First try standard PATH lookup
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    # On NixOS, also check per-user profile when running as root/elevated
    # This handles the case where doas/sudo can't see user nix profile paths
    if [[ -n "${SUDO_USER:-}" ]] || [[ -n "${DOAS_USER:-}" ]]; then
        local user="${SUDO_USER:-${DOAS_USER:-}}"
        if [[ -x "/etc/profiles/per-user/$user/bin/$cmd" ]]; then
            return 0
        fi
    fi

    return 1
}

# Resolve full path of a command (handles NixOS under sudo/doas)
# Usage: path=$(get_command_path "firecracker") || exit 1
get_command_path() {
    local cmd="$1"
    
    if [[ -z "$cmd" ]]; then
        return 1
    fi

    # First try standard PATH lookup
    if command -v "$cmd" >/dev/null 2>&1; then
        command -v "$cmd"
        return 0
    fi

    # On NixOS, also check per-user profile when running as root/elevated
    if [[ -n "${SUDO_USER:-}" ]] || [[ -n "${DOAS_USER:-}" ]]; then
        local user="${SUDO_USER:-${DOAS_USER:-}}"
        local user_path="/etc/profiles/per-user/$user/bin/$cmd"
        if [[ -x "$user_path" ]]; then
            echo "$user_path"
            return 0
        fi
    fi

    return 1
}

# Check if KVM support is available on the host
# Checks for /dev/kvm existence and accessibility
# Returns 0 if KVM is available and accessible, 1 otherwise
# Usage: check_kvm || { log_error "KVM not available"; exit 1; }
check_kvm() {
    # Check if /dev/kvm exists
    if [[ ! -e /dev/kvm ]]; then
        log_debug "/dev/kvm not found - KVM not supported on this system"
        return 1
    fi

    # Check if /dev/kvm is readable and writable
    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        log_debug "/dev/kvm exists but is not accessible (may need elevated privileges)"
        return 1
    fi

    log_debug "KVM support verified - /dev/kvm is accessible"
    return 0
}

# ============================================================================
# OS DETECTION
# ============================================================================

# Detect the host operating system
# Reads /etc/os-release to determine the OS
# Returns one of: arch, nixos, ubuntu, fedora, unknown
# Usage: os=$(detect_os) && log_info "Running on $os"
detect_os() {
    # Check if /etc/os-release exists
    if [[ ! -f /etc/os-release ]]; then
        log_debug "Cannot detect OS - /etc/os-release not found"
        echo "unknown"
        return 1
    fi

    # Source the file to get ID variable
    local ID=""
    local ID_LIKE=""

    # Safely source the os-release file
    if ! source /etc/os-release 2>/dev/null; then
        log_debug "Failed to parse /etc/os-release"
        echo "unknown"
        return 1
    fi

    # Check primary ID first
    case "${ID:-}" in
        arch)
            echo "arch"
            return 0
            ;;
        nixos)
            echo "nixos"
            return 0
            ;;
        ubuntu)
            echo "ubuntu"
            return 0
            ;;
        fedora)
            echo "fedora"
            return 0
            ;;
        debian)
            echo "ubuntu"  # Treat Debian like Ubuntu for compatibility
            return 0
            ;;
        *)
            # Check ID_LIKE for derivatives
            case "${ID_LIKE:-}" in
                *arch*)
                    echo "arch"
                    return 0
                    ;;
                *nixos*)
                    echo "nixos"
                    return 0
                    ;;
                *ubuntu*|*debian*)
                    echo "ubuntu"
                    return 0
                    ;;
                *fedora*|*rhel*|*centos*)
                    echo "fedora"
                    return 0
                    ;;
                *)
                    log_debug "Unknown OS: ID=$ID, ID_LIKE=$ID_LIKE"
                    echo "unknown"
                    return 1
                    ;;
            esac
            ;;
    esac
}

# ============================================================================
# USER & PATH UTILITIES
# ============================================================================

# Resolve the home directory of the host user (handling sudo/doas)
# Returns the absolute path to the user's home directory.
# Defaults to $HOME if not running under sudo/doas.
resolve_host_user() {
    local user=""

    if [[ -n "${SUDO_USER:-}" ]]; then
        user="${SUDO_USER}"
    elif [[ -n "${DOAS_USER:-}" ]]; then
        user="${DOAS_USER}"
    else
        user="${USER:-$(id -un)}"
    fi

    log_debug "resolve_host_user returned: $user"
    echo "$user"
}

resolve_host_home() {
    local user=""

    if [[ -n "${SUDO_USER:-}" ]]; then
        user="${SUDO_USER}"
    elif [[ -n "${DOAS_USER:-}" ]]; then
        user="${DOAS_USER}"
    else
        user="${USER:-$(id -un)}"
    fi

    local home=""
    if [[ -n "$user" ]] && command -v getent >/dev/null; then
        home="$(getent passwd "$user" | cut -d: -f6 || true)"
    fi

    if [[ -z "$home" ]]; then
        home="${HOME:-/root}"
    fi
    log_debug "resolve_host_home returned: $home"
    echo "$home"
}

# Numeric UID of the invoking (non-root) user.
#
# Everything Foundry runs inside a sandbox writes into the mounted volume root,
# which lives on the host filesystem. Running as root in the box would leave
# root-owned files the user cannot edit, so the sandbox user must match the
# host user's UID.
resolve_host_uid() {
    local user
    user="$(resolve_host_user)"

    local uid=""
    if [[ -n "$user" ]] && command -v id >/dev/null; then
        uid="$(id -u "$user" 2>/dev/null || true)"
    fi

    if [[ -z "$uid" ]]; then
        uid="$(id -u)"
    fi

    echo "$uid"
}

# Numeric GID of the invoking (non-root) user. See resolve_host_uid.
resolve_host_gid() {
    local user
    user="$(resolve_host_user)"

    local gid=""
    if [[ -n "$user" ]] && command -v id >/dev/null; then
        gid="$(id -g "$user" 2>/dev/null || true)"
    fi

    if [[ -z "$gid" ]]; then
        gid="$(id -g)"
    fi

    echo "$gid"
}

# ============================================================================
# USER INTERACTION
# ============================================================================

# Prompt user for confirmation
# Displays "[y/N]" prompt and returns based on response
# Returns 0 for yes/y, 1 for no/N or empty
# Usage: if confirm "Continue?"; then do_something; fi
confirm() {
    local prompt="$1"

    if [[ -z "$prompt" ]]; then
        prompt="Continue?"
    fi

    # Support auto-accept via global variable
    if [[ "${AUTO_ACCEPT:-false}" == "true" ]]; then
        log_debug "Auto-accepting prompt: $prompt"
        return 0
    fi

    # Don't show interactive prompt if not a TTY
    if [[ ! -t 0 ]]; then
        log_debug "Not running in interactive terminal - assuming no confirmation"
        return 1
    fi

    local response
    # -r: disable backslash escapes, -p: prompt
    read -r -p "${prompt} [y/N] " response

    # Match yes responses (case-insensitive)
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# CLEANUP & TRAP HANDLERS
# ============================================================================

# Track registered cleanup handlers for proper cleanup
declare -ga _CLEANUP_HANDLERS=()

# Register a cleanup handler to be called on exit
# Usage: cleanup_on_exit "rm -rf /tmp/tempdir"
# Multiple handlers can be registered and are called in reverse order
cleanup_on_exit() {
    local handler="$1"

    if [[ -z "$handler" ]]; then
        log_error "cleanup_on_exit: handler command required"
        return 1
    fi

    # Add handler to array
    _CLEANUP_HANDLERS+=("$handler")

    # Set trap only once (first time this function is called)
    if [[ ${#_CLEANUP_HANDLERS[@]} -eq 1 ]]; then
        # Install trap for EXIT, INT, TERM
        trap '_exit_handler' EXIT INT TERM
        log_debug "Cleanup handlers registered for EXIT, INT, TERM"
    fi
}

# Internal handler called on trap - executes all registered handlers
# Handlers are executed in reverse order (LIFO - Last In, First Out)
_exit_handler() {
    local exit_code=$?

    log_debug "Cleanup handler triggered (exit code: $exit_code)"

    # Execute handlers in reverse order (LIFO)
    local i
    for ((i=${#_CLEANUP_HANDLERS[@]}-1; i>=0; i--)); do
        local handler="${_CLEANUP_HANDLERS[i]}"
        log_debug "Executing cleanup: $handler"

        # Execute handler - suppress errors to ensure all handlers run
        eval "$handler" 2>/dev/null || true
    done

    exit "$exit_code"
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example usage of utility functions:
#
#   # Logging with colors
#   COLOR_OUTPUT=true VERBOSE=true ./utils.sh
#   log_info "Setup complete"
#   log_warn "Running in test mode"
#   log_error "Something went wrong"
#   log_debug "Detailed diagnostic info"
#
#   # System checks
#   check_command "firecracker" && echo "Firecracker found"
#   check_kvm && echo "KVM support verified"
#   os=$(detect_os) && echo "Running on $os"
#
#   # User interaction
#   if confirm "Continue with operation?"; then
#       echo "User confirmed"
#   else
#       echo "User cancelled"
#   fi
#
#   # Cleanup handlers
#   cleanup_on_exit "rm -f /tmp/tempfile"
#   cleanup_on_exit "pkill -f myprocess"
#   trap - EXIT  # Can be overridden later if needed
#
