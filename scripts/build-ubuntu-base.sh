#!/usr/bin/env bash
#
# Agent Foundry - Build Ubuntu Base Template
#
# Downloads official Firecracker Ubuntu images and prepares them for use.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/utils.sh
source "${PROJECT_ROOT}/lib/utils.sh"

COLOR_OUTPUT="${COLOR_OUTPUT:-true}"

# Configurable sizes
DEFAULT_SIZE="10G"
IMAGE_SIZE="$DEFAULT_SIZE"

# Paths
FOUNDRY_DATA_DIR=""
TEMPLATES_DIR=""
KERNELS_DIR=""
OUTPUT_IMAGE=""
OUTPUT_KERNEL=""

MOUNT_DIR=""
LOOP_DEV=""
SSH_KEY=""
BUILD_SUCCESS="false"

# Global variable for discovered URL
DISCOVERED_ROOTFS_URL=""

usage() {
    cat <<EOF
Agent Foundry - Build Ubuntu Base Template

Usage: $(basename "$0") [OPTIONS]

Options:
  --size <SIZE>   Disk size (default: ${DEFAULT_SIZE}, example: 20G)
  -h, --help      Show this help and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --size)
                shift
                IMAGE_SIZE="$1"
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

ensure_dependencies() {
    local deps=(curl qemu-img mkfs.ext4 losetup mount umount e2fsck resize2fs unsquashfs)
    for dep in "${deps[@]}"; do
        if ! check_command "$dep"; then
            log_error "Missing required command: $dep (install squashfs-tools)"
            exit 1
        fi
    done
}

discover_resources() {
    log_info "Discovering latest Firecracker Ubuntu rootfs..."
    local arch
    arch=$(uname -m)
    
    local release_url="https://github.com/firecracker-microvm/firecracker/releases"
    local latest_version
    latest_version=$(curl -fsSLI -o /dev/null -w "%{url_effective}" "${release_url}/latest" | xargs basename)
    
    # CI_VERSION is typically MAJOR.MINOR (e.g., 1.14 from v1.14.0)
    local ci_version="${latest_version#v}"
    ci_version="${ci_version%.*}"
    
    log_debug "Detected Latest Version: $latest_version, CI_VERSION: $ci_version"

    local bucket_url="http://spec.ccfc.min.s3.amazonaws.com"
    
    # Find latest ubuntu squashfs key (Firecracker CI uses squashfs for distribution)
    log_debug "Finding latest Ubuntu rootfs for $arch..."
    local ubuntu_prefix="firecracker-ci/$ci_version/$arch/ubuntu-"
    local latest_ubuntu_key
    latest_ubuntu_key=$(curl -s "$bucket_url/?prefix=$ubuntu_prefix&list-type=2" \
        | grep -oP "(?<=<Key>)(${ubuntu_prefix}[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
        | sort -V | tail -1 || true)

    if [[ -z "$latest_ubuntu_key" ]]; then
        log_warn "Could not find Ubuntu rootfs with prefix $ubuntu_prefix. Falling back to stable v1.10 ext4."
        DISCOVERED_ROOTFS_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/$arch/ubuntu-22.04.ext4"
    else
        DISCOVERED_ROOTFS_URL="https://s3.amazonaws.com/spec.ccfc.min/$latest_ubuntu_key"
    fi

    log_info "Discovered Rootfs: $(basename "$DISCOVERED_ROOTFS_URL")"
}

download_rootfs() {
    mkdir -p "$TEMPLATES_DIR"

    if [[ ! -f "$OUTPUT_IMAGE" ]]; then
        log_info "Downloading Ubuntu rootfs from $DISCOVERED_ROOTFS_URL"
        
        # If it's a squashfs, we need to convert it (per official guide)
        if [[ "$DISCOVERED_ROOTFS_URL" == *.squashfs ]]; then
            local temp_squash
            temp_squash=$(mktemp)
            curl -fsSL -o "$temp_squash" "$DISCOVERED_ROOTFS_URL"
            
            log_info "Converting squashfs to ext4 image..."
            local extract_dir
            extract_dir=$(mktemp -d)
            unsquashfs -d "$extract_dir" "$temp_squash"
            
            # Create ext4 image from extracted contents
            truncate -s "$IMAGE_SIZE" "$OUTPUT_IMAGE"
            mkfs.ext4 -d "$extract_dir" -F "$OUTPUT_IMAGE"
            
            rm -rf "$extract_dir" "$temp_squash"
        else
            # Already ext4
            curl -fsSL -o "$OUTPUT_IMAGE" "$DISCOVERED_ROOTFS_URL"
        fi
    else
        log_info "Base image already exists at $OUTPUT_IMAGE. Re-using."
    fi
}

