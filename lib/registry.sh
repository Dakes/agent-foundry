#!/usr/bin/env bash
#
# Agent Foundry - Registry Management
#
# Functions for managing VM registry at ~/.config/foundry/vms.json
# Uses jq for JSON manipulation and flock for file locking.
#
# The registry tracks all VMs, their network configuration, and agent status.
# Registry format:
# {
#   "version": "1.0",
#   "vms": {
#     "vm-name": {
#       "ip": "172.16.0.11",
#       "tap": "tap-agent-01",
#       "disk": "/path/to/disk.ext4",
#       "kernel": "/path/to/vmlinux",
#       "status": "running",
#       "pid": 12345,
#       "cpus": 8,
#       "memory_mb": 8192,
#       "created": "2026-01-17T10:30:00Z",
#       "agent": {
#         "type": "ralph-claude-code",
#         "status": "running",
#         "session": "tmux-session-name"
#       }
#     }
#   },
#   "network": {
#     "next_ip": "172.16.0.12",
#     "next_tap_id": 2
#   }
# }

# Source utils for logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    # shellcheck source=lib/utils.sh
    source "${SCRIPT_DIR}/utils.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

FOUNDRY_HOST_HOME="$(resolve_host_home)"

# Registry file path
REGISTRY_FILE="${FOUNDRY_CONFIG_DIR:-${FOUNDRY_HOST_HOME}/.config/foundry}/vms.json"
REGISTRY_LOCK="${FOUNDRY_CONFIG_DIR:-${FOUNDRY_HOST_HOME}/.config/foundry}/registry.lock"

# Lock file descriptor - used for flock
REGISTRY_LOCK_FD=200

# ============================================================================
# LOCK MANAGEMENT
# ============================================================================

# Acquire exclusive lock on registry
# Uses flock to ensure atomic access to registry file
# This function will block until lock is acquired
# Usage: registry_lock
registry_lock() {
    local lock_dir
    lock_dir="$(dirname "$REGISTRY_LOCK")"

    # Ensure lock directory exists
    if [[ ! -d "$lock_dir" ]]; then
        log_debug "Creating registry lock directory: $lock_dir"
        mkdir -p "$lock_dir" || {
            log_error "Failed to create lock directory: $lock_dir"
            return 1
        }
    fi

    # Create lock file if it doesn't exist
    if [[ ! -f "$REGISTRY_LOCK" ]]; then
        log_debug "Creating registry lock file: $REGISTRY_LOCK"
        touch "$REGISTRY_LOCK" || {
            log_error "Failed to create lock file: $REGISTRY_LOCK"
            return 1
        }
    fi

    # Acquire exclusive lock (blocking)
    log_debug "Acquiring registry lock..."
    eval "exec ${REGISTRY_LOCK_FD}<>${REGISTRY_LOCK}"
    flock -x "$REGISTRY_LOCK_FD" || {
        log_error "Failed to acquire registry lock"
        return 1
    }

    log_debug "Registry lock acquired"
    return 0
}

