#!/usr/bin/env bash
#
# Agent Foundry - Network Management
#
# Functions for managing VM networking including TAP devices, IP allocation,
# and NAT configuration for the 172.16.0.0/24 network.
#
# Network architecture:
# - Host gateway: 172.16.0.1/24
# - VM IP pool: 172.16.0.10-254 (245 VMs max)
# - TAP device naming: tap-agent-01, tap-agent-02, etc
# - NAT masquerade for internet access
#

set -euo pipefail

# Source utils for logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    # shellcheck source=lib/utils.sh
    source "${SCRIPT_DIR}/utils.sh"
fi

# Source registry for state management
if [[ -f "${SCRIPT_DIR}/registry.sh" ]]; then
    # shellcheck source=lib/registry.sh
    source "${SCRIPT_DIR}/registry.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Network configuration
FOUNDRY_NETWORK="${FOUNDRY_NETWORK:-172.16.0.0/24}"
FOUNDRY_GATEWAY="${FOUNDRY_GATEWAY:-172.16.0.1}"
FOUNDRY_IP_START="${FOUNDRY_IP_START:-10}"
FOUNDRY_IP_END="${FOUNDRY_IP_END:-254}"
FOUNDRY_BRIDGE="${FOUNDRY_BRIDGE:-foundry-br0}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Check if running as root
_require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges"
        return 1
    fi
    return 0
}

# Get next available TAP ID from registry
_get_next_tap_id() {
    registry_lock
    local tap_id
    tap_id=$(jq -r '.network.next_tap_id // 1' "$REGISTRY_FILE" 2>/dev/null || echo "1")
    registry_unlock
    echo "$tap_id"
}

# Increment TAP ID in registry
_increment_tap_id() {
    local current_id="$1"
    local next_id=$((current_id + 1))

    registry_lock
    local tmp_file
    tmp_file=$(mktemp)

    jq ".network.next_tap_id = $next_id" "$REGISTRY_FILE" > "$tmp_file" && \
        mv "$tmp_file" "$REGISTRY_FILE"

    registry_unlock
    log_debug "TAP ID incremented to $next_id"
}

# Format TAP ID to name (e.g., 1 -> tap-agent-01)
_tap_id_to_name() {
    local tap_id="$1"
    printf "tap-agent-%02d" "$tap_id"
}

# Get next available IP from pool
_get_next_ip() {
    registry_lock

    # Read current registry
    local registry_content
    registry_content=$(cat "$REGISTRY_FILE")

    # Get all allocated IPs
    local allocated_ips
    allocated_ips=$(echo "$registry_content" | jq -r '.vms[].ip // empty' 2>/dev/null | sort -t. -k4 -n)

    # Find first available IP in range
    local ip_found=""
    for i in $(seq "$FOUNDRY_IP_START" "$FOUNDRY_IP_END"); do
        local candidate="172.16.0.$i"
        if ! echo "$allocated_ips" | grep -q "^${candidate}$"; then
            ip_found="$candidate"
            break
        fi
    done

    registry_unlock

    if [[ -z "$ip_found" ]]; then
        log_error "No available IPs in pool (172.16.0.$FOUNDRY_IP_START-$FOUNDRY_IP_END)"
        return 1
    fi

    echo "$ip_found"
}

# ============================================================================
# NETWORK INITIALIZATION
# ============================================================================

