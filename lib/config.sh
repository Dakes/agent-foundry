#!/usr/bin/env bash
#
# Agent Foundry - Configuration Management
#
# Functions for managing configuration hierarchy and persistence.
# Configuration hierarchy (later overrides earlier):
#   1. System: /etc/foundry/config.conf (if exists)
#   2. User: ~/.config/foundry/config.conf
#   3. Defaults: config/default.conf (in repo)
#

# Source utilities for logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# CONFIGURATION PATHS
# ============================================================================

# System config location
SYSTEM_CONFIG="/etc/foundry/config.conf"

# Resolve real user home
HOST_HOME="$(resolve_host_home)"

# User config directory
USER_CONFIG_DIR="${FOUNDRY_CONFIG_DIR:-${HOST_HOME}/.config/foundry}"
USER_CONFIG="${USER_CONFIG_DIR}/config.conf"

# Data directory
DATA_DIR="${FOUNDRY_DATA_DIR:-${HOST_HOME}/.local/share/foundry}"

# Default config location (relative to project root)
# Allow override via FOUNDRY_BASE_DIR (set by release bundles)
PROJECT_ROOT="${FOUNDRY_BASE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DEFAULT_CONFIG="${PROJECT_ROOT}/config/default.conf"

# ============================================================================
# INITIALIZATION
# ============================================================================

# Initialize configuration directories and default config
# Creates ~/.config/foundry/ and ~/.local/share/foundry/ structure
# Copies default config if user config doesn't exist
#
# Returns: 0 on success, 1 on failure
config_init() {
    log_info "Initializing Agent Foundry configuration"

    # Create user config directory
    if [[ ! -d "$USER_CONFIG_DIR" ]]; then
        log_debug "Creating config directory: $USER_CONFIG_DIR"
        if ! mkdir -p "$USER_CONFIG_DIR"; then
            log_error "Failed to create config directory: $USER_CONFIG_DIR"
            return 1
        fi
        chmod 755 "$USER_CONFIG_DIR"
    else
        log_debug "Config directory already exists: $USER_CONFIG_DIR"
    fi

    # Copy default config if user config doesn't exist
    if [[ ! -f "$USER_CONFIG" ]]; then
        if [[ ! -f "$DEFAULT_CONFIG" ]]; then
            log_error "Default config not found: $DEFAULT_CONFIG"
            return 1
        fi

        log_info "Creating user config from defaults: $USER_CONFIG"
        if ! cp "$DEFAULT_CONFIG" "$USER_CONFIG"; then
            log_error "Failed to copy default config to: $USER_CONFIG"
            return 1
        fi
        chmod 644 "$USER_CONFIG"
    else
        log_debug "User config already exists: $USER_CONFIG"
    fi

    # Create data directory structure
    local subdirs=(
        "vms/templates"
        "vms/instances"
        "vms/kernels"
        "logs"
    )

    for subdir in "${subdirs[@]}"; do
        local dir="${DATA_DIR}/${subdir}"
        if [[ ! -d "$dir" ]]; then
            log_debug "Creating data directory: $dir"
            if ! mkdir -p "$dir"; then
                log_error "Failed to create data directory: $dir"
                return 1
            fi
            chmod 755 "$dir"
        else
            log_debug "Data directory already exists: $dir"
        fi
    done

    log_info "Configuration initialization complete"
    return 0
}

# ============================================================================
# CONFIGURATION READING
# ============================================================================