# Release lock on registry
# Usage: registry_unlock
registry_unlock() {
    log_debug "Releasing registry lock..."

    # Release lock by closing file descriptor
    eval "exec ${REGISTRY_LOCK_FD}>&-" 2>/dev/null || true

    log_debug "Registry lock released"
    return 0
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Initialize registry file with default structure
# Creates ~/.config/foundry/ directory if needed
# Writes initial JSON structure with version 1.0
# Usage: registry_init
registry_init() {
    local registry_dir
    registry_dir="$(dirname "$REGISTRY_FILE")"

    log_info "Initializing registry at $REGISTRY_FILE"

    # Create config directory if it doesn't exist
    if [[ ! -d "$registry_dir" ]]; then
        log_debug "Creating registry directory: $registry_dir"
        mkdir -p "$registry_dir" || {
            log_error "Failed to create registry directory: $registry_dir"
            return 1
        }
    fi

    # Check if registry already exists
    if [[ -f "$REGISTRY_FILE" ]]; then
        log_warn "Registry file already exists at $REGISTRY_FILE"

        # Validate existing registry
        if jq empty "$REGISTRY_FILE" 2>/dev/null; then
            log_info "Existing registry is valid JSON"
            return 0
        else
            log_error "Existing registry file is corrupted - backup and reinitialize manually"
            return 1
        fi
    fi

    # Create initial registry structure
    local initial_json
    initial_json=$(jq -n '{
        version: "1.0",
        vms: {},
        network: {
            next_ip: "172.16.0.11",
            next_tap_id: 1
        }
    }')

    # Validate JSON before writing
    if ! echo "$initial_json" | jq empty 2>/dev/null; then
        log_error "Failed to generate valid initial registry JSON"
        return 1
    fi

    # Write to file
    echo "$initial_json" > "$REGISTRY_FILE" || {
        log_error "Failed to write registry file: $REGISTRY_FILE"
        return 1
    }

    # Set permissions (user read/write only)
    chmod 600 "$REGISTRY_FILE" || {
        log_error "Failed to set registry file permissions"
        return 1
    }

    log_info "Registry initialized successfully"
    return 0
}

# ============================================================================
# VM OPERATIONS
# ============================================================================

# Add VM to registry
# Usage: registry_add <vm_name> <vm_data_json>
# vm_data_json should be a valid JSON object with VM properties
registry_add() {
    local vm_name="$1"
    local vm_data="$2"

    if [[ -z "$vm_name" ]]; then
        log_error "registry_add: VM name required"
        return 1
    fi

    if [[ -z "$vm_data" ]]; then
        log_error "registry_add: VM data JSON required"
        return 1
    fi

    # Validate vm_data is valid JSON
    if ! echo "$vm_data" | jq empty 2>/dev/null; then
        log_error "registry_add: Invalid JSON provided for VM data"
        return 1
    fi

    # Ensure registry exists
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_warn "Registry does not exist - initializing"
        registry_init || return 1
    fi

    # Acquire lock
    registry_lock || return 1

    # Use trap to ensure unlock on exit
    trap 'registry_unlock' RETURN

    log_debug "Adding VM '$vm_name' to registry"

    # Check if VM already exists
    if jq -e ".vms[\"$vm_name\"]" "$REGISTRY_FILE" >/dev/null 2>&1; then
        log_error "VM '$vm_name' already exists in registry"
        return 1
    fi

    # Create temporary file for atomic write
    local temp_file="${REGISTRY_FILE}.tmp.$$"

    # Add VM to registry
    jq --arg name "$vm_name" \
       --argjson data "$vm_data" \
       '.vms[$name] = $data' \
       "$REGISTRY_FILE" > "$temp_file" || {
        log_error "Failed to add VM to registry"
        rm -f "$temp_file"
        return 1
    }

    # Validate resulting JSON
    if ! jq empty "$temp_file" 2>/dev/null; then
        log_error "Registry validation failed after adding VM"
        rm -f "$temp_file"
        return 1
    fi

    # Atomic move (use 'command' to bypass mv alias like mv -i)
    command mv "$temp_file" "$REGISTRY_FILE" || {
        log_error "Failed to write updated registry"
        rm -f "$temp_file"
        return 1
    }

    log_info "VM '$vm_name' added to registry"
    return 0
}

# Update VM field in registry
# Supports nested fields using dot notation (e.g., "agent.status")
# Usage: registry_update <vm_name> <field> <value>
registry_update() {
    local vm_name="$1"
    local field="$2"
    local value="$3"

    # Strip leading dot if present
    if [[ "${field:0:1}" == "." ]]; then
        field="${field:1}"
    fi

    if [[ -z "$vm_name" ]]; then
        log_error "registry_update: VM name required"
        return 1
    fi

    if [[ -z "$field" ]]; then
        log_error "registry_update: Field name required"
        return 1
    fi

    if [[ -z "$value" ]]; then
        log_error "registry_update: Value required"
        return 1
    fi

    # Ensure registry exists
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_error "Registry does not exist - run registry_init first"
        return 1
    fi

    # Acquire lock
    registry_lock || return 1

    # Use trap to ensure unlock on exit
    trap 'registry_unlock' RETURN

    log_debug "Updating VM '$vm_name' field '$field' to '$value'"

    # Check if VM exists
    if ! jq -e ".vms[\"$vm_name\"]" "$REGISTRY_FILE" >/dev/null 2>&1; then
        log_error "VM '$vm_name' not found in registry"
        return 1
    fi

    # Create temporary file for atomic write
    local temp_file="${REGISTRY_FILE}.tmp.$$"

    # Build jq path for nested fields
    local jq_path=".vms[\"$vm_name\"]"

    # Handle nested fields (e.g., "agent.status" -> .vms["name"].agent.status)
    if [[ "$field" == *.* ]]; then
        # Split by dots and build path
        IFS='.' read -ra PARTS <<< "$field"
        for part in "${PARTS[@]}"; do
            jq_path="${jq_path}.${part}"
        done
    else
        jq_path="${jq_path}.${field}"
    fi

    # Try to parse value as JSON, otherwise treat as string
    local jq_value
    if echo "$value" | jq empty 2>/dev/null; then
        # Value is valid JSON - use as-is
        jq_value="$value"
        jq --argjson val "$jq_value" \
           "${jq_path} = \$val" \
           "$REGISTRY_FILE" > "$temp_file" || {
            log_error "Failed to update registry"
            rm -f "$temp_file"
            return 1
        }
    else
        # Value is a string - quote it
        jq --arg val "$value" \
           "${jq_path} = \$val" \
           "$REGISTRY_FILE" > "$temp_file" || {
            log_error "Failed to update registry"
            rm -f "$temp_file"
            return 1
        }
    fi

    # Validate resulting JSON
    if ! jq empty "$temp_file" 2>/dev/null; then
        log_error "Registry validation failed after update"
        rm -f "$temp_file"
        return 1
    fi

    # Atomic move (use 'command' to bypass mv alias like mv -i)
    command mv "$temp_file" "$REGISTRY_FILE" || {
        log_error "Failed to write updated registry"
        rm -f "$temp_file"
        return 1
    }

    log_info "VM '$vm_name' field '$field' updated"
    return 0
}

# Remove VM from registry
# Usage: registry_remove <vm_name>
registry_remove() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "registry_remove: VM name required"
        return 1
    fi

    # Ensure registry exists
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_error "Registry does not exist"
        return 1
    fi

    # Acquire lock
    registry_lock || return 1

    # Use trap to ensure unlock on exit
    trap 'registry_unlock' RETURN

    log_debug "Removing VM '$vm_name' from registry"

    # Check if VM exists
    if ! jq -e ".vms[\"$vm_name\"]" "$REGISTRY_FILE" >/dev/null 2>&1; then
        log_error "VM '$vm_name' not found in registry"
        return 1
    fi

    # Create temporary file for atomic write
    local temp_file="${REGISTRY_FILE}.tmp.$$"

    # Remove VM from registry
    jq --arg name "$vm_name" \
       'del(.vms[$name])' \
       "$REGISTRY_FILE" > "$temp_file" || {
        log_error "Failed to remove VM from registry"
        rm -f "$temp_file"
        return 1
    }

    # Validate resulting JSON
    if ! jq empty "$temp_file" 2>/dev/null; then
        log_error "Registry validation failed after removal"
        rm -f "$temp_file"
        return 1
    fi

    # Atomic move (use 'command' to bypass mv alias like mv -i)
    command mv "$temp_file" "$REGISTRY_FILE" || {
        log_error "Failed to write updated registry"
        rm -f "$temp_file"
        return 1
    }

    log_info "VM '$vm_name' removed from registry"
    return 0
}

