#!/usr/bin/env bash
#
# Agent Foundry - VM Lifecycle Management
#
# Functions for managing Firecracker microVM lifecycle including creation,
# starting, stopping, destroying, SSH access, copying, and snapshots.
#
# VM storage layout:
# ~/.local/share/foundry/vms/
# ├── templates/      # Base and golden templates
# ├── instances/      # Running VM disks
# ├── kernels/        # Firecracker kernels
# └── sockets/        # Firecracker API sockets
#

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    source "${SCRIPT_DIR}/utils.sh"
fi
if [[ -f "${SCRIPT_DIR}/registry.sh" ]]; then
    source "${SCRIPT_DIR}/registry.sh"
fi
if [[ -f "${SCRIPT_DIR}/network.sh" ]]; then
    source "${SCRIPT_DIR}/network.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

FOUNDRY_HOST_HOME="$(resolve_host_home)"
FOUNDRY_DATA_DIR="${FOUNDRY_DATA_DIR:-${FOUNDRY_HOST_HOME}/.local/share/foundry}"
FOUNDRY_VMS_DIR="${FOUNDRY_DATA_DIR}/vms"
FOUNDRY_TEMPLATES_DIR="${FOUNDRY_VMS_DIR}/templates"
FOUNDRY_INSTANCES_DIR="${FOUNDRY_VMS_DIR}/instances"
FOUNDRY_KERNELS_DIR="${FOUNDRY_VMS_DIR}/kernels"
FOUNDRY_SOCKETS_DIR="${FOUNDRY_VMS_DIR}/sockets"
FOUNDRY_LOGS_DIR="${FOUNDRY_DATA_DIR}/logs"

# Default VM resources
FOUNDRY_DEFAULT_CPUS="${FOUNDRY_DEFAULT_CPUS:-4}"
FOUNDRY_DEFAULT_MEMORY_MB="${FOUNDRY_DEFAULT_MEMORY_MB:-8192}"
FOUNDRY_DEFAULT_KERNEL="${FOUNDRY_DEFAULT_KERNEL:-vmlinux}"
FOUNDRY_DEFAULT_TEMPLATE="${FOUNDRY_DEFAULT_TEMPLATE:-golden.ext4}"

# SSH settings
FOUNDRY_SSH_USER="${FOUNDRY_SSH_USER:-root}"
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

_require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges"
        return 1
    fi
    return 0
}

_vm_exists() {
    local name="$1"
    registry_get "$name" ".status" >/dev/null
}

_validate_vm_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "VM name required"
        return 1
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        log_error "Invalid VM name: $name (use lowercase alphanumeric, hyphens, underscores)"
        return 1
    fi
    return 0
}

_ensure_dirs() {
    mkdir -p "$FOUNDRY_TEMPLATES_DIR" "$FOUNDRY_INSTANCES_DIR" \
             "$FOUNDRY_KERNELS_DIR" "$FOUNDRY_SOCKETS_DIR" "$FOUNDRY_LOGS_DIR"
}

_get_socket_path() {
    local name="$1"
    echo "${FOUNDRY_SOCKETS_DIR}/${name}.sock"
}

_get_disk_path() {
    local name="$1"
    echo "${FOUNDRY_INSTANCES_DIR}/${name}.ext4"
}

_get_log_path() {
    local name="$1"
    echo "${FOUNDRY_LOGS_DIR}/${name}-firecracker.log"
}

# Generate Firecracker config from template
_generate_fc_config() {
    local name="$1"
    local disk_path="$2"
    local kernel_path="$3"
    local tap_name="$4"
    local vcpu_count="$5"
    local mem_size_mib="$6"
    local vm_ip="$7"

    local socket_path
    socket_path=$(_get_socket_path "$name")

    # Generate inline config
    cat <<EOF
{
  "boot-source": {
    "kernel_image_path": "$kernel_path",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=${vm_ip}::${FOUNDRY_GATEWAY}:255.255.255.0::eth0:off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$disk_path",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "$(printf '02:FC:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))",
      "host_dev_name": "$tap_name"
    }
  ],
  "machine-config": {
    "vcpu_count": $vcpu_count,
    "mem_size_mib": $mem_size_mib,
    "smt": false
  }
}
EOF
}

# Wait for VM to be reachable via SSH
_wait_for_ssh() {
    local ip="$1"
    local timeout="${2:-60}"
    local elapsed=0

    log_debug "Waiting for SSH on $ip (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        if ssh $FOUNDRY_SSH_OPTS -o ConnectTimeout=2 "${FOUNDRY_SSH_USER}@${ip}" "true" 2>/dev/null; then
            log_debug "SSH available on $ip after ${elapsed}s"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "SSH not available on $ip after ${timeout}s"
    return 1
}