# Initialize host networking for Firecracker VMs
# Sets up IP forwarding and NAT masquerade
# Usage: network_init
network_init() {
    _require_root || return 1

    log_info "Initializing Agent Foundry network..."

    # Enable IP forwarding
    log_debug "Enabling IP forwarding..."
    if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        log_error "Failed to enable IP forwarding"
        return 1
    fi

    # Make IP forwarding persistent
    if [[ -d /etc/sysctl.d ]]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-foundry.conf
        log_debug "IP forwarding made persistent in /etc/sysctl.d/99-foundry.conf"
    fi

    # Create bridge interface if it doesn't exist
    if ! ip link show "$FOUNDRY_BRIDGE" >/dev/null 2>&1; then
        log_debug "Creating bridge interface: $FOUNDRY_BRIDGE"
        ip link add name "$FOUNDRY_BRIDGE" type bridge || {
            log_error "Failed to create bridge $FOUNDRY_BRIDGE"
            return 1
        }
    fi

    # Configure bridge IP
    if ! ip addr show "$FOUNDRY_BRIDGE" | grep -q "$FOUNDRY_GATEWAY"; then
        log_debug "Assigning IP $FOUNDRY_GATEWAY to bridge"
        ip addr add "${FOUNDRY_GATEWAY}/24" dev "$FOUNDRY_BRIDGE" 2>/dev/null || true
    fi

    # Bring up bridge
    ip link set "$FOUNDRY_BRIDGE" up || {
        log_error "Failed to bring up bridge $FOUNDRY_BRIDGE"
        return 1
    }

    # Set up NAT masquerade
    log_debug "Setting up NAT masquerade for $FOUNDRY_NETWORK..."

    # Check if rule already exists
    if ! iptables -t nat -C POSTROUTING -s "$FOUNDRY_NETWORK" ! -o "$FOUNDRY_BRIDGE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$FOUNDRY_NETWORK" ! -o "$FOUNDRY_BRIDGE" -j MASQUERADE || {
            log_error "Failed to add NAT masquerade rule"
            return 1
        }
        log_debug "NAT masquerade rule added"
    else
        log_debug "NAT masquerade rule already exists"
    fi

    # Allow forwarding to/from bridge
    if ! iptables -C FORWARD -i "$FOUNDRY_BRIDGE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$FOUNDRY_BRIDGE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -o "$FOUNDRY_BRIDGE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -o "$FOUNDRY_BRIDGE" -j ACCEPT
    fi

    log_info "Network initialization complete"
    log_info "  Bridge: $FOUNDRY_BRIDGE"
    log_info "  Gateway: $FOUNDRY_GATEWAY"
    log_info "  Network: $FOUNDRY_NETWORK"

    return 0
}

# ============================================================================
# TAP DEVICE MANAGEMENT
# ============================================================================

# Create a TAP device for a VM
# Usage: network_create_tap <vm_name>
# Returns: TAP device name
network_create_tap() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "network_create_tap: VM name required"
        return 1
    fi

    _require_root || return 1

    # Get next TAP ID
    local tap_id
    tap_id=$(_get_next_tap_id)

    local tap_name
    tap_name=$(_tap_id_to_name "$tap_id")

    log_info "Creating TAP device $tap_name for VM $vm_name..."

    # Check if TAP already exists
    if ip link show "$tap_name" >/dev/null 2>&1; then
        log_warn "TAP device $tap_name already exists, reusing"
    else
        # Create TAP device
        ip tuntap add dev "$tap_name" mode tap || {
            log_error "Failed to create TAP device $tap_name"
            return 1
        }
    fi

    # Bring up TAP device
    ip link set "$tap_name" up || {
        log_error "Failed to bring up TAP device $tap_name"
        return 1
    }

    # Add TAP to bridge
    ip link set "$tap_name" master "$FOUNDRY_BRIDGE" || {
        log_error "Failed to add $tap_name to bridge $FOUNDRY_BRIDGE"
        return 1
    }

    # Increment TAP ID for next VM
    _increment_tap_id "$tap_id"

    log_debug "TAP device $tap_name created and added to bridge"
    echo "$tap_name"
    return 0
}

# Destroy a TAP device
# Usage: network_destroy_tap <vm_name>
network_destroy_tap() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "network_destroy_tap: VM name required"
        return 1
    fi

    _require_root || return 1

    # Get TAP name from registry
    local tap_name
    tap_name=$(registry_get "$vm_name" ".tap" 2>/dev/null)

    if [[ -z "$tap_name" || "$tap_name" == "null" ]]; then
        log_warn "No TAP device found for VM $vm_name"
        return 0
    fi

    log_info "Destroying TAP device $tap_name..."

    # Check if TAP exists
    if ip link show "$tap_name" >/dev/null 2>&1; then
        # Remove from bridge and delete
        ip link set "$tap_name" down 2>/dev/null || true
        ip link delete "$tap_name" 2>/dev/null || {
            log_warn "Failed to delete TAP device $tap_name (may already be removed)"
        }
        log_debug "TAP device $tap_name destroyed"
    else
        log_debug "TAP device $tap_name does not exist"
    fi

    return 0
}

# ============================================================================
# IP ALLOCATION
# ============================================================================

# Allocate IP address for a VM
# Usage: network_allocate_ip <vm_name>
# Returns: Allocated IP address
network_allocate_ip() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "network_allocate_ip: VM name required"
        return 1
    fi

    # Check if VM already has an IP
    local existing_ip
    existing_ip=$(registry_get "$vm_name" ".ip" 2>/dev/null)

    if [[ -n "$existing_ip" && "$existing_ip" != "null" ]]; then
        log_debug "VM $vm_name already has IP $existing_ip"
        echo "$existing_ip"
        return 0
    fi

    # Get next available IP
    local new_ip
    new_ip=$(_get_next_ip) || {
        log_error "Failed to allocate IP for VM $vm_name"
        return 1
    }

    log_info "Allocated IP $new_ip for VM $vm_name"
    echo "$new_ip"
    return 0
}

