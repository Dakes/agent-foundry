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
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o PasswordAuthentication=no}"

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

_generate_vm_ssh_key() {
    local name="$1"

    _validate_vm_name "$name" || return 1

    local ssh_keygen
    ssh_keygen=$(get_command_path "ssh-keygen") || {
        log_error "ssh-keygen not found. Please install OpenSSH client tools."
        return 1
    }

    local ssh_dir private_key public_key
    ssh_dir="${FOUNDRY_VMS_DIR}/${name}/ssh"
    private_key="${ssh_dir}/id_ed25519"
    public_key="${private_key}.pub"

    if [[ -e "$private_key" || -e "$public_key" ]]; then
        log_warn "SSH key already exists for VM '$name' at $ssh_dir; removing stale keys"
        if ! rm -rf "$ssh_dir"; then
            log_error "Failed to remove existing SSH directory: $ssh_dir"
            return 1
        fi
    fi

    if ! mkdir -p "$ssh_dir"; then
        log_error "Failed to create SSH directory: $ssh_dir"
        return 1
    fi

    if ! chmod 700 "$ssh_dir"; then
        log_error "Failed to set permissions on SSH directory: $ssh_dir"
        return 1
    fi

    if ! "$ssh_keygen" -t ed25519 -N "" -f "$private_key" -q; then
        log_error "Failed to generate SSH key for VM '$name'"
        return 1
    fi

    if [[ ! -f "$private_key" || ! -f "$public_key" ]]; then
        log_error "SSH key generation incomplete for VM '$name'"
        return 1
    fi

    if ! chmod 600 "$private_key"; then
        log_error "Failed to set permissions on private key: $private_key"
        return 1
    fi

    if ! chmod 644 "$public_key"; then
        log_error "Failed to set permissions on public key: $public_key"
        return 1
    fi

    # Chown SSH directory to real user if running with sudo/doas
    if [[ -n "${SUDO_USER:-}" ]] || [[ -n "${DOAS_USER:-}" ]]; then
        local real_user
        real_user=$(resolve_host_user)
        log_debug "Changing ownership of SSH directory to user: $real_user"
        if ! chown -R "$real_user:$real_user" "$ssh_dir"; then
            log_warn "Failed to change ownership of SSH directory to $real_user"
        fi
    fi

    echo "$private_key"
    return 0
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
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=${vm_ip}::${FOUNDRY_GATEWAY}:255.255.255.0::eth0:off:1.1.1.1"
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
    local ssh_key_path="$2"
    local timeout="${3:-60}"
    local elapsed=0

    log_debug "Waiting for SSH on $ip (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        if ssh ${ssh_key_path:+-i "$ssh_key_path"} $FOUNDRY_SSH_OPTS -o BatchMode=yes -o ConnectTimeout=2 "${FOUNDRY_SSH_USER}@${ip}" "true" 2>/dev/null; then
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
# Usage: vm_create <name> [-y|--yes] [--ssh-key <path>] [template]
vm_create() {
    local name="$1"
    shift || true

    local ssh_key_arg=""
    local template="$FOUNDRY_DEFAULT_TEMPLATE"
    local auto_yes=false

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            -y|--yes)
                auto_yes=true
                shift
                ;;
            --ssh-key)
                ssh_key_arg="${2:-}"
                if [[ -z "$ssh_key_arg" ]]; then
                    log_error "--ssh-key requires a key path"
                    return 1
                fi
                shift 2
                ;;
            *)
                # First non-flag argument is template
                if [[ -n "${1:-}" ]]; then
                    template="$1"
                    shift
                fi
                break
                ;;
        esac
    done

    if [[ -n "${1:-}" ]]; then
        log_error "Unexpected argument: $1"
        log_error "Usage: vm_create <name> [-y|--yes] [--ssh-key <path>] [template]"
        return 1
    fi

    _validate_vm_name "$name" || return 1
    _require_root || return 1
    _ensure_dirs

    # Check if VM already exists
    if _vm_exists "$name"; then
        if [[ "$auto_yes" == true ]]; then
            log_info "Overwriting existing VM '$name'..."
            vm_destroy "$name" || return 1
        elif confirm "VM already exists. Overwrite?"; then
            vm_destroy "$name" || return 1
        else
            log_error "VM '$name' already exists"
            return 1
        fi
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
    local ssh_key_path=""
    local ssh_public_key=""
    local generated_ssh_key="false"
    local mount_dir=""
    local mount_active="false"
    local tap_name=""
    local vm_ip=""

    _vm_create_cleanup_mount() {
        if [[ "$mount_active" == "true" ]]; then
            umount "$mount_dir" 2>/dev/null || true
            mount_active="false"
        fi
        if [[ -n "$mount_dir" ]]; then
            rmdir "$mount_dir" 2>/dev/null || true
        fi
    }

    _vm_create_cleanup_ssh_key() {
        if [[ "$generated_ssh_key" == "true" && -n "$ssh_key_path" ]]; then
            rm -f "$ssh_key_path" "${ssh_key_path}.pub"
            rmdir "${FOUNDRY_VMS_DIR}/${name}/ssh" 2>/dev/null || true
        fi
    }

    _vm_create_cleanup_tap() {
        if [[ -n "$tap_name" ]]; then
            if ip link show "$tap_name" >/dev/null 2>&1; then
                ip link set "$tap_name" down 2>/dev/null || true
                ip link delete "$tap_name" 2>/dev/null || true
            fi
        fi
    }

    _vm_create_fail() {
        local message="${1:-}"
        if [[ -n "$message" ]]; then
            log_error "$message"
        fi
        _vm_create_cleanup_mount
        _vm_create_cleanup_tap
        _vm_create_cleanup_ssh_key
        if [[ -n "$disk_path" ]]; then
            rm -f "$disk_path"
        fi
        return 1
    }

    disk_path=$(_get_disk_path "$name")
    log_debug "Copying template to $disk_path..."

    if cp --reflink=auto "$template_path" "$disk_path"; then
        log_debug "Disk copied (COW if supported)"
    else
        _vm_create_fail "Failed to copy template disk"
        return 1
    fi

    if [[ -n "$ssh_key_arg" ]]; then
        ssh_key_path="${ssh_key_arg/#\~/$FOUNDRY_HOST_HOME}"
        if [[ ! -f "$ssh_key_path" ]]; then
            _vm_create_fail "SSH key not found: $ssh_key_path"
            return 1
        fi
        if [[ "$ssh_key_path" == *.pub ]]; then
            ssh_public_key="$ssh_key_path"
        else
            ssh_public_key="${ssh_key_path}.pub"
        fi
        if [[ ! -f "$ssh_public_key" ]]; then
            _vm_create_fail "SSH public key not found: $ssh_public_key"
            return 1
        fi
    else
        ssh_key_path=$(_generate_vm_ssh_key "$name") || {
            _vm_create_fail "Failed to generate SSH key"
            return 1
        }
        generated_ssh_key="true"
        ssh_public_key="${ssh_key_path}.pub"
    fi

    log_debug "Injecting SSH key into VM disk..."
    mount_dir=$(mktemp -d -t "foundry-vm-${name}-XXXX") || {
        _vm_create_fail "Failed to create mount directory"
        return 1
    }
    if ! mount -o loop "$disk_path" "$mount_dir"; then
        _vm_create_fail "Failed to mount VM disk"
        return 1
    fi
    mount_active="true"

    if ! mkdir -p "$mount_dir/root/.ssh"; then
        _vm_create_fail "Failed to create /root/.ssh in VM disk"
        return 1
    fi
    if ! chmod 700 "$mount_dir/root/.ssh"; then
        _vm_create_fail "Failed to set permissions on /root/.ssh"
        return 1
    fi
    if ! cat "$ssh_public_key" > "$mount_dir/root/.ssh/authorized_keys"; then
        _vm_create_fail "Failed to write authorized_keys to VM disk"
        return 1
    fi
    if ! chmod 600 "$mount_dir/root/.ssh/authorized_keys"; then
        _vm_create_fail "Failed to set permissions on authorized_keys"
        return 1
    fi

    if ! umount "$mount_dir"; then
        _vm_create_fail "Failed to unmount VM disk"
        return 1
    fi
    mount_active="false"
    rmdir "$mount_dir" 2>/dev/null || true
    mount_dir=""

    # Allocate IP address
    vm_ip=$(network_allocate_ip "$name") || {
        _vm_create_fail "Failed to allocate IP"
        return 1
    }

    # Create TAP device
    tap_name=$(network_create_tap "$name") || {
        _vm_create_fail "Failed to create TAP device"
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
        \"ssh_key\": \"$ssh_key_path\",
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
        _vm_create_fail "Failed to register VM"
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
    local disk_path kernel_path tap_name vm_ip cpus memory_mb ssh_key
    disk_path=$(registry_get "$name" ".disk")
    kernel_path=$(registry_get "$name" ".kernel")
    tap_name=$(registry_get "$name" ".tap")
    vm_ip=$(registry_get "$name" ".ip")
    cpus=$(registry_get "$name" ".cpus")
    memory_mb=$(registry_get "$name" ".memory_mb")
    ssh_key=$(registry_get "$name" ".ssh_key")

    # Verify files exist
    if [[ ! -f "$disk_path" ]]; then
        log_error "Disk not found: $disk_path"
        return 1
    fi
    if [[ ! -f "$kernel_path" ]]; then
        log_error "Kernel not found: $kernel_path"
        return 1
    fi

    # Ensure bridge and gateway IP are present.
    # Bridge can exist without the expected gateway address after host/network resets.
    if ! ip link show "$FOUNDRY_BRIDGE" >/dev/null 2>&1 || \
       ! ip -o -4 addr show dev "$FOUNDRY_BRIDGE" | grep -q "${FOUNDRY_GATEWAY}/"; then
        log_warn "Network bridge state incomplete. Re-initializing network..."
        network_init || return 1
    fi

    # Ensure TAP device exists
    if ! ip link show "$tap_name" >/dev/null 2>&1; then
        log_debug "Recreating TAP device $tap_name..."
        ip tuntap add dev "$tap_name" mode tap || return 1
        ip link set "$tap_name" up || return 1
    fi

    # Always attach TAP to the bridge; this is idempotent and fixes stale/missing master assignment.
    ip link set "$tap_name" master "$FOUNDRY_BRIDGE" || return 1
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
    if _wait_for_ssh "$vm_ip" "$ssh_key" 30; then
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

    local pid vm_ip ssh_key
    pid=$(registry_get "$name" ".pid")
    vm_ip=$(registry_get "$name" ".ip")
    ssh_key=$(registry_get "$name" ".ssh_key")
    if [[ "$ssh_key" == "null" ]]; then
        ssh_key=""
    fi

    # Try graceful shutdown via SSH first
    if [[ -n "$vm_ip" ]]; then
        log_debug "Attempting graceful shutdown..."
        ssh ${ssh_key:+-i "$ssh_key"} $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "poweroff" 2>/dev/null || true
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
    local disk_path tap_name ssh_key_path
    disk_path=$(registry_get "$name" ".disk")
    tap_name=$(registry_get "$name" ".tap")
    ssh_key_path=$(registry_get "$name" ".ssh_key")

    # Destroy TAP device
    network_destroy_tap "$name" || true

    # Release IP (handled by registry removal)
    network_release_ip "$name" || true

    # Delete disk
    if [[ -n "$disk_path" && -f "$disk_path" ]]; then
        log_debug "Removing disk: $disk_path"
        rm -f "$disk_path"
    fi

    if [[ -n "$ssh_key_path" ]]; then
        local ssh_dir
        ssh_dir=$(dirname "$ssh_key_path")
        if [[ -d "$ssh_dir" && "$ssh_dir" == "${FOUNDRY_VMS_DIR}/${name}/ssh"* ]]; then
            log_debug "Removing SSH keys: $ssh_dir"
            rm -rf "$ssh_dir"
        fi
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

    local status vm_ip ssh_key
    status=$(registry_get "$name" ".status")
    vm_ip=$(registry_get "$name" ".ip")
    ssh_key=$(registry_get "$name" ".ssh_key")

    if [[ "$status" != "running" ]]; then
        log_error "VM '$name' is not running"
        return 1
    fi
    if [[ -z "$ssh_key" || "$ssh_key" == "null" ]]; then
        log_error "SSH key not found in registry for VM '$name'"
        return 1
    fi

    if [[ ${#cmd[@]} -eq 0 ]]; then
        # Interactive SSH
        exec ssh -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}"
    else
        # Run command in login shell to source profile files (ensures PATH is set correctly)
        local quoted_cmd
        printf -v quoted_cmd '%q ' "${cmd[@]}"
        ssh -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
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

    local ssh_key_path=""
    local ssh_public_key=""
    local mount_dir=""
    local mount_active="false"

    _vm_copy_cleanup() {
        if [[ "$mount_active" == "true" ]]; then
            umount "$mount_dir" 2>/dev/null || true
            mount_active="false"
        fi
        if [[ -n "$mount_dir" ]]; then
            rmdir "$mount_dir" 2>/dev/null || true
        fi
        if [[ -n "$ssh_key_path" ]]; then
            rm -f "$ssh_key_path" "${ssh_key_path}.pub"
            rmdir "${FOUNDRY_VMS_DIR}/${dest}/ssh" 2>/dev/null || true
            rmdir "${FOUNDRY_VMS_DIR}/${dest}" 2>/dev/null || true
        fi
    }
    _vm_copy_fail() {
        log_error "$1"
        _vm_copy_cleanup
        rm -f "$dest_disk"
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

    # Generate new SSH key pair for the copied VM
    ssh_key_path=$(_generate_vm_ssh_key "$dest") || { _vm_copy_fail "Failed to generate SSH key for VM '$dest'"; return 1; }
    ssh_public_key="${ssh_key_path}.pub"

    # Update authorized_keys on the copied disk to use the new key
    mount_dir=$(mktemp -d -t "foundry-vm-${dest}-XXXX") || { _vm_copy_fail "Failed to create mount directory"; return 1; }
    if ! mount -o loop "$dest_disk" "$mount_dir"; then
        _vm_copy_fail "Failed to mount copied VM disk"
        return 1
    fi
    mount_active="true"
    if ! mkdir -p "$mount_dir/root/.ssh"; then
        _vm_copy_fail "Failed to create /root/.ssh in copied VM disk"
        return 1
    fi
    if ! chmod 700 "$mount_dir/root/.ssh"; then
        _vm_copy_fail "Failed to set permissions on /root/.ssh"
        return 1
    fi
    if ! cat "$ssh_public_key" > "$mount_dir/root/.ssh/authorized_keys"; then
        _vm_copy_fail "Failed to write authorized_keys to copied VM disk"
        return 1
    fi
    if ! chmod 600 "$mount_dir/root/.ssh/authorized_keys"; then
        _vm_copy_fail "Failed to set permissions on authorized_keys"
        return 1
    fi
    if ! umount "$mount_dir"; then
        _vm_copy_fail "Failed to unmount copied VM disk"
        return 1
    fi
    mount_active="false"
    rmdir "$mount_dir" 2>/dev/null || true
    mount_dir=""

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
        \"ssh_key\": \"$ssh_key_path\",
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

    # Update SSH key path if it lives under the VM directory
    local old_ssh_key new_ssh_key old_ssh_dir new_ssh_dir
    old_ssh_key=$(registry_get "$old_name" ".ssh_key")
    if [[ -n "$old_ssh_key" && "$old_ssh_key" != "null" ]]; then
        old_ssh_dir="${FOUNDRY_VMS_DIR}/${old_name}/ssh"
        new_ssh_dir="${FOUNDRY_VMS_DIR}/${new_name}/ssh"
        if [[ "$old_ssh_key" == "$old_ssh_dir/"* ]]; then
            mkdir -p "${FOUNDRY_VMS_DIR}/${new_name}" || {
                log_error "Failed to create VM directory for SSH keys"
                return 1
            }
            if [[ -d "$old_ssh_dir" ]]; then
                mv "$old_ssh_dir" "$new_ssh_dir" || {
                    log_error "Failed to move SSH keys to new VM directory"
                    return 1
                }
            fi
            new_ssh_key="${old_ssh_key/$old_ssh_dir/$new_ssh_dir}"
            rmdir "${FOUNDRY_VMS_DIR}/${old_name}" 2>/dev/null || true
        fi
    fi

    # Get current data and update
    local vm_data
    vm_data=$(registry_get "$old_name" ".")

    # Remove old entry
    registry_remove "$old_name"

    # Add with new name and updated paths
    if [[ -n "$new_ssh_key" ]]; then
        registry_add "$new_name" "$(echo "$vm_data" | jq --arg disk "$new_disk" --arg ssh_key "$new_ssh_key" '.disk = $disk | .ssh_key = $ssh_key')"
    else
        registry_add "$new_name" "$(echo "$vm_data" | jq --arg disk "$new_disk" '.disk = $disk')"
    fi

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

# Update AI dependencies in VM
# Usage: vm_update <name>
vm_update() {
    local name="$1"

    _validate_vm_name "$name" || return 1

    if ! _vm_exists "$name"; then
        log_error "VM '$name' does not exist"
        return 1
    fi

    # Must be running
    local status
    status=$(registry_get "$name" ".status")
    if [[ "$status" != "running" ]]; then
        log_error "VM '$name' is not running (status: $status)"
        log_error "Start the VM first with: foundry vm start $name"
        return 1
    fi

    log_info "Updating AI dependencies in VM '$name'..."

    # Run update script in VM
    local vm_ip ssh_key
    vm_ip=$(registry_get "$name" ".ip")
    ssh_key=$(registry_get "$name" ".ssh_key")

    # Remove quotes if present (jq output)
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"

    if ! ssh ${FOUNDRY_SSH_OPTS} -i "$ssh_key" "${FOUNDRY_SSH_USER}@${vm_ip}" "update-ai-deps"; then
        log_error "Failed to update AI dependencies"
        return 1
    fi

    log_info "AI dependencies updated successfully"
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