# ============================================================================
# VM CREATION
# ============================================================================

# Create a new VM from template
# Usage: vm_create <name> [template]
vm_create() {
    local name="$1"
    local template="${2:-$FOUNDRY_DEFAULT_TEMPLATE}"

    _validate_vm_name "$name" || return 1
    _require_root || return 1
    _ensure_dirs

    # Check if VM already exists
    if _vm_exists "$name"; then
        log_error "VM '$name' already exists"
        return 1
    fi

    # Verify template exists
    local template_path="${FOUNDRY_TEMPLATES_DIR}/${template}"
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        log_info "Available templates:"
        ls -1 "$FOUNDRY_TEMPLATES_DIR" 2>/dev/null || echo "  (none)"
        return 1
    fi

    # Verify kernel exists
    local kernel_path="${FOUNDRY_KERNELS_DIR}/${FOUNDRY_DEFAULT_KERNEL}"
    if [[ ! -f "$kernel_path" ]]; then
        log_error "Kernel not found: $kernel_path"
        return 1
    fi

    log_info "Creating VM '$name' from template '$template'..."

    # Copy template disk using COW if available
    local disk_path
    disk_path=$(_get_disk_path "$name")
    log_debug "Copying template to $disk_path..."

    if cp --reflink=auto "$template_path" "$disk_path"; then
        log_debug "Disk copied (COW if supported)"
    else
        log_error "Failed to copy template disk"
        return 1
    fi

    # Allocate IP address
    local vm_ip
    vm_ip=$(network_allocate_ip "$name") || {
        log_error "Failed to allocate IP"
        rm -f "$disk_path"
        return 1
    }

    # Create TAP device
    local tap_name
    tap_name=$(network_create_tap "$name") || {
        log_error "Failed to create TAP device"
        rm -f "$disk_path"
        return 1
    }

    # Register VM
    local created_at
    created_at=$(date -Iseconds)

    registry_add "$name" "{
        \"ip\": \"$vm_ip\",
        \"tap\": \"$tap_name\",
        \"disk\": \"$disk_path\",
        \"kernel\": \"$kernel_path\",
        \"status\": \"stopped\",
        \"pid\": null,
        \"cpus\": $FOUNDRY_DEFAULT_CPUS,
        \"memory_mb\": $FOUNDRY_DEFAULT_MEMORY_MB,
        \"created\": \"$created_at\",
        \"template\": \"$template\",
        \"agent\": {
            \"type\": null,
            \"status\": \"stopped\",
            \"session\": null
        }
    }" || {
        log_error "Failed to register VM"
        rm -f "$disk_path"
        network_destroy_tap "$name"
        return 1
    }

    log_info "VM '$name' created successfully"
    log_info "  IP: $vm_ip"
    log_info "  TAP: $tap_name"
    log_info "  Disk: $disk_path"

    return 0
}

# ============================================================================
# VM LIFECYCLE
# ============================================================================