# Get VM information from registry
# If field is specified, returns only that field value
# Otherwise returns the entire VM object as JSON
# Usage: registry_get <vm_name> [field]
registry_get() {
    local vm_name="$1"
    local field="${2:-}"

    # Strip leading dot if present
    if [[ "${field:0:1}" == "." ]]; then
        field="${field:1}"
    fi

    if [[ -z "$vm_name" ]]; then
        log_error "registry_get: VM name required"
        return 1
    fi

    # Ensure registry exists
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_error "Registry does not exist at $REGISTRY_FILE"
        return 1
    fi

    log_debug "Getting info for VM '$vm_name' from $REGISTRY_FILE"

    # Check if VM exists
    if ! jq -e ".vms[\"$vm_name\"]" "$REGISTRY_FILE" >/dev/null 2>&1; then
        log_debug "VM '$vm_name' not found in registry at $REGISTRY_FILE"
        return 1
    fi

    # If no field specified, return entire VM object
    if [[ -z "$field" ]]; then
        jq -r ".vms[\"$vm_name\"]" "$REGISTRY_FILE" || {
            log_error "Failed to read VM data"
            return 1
        }
        return 0
    fi

    # Build jq path for nested fields
    local jq_path=".vms[\"$vm_name\"]"

    # Handle nested fields (e.g., "agent.status")
    if [[ "$field" == *.* ]]; then
        IFS='.' read -ra PARTS <<< "$field"
        for part in "${PARTS[@]}"; do
            jq_path="${jq_path}.${part}"
        done
    else
        jq_path="${jq_path}.${field}"
    fi

    # Get field value
    jq -r "$jq_path" "$REGISTRY_FILE" || {
        log_error "Failed to read field '$field'"
        return 1
    }

    return 0
}