# Get configuration value by key
# Loads all configs in hierarchy and returns the final value
# Supports nested keys with dots (e.g., "default.cpus")
#
# Args:
#   $1 - Configuration key (e.g., "DEFAULT_CPUS" or "default.cpus")
#
# Returns: Prints value to stdout, returns 1 if key not found
#
# Example:
#   cpus=$(config_get "DEFAULT_CPUS")
#   memory=$(config_get "default.memory")
config_get() {
    local key="$1"

    if [[ -z "$key" ]]; then
        log_error "config_get: key required"
        return 1
    fi

    # Normalize key - convert dots to underscores and uppercase
    # This allows both "default.cpus" and "DEFAULT_CPUS" syntax
    local normalized_key="${key//\./_}"
    normalized_key="${normalized_key^^}"

    log_debug "Getting config value for key: $key (normalized: $normalized_key)"

    # Declare associative array for config values
    declare -A config_values

    # Load configs in order: defaults → system → user (later overrides earlier)
    local config_files=()

    # 1. Default config (always exists in repo)
    if [[ -f "$DEFAULT_CONFIG" ]]; then
        config_files+=("$DEFAULT_CONFIG")
        log_debug "Loading default config: $DEFAULT_CONFIG"
    fi

    # 2. System config (optional)
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        config_files+=("$SYSTEM_CONFIG")
        log_debug "Loading system config: $SYSTEM_CONFIG"
    fi

    # 3. User config (created by config_init)
    if [[ -f "$USER_CONFIG" ]]; then
        config_files+=("$USER_CONFIG")
        log_debug "Loading user config: $USER_CONFIG"
    fi

    # Parse all config files and build merged config
    for config_file in "${config_files[@]}"; do
        while IFS='=' read -r conf_key conf_value; do
            # Skip empty lines and comments
            [[ -z "$conf_key" || "$conf_key" =~ ^[[:space:]]*# ]] && continue

            # Trim whitespace
            conf_key="${conf_key#"${conf_key%%[![:space:]]*}"}"
            conf_key="${conf_key%"${conf_key##*[![:space:]]}"}"
            conf_value="${conf_value#"${conf_value%%[![:space:]]*}"}"
            conf_value="${conf_value%"${conf_value##*[![:space:]]}"}"

            # Remove quotes from value if present
            if [[ "$conf_value" =~ ^\"(.*)\"$ ]]; then
                conf_value="${BASH_REMATCH[1]}"
            elif [[ "$conf_value" =~ ^\'(.*)\'$ ]]; then
                conf_value="${BASH_REMATCH[1]}"
            fi

            # Store in associative array (later values override earlier)
            config_values["$conf_key"]="$conf_value"
            log_debug "  Loaded: $conf_key = $conf_value"
        done < "$config_file"
    done

    # Return the value for the requested key
    if [[ -v config_values["$normalized_key"] ]]; then
        local value="${config_values[$normalized_key]}"
        log_debug "Found value for $normalized_key: $value"
        echo "$value"
        return 0
    else
        log_debug "Key not found: $normalized_key"
        return 1
    fi
}

# ============================================================================
# CONFIGURATION WRITING
# ============================================================================

# Set configuration value in user config
# Updates ~/.config/foundry/config.conf atomically
# Preserves comments and formatting, only updates the specified key
#
# Args:
#   $1 - Configuration key (e.g., "DEFAULT_CPUS" or "default.cpus")
#   $2 - New value
#
# Returns: 0 on success, 1 on failure
#
# Example:
#   config_set "DEFAULT_CPUS" "8"
#   config_set "default.memory" "16384"
config_set() {
    local key="$1"
    local value="$2"

    if [[ -z "$key" ]]; then
        log_error "config_set: key required"
        return 1
    fi

    # Value can be empty (unset)

    # Normalize key - convert dots to underscores and uppercase
    local normalized_key="${key//\./_}"
    normalized_key="${normalized_key^^}"

    log_info "Setting config: $normalized_key = $value"

    # Ensure user config exists
    if [[ ! -f "$USER_CONFIG" ]]; then
        log_warn "User config does not exist, creating from defaults"
        if ! config_init; then
            log_error "Failed to initialize config"
            return 1
        fi
    fi

    # Create temporary file for atomic write
    local temp_config="${USER_CONFIG}.tmp.$$"

    # Track if key was found and updated
    local key_found=false

    # Read config line by line, update matching key
    while IFS= read -r line; do
        # Check if line starts with our key (allowing whitespace)
        if [[ "$line" =~ ^[[:space:]]*${normalized_key}[[:space:]]*= ]]; then
            # Found the key, replace with new value
            if [[ -n "$value" ]]; then
                echo "${normalized_key}=${value}"
            else
                # Empty value
                echo "${normalized_key}="
            fi
            key_found=true
            log_debug "Updated existing key: $normalized_key"
        else
            # Keep line as-is
            echo "$line"
        fi
    done < "$USER_CONFIG" > "$temp_config"

    # If key wasn't found, append it
    if [[ "$key_found" == "false" ]]; then
        if [[ -n "$value" ]]; then
            echo "${normalized_key}=${value}" >> "$temp_config"
        else
            echo "${normalized_key}=" >> "$temp_config"
        fi
        log_debug "Added new key: $normalized_key"
    fi

    # Atomic move (replaces old file)
    if ! mv "$temp_config" "$USER_CONFIG"; then
        log_error "Failed to write config file: $USER_CONFIG"
        rm -f "$temp_config"
        return 1
    fi

    chmod 644 "$USER_CONFIG"
    log_info "Configuration updated successfully"
    return 0
}

# ============================================================================
# CONFIGURATION EDITING
# ============================================================================

# Open user config in editor
# Opens ~/.config/foundry/config.conf in $EDITOR
# Creates config if it doesn't exist
# Validates syntax after editing (basic check for KEY=value format)
#
# Returns: 0 on success, 1 on failure
#
# Example:
#   config_edit
config_edit() {
    log_info "Opening config for editing"

    # Check if EDITOR is set
    if [[ -z "${EDITOR:-}" ]]; then
        log_error "EDITOR environment variable not set"
        log_error "Set EDITOR to your preferred editor: export EDITOR=vim"
        return 1
    fi

    # Check if editor command exists
    local editor_cmd="${EDITOR%% *}"  # Get first word (command name)
    if ! check_command "$editor_cmd"; then
        log_error "Editor not found: $editor_cmd"
        return 1
    fi

    # Ensure config exists
    if [[ ! -f "$USER_CONFIG" ]]; then
        log_warn "User config does not exist, creating from defaults"
        if ! config_init; then
            log_error "Failed to initialize config"
            return 1
        fi
    fi

    # Create backup before editing
    local backup="${USER_CONFIG}.backup"
    if ! cp "$USER_CONFIG" "$backup"; then
        log_error "Failed to create backup: $backup"
        return 1
    fi
    log_debug "Created backup: $backup"

    # Open in editor
    log_info "Opening $USER_CONFIG in $EDITOR"
    if ! $EDITOR "$USER_CONFIG"; then
        log_error "Editor exited with error"
        # Restore backup
        log_warn "Restoring backup"
        cp "$backup" "$USER_CONFIG"
        return 1
    fi

    # Basic syntax validation
    log_debug "Validating config syntax"
    local line_num=0
    local has_errors=false

    while IFS= read -r line; do
        ((line_num++))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Check for KEY=value format
        if ! [[ "$line" =~ ^[[:space:]]*[A-Z_][A-Z0-9_]*[[:space:]]*= ]]; then
            log_error "Syntax error on line $line_num: $line"
            log_error "Expected format: KEY=value"
            has_errors=true
        fi
    done < "$USER_CONFIG"

    if [[ "$has_errors" == "true" ]]; then
        log_error "Config validation failed"
        log_warn "Backup available at: $backup"
        if confirm "Restore backup?"; then
            cp "$backup" "$USER_CONFIG"
            log_info "Backup restored"
        fi
        return 1
    fi

    # Validation passed
    log_info "Config validated successfully"
    rm -f "$backup"
    return 0
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

# Load all configuration into environment variables
# Sources all config files in hierarchy order
# Exports all variables for use in child processes
# Handles missing files gracefully
#
# Returns: 0 on success, 1 on failure
#
# Example:
#   config_load
#   echo "Default CPUs: $DEFAULT_CPUS"
config_load() {
    log_info "Loading configuration into environment"

    # Load configs in order: defaults → system → user (later overrides earlier)
    local config_files=()

    # 1. Default config (always exists in repo)
    if [[ -f "$DEFAULT_CONFIG" ]]; then
        config_files+=("$DEFAULT_CONFIG")
    else
        log_error "Default config not found: $DEFAULT_CONFIG"
        return 1
    fi

    # 2. System config (optional)
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        config_files+=("$SYSTEM_CONFIG")
    else
        log_debug "System config not found (optional): $SYSTEM_CONFIG"
    fi

    # 3. User config (created by config_init)
    if [[ -f "$USER_CONFIG" ]]; then
        config_files+=("$USER_CONFIG")
    else
        log_warn "User config not found: $USER_CONFIG"
        log_warn "Run 'foundry config init' to initialize"
    fi

    # Source each config file
    for config_file in "${config_files[@]}"; do
        log_debug "Loading config: $config_file"

        # Source the config file in a subshell to validate it first
        if ! (set -e; source "$config_file" >/dev/null 2>&1); then
            log_error "Failed to load config: $config_file"
            return 1
        fi

        # Source into current shell and export all variables
        # shellcheck disable=SC1090
        set -a  # Mark all variables for export
        source "$config_file"
        set +a  # Disable auto-export
    done

    log_info "Configuration loaded successfully"
    log_debug "Config values:"
    log_debug "  DEFAULT_CPUS=${DEFAULT_CPUS:-<unset>}"
    log_debug "  DEFAULT_MEMORY=${DEFAULT_MEMORY:-<unset>}"
    log_debug "  DEFAULT_DISK=${DEFAULT_DISK:-<unset>}"
    log_debug "  GATEWAY_IP=${GATEWAY_IP:-<unset>}"
    log_debug "  CONFIG_DIR=${CONFIG_DIR:-<unset>}"

    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example usage of configuration functions:
#
#   # Initialize configuration
#   config_init
#   # Creates ~/.config/foundry/ and ~/.local/share/foundry/ structure
#   # Copies default config to ~/.config/foundry/config.conf
#
#   # Get configuration values
#   cpus=$(config_get "DEFAULT_CPUS")
#   memory=$(config_get "default.memory")  # Dot notation also works
#   echo "CPUs: $cpus, Memory: $memory"
#
#   # Set configuration values
#   config_set "DEFAULT_CPUS" "8"
#   config_set "default.memory" "16384"
#
#   # Edit config interactively
#   EDITOR=vim config_edit
#
#   # Load all config into environment
#   config_load
#   echo "Gateway IP: $GATEWAY_IP"
#   echo "Template dir: $TEMPLATE_DIR"
#
# Test configuration hierarchy:
#
#   # 1. Create test configs
#   mkdir -p /tmp/test-foundry/{config,data}
#
#   # 2. Set up defaults (lowest priority)
#   echo "DEFAULT_CPUS=4" > /tmp/test-foundry/default.conf
#   echo "DEFAULT_MEMORY=8192" >> /tmp/test-foundry/default.conf
#
#   # 3. Override in user config (highest priority)
#   echo "DEFAULT_CPUS=8" > /tmp/test-foundry/config/config.conf
#
#   # 4. Test hierarchy
#   FOUNDRY_CONFIG_DIR=/tmp/test-foundry/config \
#   DEFAULT_CONFIG=/tmp/test-foundry/default.conf \
#   config_get "DEFAULT_CPUS"
#   # Should return: 8 (from user config)
#
#   config_get "DEFAULT_MEMORY"
#   # Should return: 8192 (from default config)
#
# Test atomic writes:
#
#   # Set a value
#   config_set "TEST_KEY" "value1"
#
#   # Update the same key
#   config_set "TEST_KEY" "value2"
#
#   # Verify only one entry exists
#   grep -c "TEST_KEY" ~/.config/foundry/config.conf
#   # Should return: 1
#