# Start a stopped VM
# Usage: vm_start <name>
vm_start() {
    local name="$1"

    _validate_vm_name "$name" || return 1
    _require_root || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    # Check current status
    local status
    status=$(registry_get "$name" ".status")
    if [[ "$status" == "running" ]]; then
        log_warn "VM '$name' is already running"
        return 0
    fi

    log_info "Starting VM '$name'..."

    # Get VM configuration
    local disk_path kernel_path tap_name vm_ip cpus memory_mb
    disk_path=$(registry_get "$name" ".disk")
    kernel_path=$(registry_get "$name" ".kernel")
    tap_name=$(registry_get "$name" ".tap")
    vm_ip=$(registry_get "$name" ".ip")
    cpus=$(registry_get "$name" ".cpus")
    memory_mb=$(registry_get "$name" ".memory_mb")

    # Verify files exist
    if [[ ! -f "$disk_path" ]]; then
        log_error "Disk not found: $disk_path"
        return 1
    fi
    if [[ ! -f "$kernel_path" ]]; then
        log_error "Kernel not found: $kernel_path"
        return 1
    fi

    # Ensure TAP device exists
    if ! ip link show "$tap_name" >/dev/null 2>&1; then
        log_debug "Recreating TAP device $tap_name..."
        ip tuntap add dev "$tap_name" mode tap || return 1
        ip link set "$tap_name" up || return 1
    fi
    
    # Always ensure TAP is attached to bridge and UP
    if ! bridge link show dev "$tap_name" >/dev/null 2>&1; then
        log_debug "Attaching $tap_name to $FOUNDRY_BRIDGE..."
        ip link set "$tap_name" master "$FOUNDRY_BRIDGE" || return 1
    fi
    ip link set "$tap_name" up || return 1
    ip link set "$FOUNDRY_BRIDGE" up || return 1

    # Generate config
    local fc_config
    fc_config=$(_generate_fc_config "$name" "$disk_path" "$kernel_path" "$tap_name" "$cpus" "$memory_mb" "$vm_ip")

    local socket_path log_path
    socket_path=$(_get_socket_path "$name")
    log_path=$(_get_log_path "$name")

    # Remove stale socket
    rm -f "$socket_path"

    # Resolve firecracker binary (handle NixOS path issues)
    local fc_bin
    fc_bin=$(get_command_path "firecracker") || {
        log_error "Firecracker binary not found. Ensure it is installed and in PATH."
        return 1
    }

    # Start Firecracker
    log_debug "Starting Firecracker ($fc_bin)..."
    log_debug "Command: $fc_bin --api-sock $socket_path --config-file /dev/stdin"

    "$fc_bin" --api-sock "$socket_path" --config-file /dev/stdin \
        > "$log_path" 2>&1 <<< "$fc_config" &

    local fc_pid=$!

    # Brief wait to check if process started
    sleep 1
    if ! kill -0 "$fc_pid" 2>/dev/null; then
        log_error "Firecracker failed to start. Check log: $log_path"
        return 1
    fi

    # Update registry
    registry_update "$name" ".status" "running"
    registry_update "$name" ".pid" "$fc_pid"

    log_info "VM '$name' started (PID: $fc_pid)"

    # Wait for SSH (optional, non-blocking info)
    if _wait_for_ssh "$vm_ip" 30; then
        log_info "VM '$name' is ready: ssh ${FOUNDRY_SSH_USER}@${vm_ip}"
    else
        log_warn "VM started but SSH not yet available at $vm_ip"
    fi

    return 0
}