# List VMs in registry
# Optional filter parameter: "running", "stopped", or empty for all
# Returns VM names, one per line
# Usage: registry_list [filter]
registry_list() {
    local filter="${1:-}"

    # Ensure registry exists
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_debug "Registry does not exist - no VMs"
        return 0
    fi

    log_debug "Listing VMs (filter: ${filter:-all})"

    # List all VMs or filter by status
    if [[ -z "$filter" ]]; then
        # Return all VM names
        jq -r '.vms | keys[]' "$REGISTRY_FILE" 2>/dev/null || {
            log_error "Failed to list VMs"
            return 1
        }
    else
        # Filter by status
        jq -r --arg status "$filter" \
           '.vms | to_entries[] | select(.value.status == $status) | .key' \
           "$REGISTRY_FILE" 2>/dev/null || {
            log_error "Failed to list VMs with filter '$filter'"
            return 1
        }
    fi

    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example usage of registry functions:
#
# # Initialize registry
# registry_init
#
# # Add a VM
# vm_data=$(jq -n '{
#   ip: "172.16.0.11",
#   tap: "tap-agent-01",
#   disk: "/var/lib/foundry/vms/my-project.ext4",
#   kernel: "/var/lib/foundry/kernels/vmlinux",
#   status: "running",
#   pid: 12345,
#   cpus: 8,
#   memory_mb: 8192,
#   created: "2026-01-17T10:30:00Z",
#   agent: {
#     type: "ralph-claude-code",
#     status: "running",
#     session: "ralph-my-project"
#   }
# }')
# registry_add "my-project" "$vm_data"
#
# # Update VM status
# registry_update "my-project" "status" "stopped"
#
# # Update nested field
# registry_update "my-project" "agent.status" "stopped"
#
# # Get entire VM info
# registry_get "my-project"
#
# # Get specific field
# ip=$(registry_get "my-project" "ip")
# echo "VM IP: $ip"
#
# # Get nested field
# agent_type=$(registry_get "my-project" "agent.type")
# echo "Agent type: $agent_type"
#
# # List all VMs
# registry_list
#
# # List only running VMs
# registry_list "running"
#
# # List only stopped VMs
# registry_list "stopped"
#
# # Remove VM
# registry_remove "my-project"
#
# # Test concurrent access with locking
# registry_lock
# # ... perform multiple registry operations ...
# registry_unlock
#