# Release IP address back to pool
# Usage: network_release_ip <vm_name>
network_release_ip() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "network_release_ip: VM name required"
        return 1
    fi

    # Get current IP from registry
    local current_ip
    current_ip=$(registry_get "$vm_name" ".ip" 2>/dev/null)

    if [[ -z "$current_ip" || "$current_ip" == "null" ]]; then
        log_debug "VM $vm_name has no IP to release"
        return 0
    fi

    log_info "Released IP $current_ip from VM $vm_name"
    # IP is "released" simply by being removed from registry
    # The _get_next_ip function scans for unused IPs

    return 0
}

# ============================================================================
# NETWORK STATUS
# ============================================================================

# Show network status including TAP devices, IPs, and NAT rules
# Usage: network_status
network_status() {
    log_info "Agent Foundry Network Status"
    echo ""

    # Bridge status
    echo "=== Bridge Interface ==="
    if ip link show "$FOUNDRY_BRIDGE" >/dev/null 2>&1; then
        ip addr show "$FOUNDRY_BRIDGE"
    else
        echo "Bridge $FOUNDRY_BRIDGE not found"
    fi
    echo ""

    # TAP devices
    echo "=== TAP Devices ==="
    local tap_count=0
    for tap in $(ip link show 2>/dev/null | grep -o 'tap-agent-[0-9]*' | sort -u); do
        echo "  $tap"
        tap_count=$((tap_count + 1))
    done
    if [[ $tap_count -eq 0 ]]; then
        echo "  No TAP devices found"
    fi
    echo ""

    # Allocated IPs from registry
    echo "=== Allocated IPs ==="
    if [[ -f "$REGISTRY_FILE" ]]; then
        local vms
        vms=$(jq -r '.vms | to_entries[] | "\(.key): \(.value.ip // "none") (\(.value.status // "unknown"))"' "$REGISTRY_FILE" 2>/dev/null)
        if [[ -n "$vms" ]]; then
            echo "$vms" | while read -r line; do
                echo "  $line"
            done
        else
            echo "  No VMs registered"
        fi
    else
        echo "  Registry not initialized"
    fi
    echo ""

    # NAT rules
    echo "=== NAT Rules ==="
    if [[ $EUID -eq 0 ]]; then
        iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "(foundry|172\.16\.0)" || echo "  No Foundry NAT rules"
    else
        echo "  (Run as root to view NAT rules)"
    fi
    echo ""

    # IP forwarding status
    echo "=== IP Forwarding ==="
    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "unknown")
    if [[ "$ip_forward" == "1" ]]; then
        echo "  Enabled"
    else
        echo "  Disabled (ip_forward=$ip_forward)"
    fi

    return 0
}

# ============================================================================
# NETWORK CLEANUP
# ============================================================================

# Clean up all network resources
# WARNING: This removes all Foundry TAP devices and network configuration
# Usage: network_cleanup
network_cleanup() {
    _require_root || return 1

    log_warn "Cleaning up all Foundry network resources..."

    # Remove all TAP devices
    for tap in $(ip link show 2>/dev/null | grep -o 'tap-agent-[0-9]*' | sort -u); do
        log_debug "Removing TAP device: $tap"
        ip link set "$tap" down 2>/dev/null || true
        ip link delete "$tap" 2>/dev/null || true
    done

    # Remove NAT rule
    iptables -t nat -D POSTROUTING -s "$FOUNDRY_NETWORK" ! -o "$FOUNDRY_BRIDGE" -j MASQUERADE 2>/dev/null || true

    # Remove forwarding rules
    iptables -D FORWARD -i "$FOUNDRY_BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$FOUNDRY_BRIDGE" -j ACCEPT 2>/dev/null || true

    # Remove bridge
    if ip link show "$FOUNDRY_BRIDGE" >/dev/null 2>&1; then
        ip link set "$FOUNDRY_BRIDGE" down 2>/dev/null || true
        ip link delete "$FOUNDRY_BRIDGE" 2>/dev/null || true
    fi

    log_info "Network cleanup complete"
    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example usage:
#
#   # Initialize network (requires root)
#   sudo ./network.sh
#   network_init
#
#   # Create TAP device for VM
#   tap_name=$(network_create_tap "my-project")
#
#   # Allocate IP for VM
#   vm_ip=$(network_allocate_ip "my-project")
#
#   # Show network status
#   network_status
#
#   # Cleanup (destroys all Foundry network resources)
#   network_cleanup
#