# Stop a running VM
# Usage: vm_stop <name>
vm_stop() {
    local name="$1"

    _validate_vm_name "$name" || return 1
    _require_root || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    local status
    status=$(registry_get "$name" ".status")
    if [[ "$status" != "running" ]]; then
        log_debug "VM '$name' is not running (status: $status)"
        return 0
    fi

    log_info "Stopping VM '$name'..."

    local pid vm_ip
    pid=$(registry_get "$name" ".pid")
    vm_ip=$(registry_get "$name" ".ip")

    # Try graceful shutdown via SSH first
    if [[ -n "$vm_ip" ]]; then
        log_debug "Attempting graceful shutdown..."
        ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "poweroff" 2>/dev/null || true
        sleep 3
    fi

    # Check if process is still running
    if [[ -n "$pid" && "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null; then
        log_debug "Sending SIGTERM to Firecracker (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Forcing kill..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi

    # Clean up socket
    local socket_path
    socket_path=$(_get_socket_path "$name")
    rm -f "$socket_path"

    # Update registry
    registry_update "$name" ".status" "stopped"
    registry_update "$name" ".pid" "null"

    log_info "VM '$name' stopped"
    return 0
}

# Restart a VM
# Usage: vm_restart <name>
vm_restart() {
    local name="$1"
    _validate_vm_name "$name" || return 1

    log_info "Restarting VM '$name'..."
    vm_stop "$name" || return 1
    sleep 1
    vm_start "$name" || return 1
    return 0
}

# Destroy a VM (stop, delete disk, release network)
# Usage: vm_destroy <name>
vm_destroy() {
    local name="$1"

    _validate_vm_name "$name" || return 1
    _require_root || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    log_info "Destroying VM '$name'..."

    # Stop if running
    local status
    status=$(registry_get "$name" ".status")
    if [[ "$status" == "running" ]]; then
        vm_stop "$name"
    fi

    # Get paths before removing from registry
    local disk_path tap_name
    disk_path=$(registry_get "$name" ".disk")
    tap_name=$(registry_get "$name" ".tap")

    # Destroy TAP device
    network_destroy_tap "$name" || true

    # Release IP (handled by registry removal)
    network_release_ip "$name" || true

    # Delete disk
    if [[ -n "$disk_path" && -f "$disk_path" ]]; then
        log_debug "Removing disk: $disk_path"
        rm -f "$disk_path"
    fi

    # Remove socket and log
    rm -f "$(_get_socket_path "$name")"
    rm -f "$(_get_log_path "$name")"

    # Remove from registry
    registry_remove "$name"

    log_info "VM '$name' destroyed"
    return 0
}

# ============================================================================
# VM ACCESS
# ============================================================================

# SSH into VM or run command
# Usage: vm_ssh <name> [command...]
vm_ssh() {
    local name="$1"
    shift
    local cmd=("$@")

    _validate_vm_name "$name" || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    local status vm_ip
    status=$(registry_get "$name" ".status")
    vm_ip=$(registry_get "$name" ".ip")

    if [[ "$status" != "running" ]]; then
        log_error "VM '$name' is not running"
        return 1
    fi

    if [[ ${#cmd[@]} -eq 0 ]]; then
        # Interactive SSH
        exec ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}"
    else
        # Run command
        ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "${cmd[@]}"
    fi
}

# ============================================================================
# VM INFORMATION
# ============================================================================

# List all VMs
# Usage: vm_list
vm_list() {
    log_info "Agent Foundry VMs:"
    echo ""

    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo "  No VMs registered (registry not initialized)"
        return 0
    fi

    local vms
    vms=$(jq -r '.vms | to_entries[] | "\(.key)|\(.value.ip)|\(.value.status)|\(.value.cpus)|\(.value.memory_mb)|\(.value.agent.type // "none")"' "$REGISTRY_FILE" 2>/dev/null)

    if [[ -z "$vms" ]]; then
        echo "  No VMs found"
        return 0
    fi

    printf "  %-20s %-15s %-10s %-6s %-8s %s\n" "NAME" "IP" "STATUS" "CPUS" "RAM(MB)" "AGENT"
    printf "  %-20s %-15s %-10s %-6s %-8s %s\n" "----" "--" "------" "----" "-------" "-----"

    echo "$vms" | while IFS='|' read -r name ip status cpus mem agent; do
        printf "  %-20s %-15s %-10s %-6s %-8s %s\n" "$name" "$ip" "$status" "$cpus" "$mem" "$agent"
    done

    return 0
}

# Show single VM status
# Usage: vm_status <name>
vm_status() {
    local name="$1"

    _validate_vm_name "$name" || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    local vm_data
    vm_data=$(registry_get "$name" ".")

    echo "VM: $name"
    echo "$vm_data" | jq -r '
        "  Status: \(.status)",
        "  IP: \(.ip)",
        "  TAP: \(.tap)",
        "  CPUs: \(.cpus)",
        "  Memory: \(.memory_mb) MB",
        "  Disk: \(.disk)",
        "  Kernel: \(.kernel)",
        "  Created: \(.created)",
        "  Template: \(.template // "unknown")",
        "  PID: \(.pid // "none")",
        "",
        "  Agent:",
        "    Type: \(.agent.type // "none")",
        "    Status: \(.agent.status // "unknown")",
        "    Session: \(.agent.session // "none")"
    '

    return 0
}

# Get VM IP address
# Usage: vm_ip <name>
vm_ip() {
    local name="$1"
    _validate_vm_name "$name" || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    registry_get "$name" ".ip"
}

# ============================================================================
# VM COPY & SNAPSHOT
# ============================================================================

# Copy a VM
# Usage: vm_copy <source> <dest>
vm_copy() {
    local source="$1"
    local dest="$2"

    _validate_vm_name "$source" || return 1
    _validate_vm_name "$dest" || return 1
    _require_root || return 1

    if ! _vm_exists "$source"; then
        log_error "Source VM '$source' does not exist"
        return 1
    fi

    if _vm_exists "$dest"; then
        log_error "Destination VM '$dest' already exists"
        return 1
    fi

    # Source must be stopped
    local status
    status=$(registry_get "$source" ".status")
    if [[ "$status" == "running" ]]; then
        log_error "Cannot copy running VM. Stop '$source' first"
        return 1
    fi

    log_info "Copying VM '$source' to '$dest'..."

    # Get source disk
    local source_disk dest_disk
    source_disk=$(registry_get "$source" ".disk")
    dest_disk=$(_get_disk_path "$dest")

    # Copy disk with COW
    log_debug "Copying disk (COW if supported)..."
    cp --reflink=auto "$source_disk" "$dest_disk" || {
        log_error "Failed to copy disk"
        return 1
    }

    # Allocate new network resources
    local vm_ip tap_name
    vm_ip=$(network_allocate_ip "$dest") || {
        rm -f "$dest_disk"
        return 1
    }
    tap_name=$(network_create_tap "$dest") || {
        rm -f "$dest_disk"
        return 1
    }

    # Get source config
    local kernel_path cpus memory_mb template
    kernel_path=$(registry_get "$source" ".kernel")
    cpus=$(registry_get "$source" ".cpus")
    memory_mb=$(registry_get "$source" ".memory_mb")
    template=$(registry_get "$source" ".template")

    # Register new VM
    local created_at
    created_at=$(date -Iseconds)

    registry_add "$dest" "{
        \"ip\": \"$vm_ip\",
        \"tap\": \"$tap_name\",
        \"disk\": \"$dest_disk\",
        \"kernel\": \"$kernel_path\",
        \"status\": \"stopped\",
        \"pid\": null,
        \"cpus\": $cpus,
        \"memory_mb\": $memory_mb,
        \"created\": \"$created_at\",
        \"template\": \"$template\",
        \"copied_from\": \"$source\",
        \"agent\": {
            \"type\": null,
            \"status\": \"stopped\",
            \"session\": null
        }
    }"

    log_info "VM copied: '$source' -> '$dest'"
    log_info "  New IP: $vm_ip"

    return 0
}

# Rename a VM
# Usage: vm_rename <old_name> <new_name>
vm_rename() {
    local old_name="$1"
    local new_name="$2"

    _validate_vm_name "$old_name" || return 1
    _validate_vm_name "$new_name" || return 1
    _require_root || return 1

    if ! _vm_exists "$old_name"; then
        log_error "VM '$old_name' does not exist"
        return 1
    fi

    if _vm_exists "$new_name"; then
        log_error "VM '$new_name' already exists"
        return 1
    fi

    # Must be stopped
    local status
    status=$(registry_get "$old_name" ".status")
    if [[ "$status" == "running" ]]; then
        log_error "Cannot rename running VM. Stop '$old_name' first"
        return 1
    fi

    log_info "Renaming VM '$old_name' to '$new_name'..."

    # Rename disk file
    local old_disk new_disk
    old_disk=$(registry_get "$old_name" ".disk")
    new_disk=$(_get_disk_path "$new_name")

    mv "$old_disk" "$new_disk" || {
        log_error "Failed to rename disk"
        return 1
    }

    # Get current data and update
    local vm_data
    vm_data=$(registry_get "$old_name" ".")

    # Remove old entry
    registry_remove "$old_name"

    # Add with new name and updated disk path
    echo "$vm_data" | jq --arg disk "$new_disk" '.disk = $disk' | \
        xargs -0 -I {} registry_add "$new_name" "{}"

    # Manual approach since jq output is tricky
    registry_add "$new_name" "$(echo "$vm_data" | jq --arg disk "$new_disk" '.disk = $disk')"

    log_info "VM renamed: '$old_name' -> '$new_name'"

    return 0
}

# Create snapshot of VM
# Usage: vm_snapshot <name> <snapshot_name>
vm_snapshot() {
    local name="$1"
    local snapshot_name="$2"

    _validate_vm_name "$name" || return 1

    if [[ -z "$snapshot_name" ]]; then
        log_error "Snapshot name required"
        return 1
    fi

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    # Must be stopped for consistent snapshot
    local status
    status=$(registry_get "$name" ".status")
    if [[ "$status" == "running" ]]; then
        log_warn "Snapshotting running VM - disk may be inconsistent"
    fi

    log_info "Creating snapshot '$snapshot_name' of VM '$name'..."

    local disk_path snapshot_path
    disk_path=$(registry_get "$name" ".disk")
    snapshot_path="${FOUNDRY_TEMPLATES_DIR}/${snapshot_name}.ext4"

    # Copy disk to templates
    cp --reflink=auto "$disk_path" "$snapshot_path" || {
        log_error "Failed to create snapshot"
        return 1
    }

    log_info "Snapshot created: $snapshot_path"
    log_info "Use as template with: foundry vm create <name> ${snapshot_name}.ext4"

    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example workflow:
#
#   # Create VM from golden template
#   sudo vm_create my-project golden.ext4
#
#   # Start the VM
#   sudo vm_start my-project
#
#   # SSH into VM
#   vm_ssh my-project
#
#   # Run command in VM
#   vm_ssh my-project "uname -a"
#
#   # List all VMs
#   vm_list
#
#   # Show VM details
#   vm_status my-project
#
#   # Stop VM
#   sudo vm_stop my-project
#
#   # Copy VM
#   sudo vm_copy my-project my-project-backup
#
#   # Create snapshot for reuse
#   sudo vm_snapshot my-project my-custom-template
#
#   # Destroy VM
#   sudo vm_destroy my-project
#