prepare_kernel() {
    mkdir -p "$KERNELS_DIR"

    log_info "Building Docker-capable Firecracker kernel"
    "${PROJECT_ROOT}/scripts/prepare-kernel.sh" \
        --force \
        --profile docker-netfilter \
        --install-dir "$KERNELS_DIR" \
        --output-name "$(basename "$OUTPUT_KERNEL")"
}

resize_image() {
    log_info "Resizing image to $IMAGE_SIZE"
    qemu-img resize -f raw "$OUTPUT_IMAGE" "$IMAGE_SIZE"
    e2fsck -f "$OUTPUT_IMAGE" >/dev/null 2>&1 || true
    resize2fs "$OUTPUT_IMAGE" >/dev/null 2>&1
}

select_ssh_key() {
    local host_home
    host_home="$(resolve_host_home)"
    local ed25519="${host_home}/.ssh/id_ed25519.pub"
    local rsa="${host_home}/.ssh/id_rsa.pub"

    if [[ -f "$ed25519" ]]; then
        SSH_KEY="$ed25519"
    elif [[ -f "$rsa" ]]; then
        SSH_KEY="$rsa"
    else
        log_error "No SSH public key found at ${ed25519} or ${rsa}"
        exit 1
    fi
}

cleanup_mounts() {
    if [[ -n "$MOUNT_DIR" ]]; then
        umount "$MOUNT_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}

inject_ssh_key() {
    log_info "Injecting SSH public key from $SSH_KEY"
    MOUNT_DIR="$(mktemp -d -t foundry-ubuntu-base-XXXX)"
    cleanup_on_exit "cleanup_mounts"

    mount -o loop "$OUTPUT_IMAGE" "$MOUNT_DIR"

    # Ensure .ssh exists in guest root
    mkdir -p "$MOUNT_DIR/root/.ssh"
    chmod 700 "$MOUNT_DIR/root/.ssh"
    
    # Copy key
    cat "$SSH_KEY" > "$MOUNT_DIR/root/.ssh/authorized_keys"
    chmod 600 "$MOUNT_DIR/root/.ssh/authorized_keys"
    
    # Disable password login for root for security
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' "$MOUNT_DIR/etc/ssh/sshd_config" 2>/dev/null || true

    # Disable fcnet.service which overrides our kernel IP config
    if [[ -f "$MOUNT_DIR/etc/systemd/system/fcnet.service" ]]; then
        log_info "Disabling conflicting fcnet.service..."
        rm -f "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/fcnet.service"
        # Mask it to be sure
        ln -sf /dev/null "$MOUNT_DIR/etc/systemd/system/fcnet.service"
    fi

    log_info "SSH key injected successfully"
}

inject_dns_config() {
    log_info "Configuring DNS in guest..."
    # Ensure /etc/resolv.conf has a nameserver
    # We use 1.1.1.1 as primary and 8.8.8.8 as secondary
    cat > "$MOUNT_DIR/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    log_info "DNS configuration injected"
}

main() {
    parse_args "$@"
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    ensure_dependencies
    
    local host_home
    host_home="$(resolve_host_home)"
    FOUNDRY_DATA_DIR="${FOUNDRY_DATA_DIR:-${host_home}/.local/share/foundry}"
    TEMPLATES_DIR="${FOUNDRY_DATA_DIR}/vms/templates"
    KERNELS_DIR="${FOUNDRY_DATA_DIR}/vms/kernels"
    OUTPUT_IMAGE="${TEMPLATES_DIR}/ubuntu-base.ext4"
    OUTPUT_KERNEL="${KERNELS_DIR}/vmlinux"

    select_ssh_key
    discover_resources
    download_rootfs
    prepare_kernel
    resize_image
    inject_ssh_key
    inject_dns_config

    BUILD_SUCCESS="true"
    log_info "Ubuntu base template ready at $OUTPUT_IMAGE"
    log_info "Kernel ready at $OUTPUT_KERNEL"
}

main "$@"
