#!/usr/bin/env bash
#
# Agent Foundry - Build Arch Linux Base Template
#
# Creates minimal Arch Linux base template for VMs.
#
# Usage:
#   ./scripts/build-arch-base.sh [--size 20G]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/utils.sh
source "${PROJECT_ROOT}/lib/utils.sh"

COLOR_OUTPUT="${COLOR_OUTPUT:-true}"

DEFAULT_SIZE="10G"
IMAGE_SIZE="$DEFAULT_SIZE"

FOUNDRY_DATA_DIR="${FOUNDRY_DATA_DIR:-${HOME}/.local/share/foundry}"
TEMPLATES_DIR="${FOUNDRY_DATA_DIR}/vms/templates"
OUTPUT_IMAGE="${TEMPLATES_DIR}/arch-base.ext4"

MOUNT_DIR=""
LOOP_DEV=""
SSH_KEY=""
BUILD_SUCCESS="false"
IMAGE_CREATED="false"

usage() {
    cat <<EOF
Agent Foundry - Build Arch Linux Base Template

Usage: $(basename "$0") [OPTIONS]

Options:
  --size <SIZE>   Disk size (default: ${DEFAULT_SIZE}, example: 20G)
  -h, --help      Show this help and exit
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --size)
                shift
                if [[ $# -eq 0 ]]; then
                    log_error "--size requires a value (example: --size 20G)"
                    usage
                    exit 1
                fi
                IMAGE_SIZE="$1"
                shift
                ;;
            --size=*)
                IMAGE_SIZE="${1#*=}"
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

validate_size() {
    if [[ -z "$IMAGE_SIZE" ]]; then
        log_error "Disk size cannot be empty"
        exit 1
    fi
    if [[ ! "$IMAGE_SIZE" =~ ^[0-9]+[KMGTP]?$ ]]; then
        log_error "Invalid size format: $IMAGE_SIZE (example: 10G)"
        exit 1
    fi
}

ensure_dependencies() {
    local missing=false
    local deps=(qemu-img mkfs.ext4 pacstrap losetup mount umount arch-chroot)

    for dep in "${deps[@]}"; do
        if ! check_command "$dep"; then
            log_error "Missing required command: $dep"
            missing=true
        fi
    done

    if [[ "$missing" == "true" ]]; then
        log_error "Install missing dependencies and re-run"
        exit 1
    fi
}

select_ssh_key() {
    local ed25519="${HOME}/.ssh/id_ed25519.pub"
    local rsa="${HOME}/.ssh/id_rsa.pub"

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

cleanup_image() {
    if [[ "$BUILD_SUCCESS" != "true" && "$IMAGE_CREATED" == "true" && -f "$OUTPUT_IMAGE" ]]; then
        log_warn "Removing incomplete image at $OUTPUT_IMAGE"
        rm -f "$OUTPUT_IMAGE"
    fi
}

create_disk_image() {
    if [[ -f "$OUTPUT_IMAGE" ]]; then
        log_error "Template already exists: $OUTPUT_IMAGE"
        exit 1
    fi

    mkdir -p "$TEMPLATES_DIR"

    log_info "Creating disk image (${IMAGE_SIZE}) at $OUTPUT_IMAGE"
    qemu-img create -f raw "$OUTPUT_IMAGE" "$IMAGE_SIZE"
    IMAGE_CREATED="true"

    log_info "Formatting disk image as ext4"
    mkfs.ext4 -F "$OUTPUT_IMAGE"
}

mount_disk_image() {
    MOUNT_DIR="$(mktemp -d -t foundry-arch-base-XXXX)"
    LOOP_DEV="$(losetup --find --show "$OUTPUT_IMAGE")"

    cleanup_on_exit "cleanup_mounts"

    log_info "Mounting $LOOP_DEV at $MOUNT_DIR"
    mount "$LOOP_DEV" "$MOUNT_DIR"
}

install_base_system() {
    log_info "Installing base system packages with pacstrap"
    pacstrap "$MOUNT_DIR" base base-devel openssh sudo systemd-networkd
}

configure_network() {
    log_info "Configuring systemd-networkd for DHCP on eth0"
    mkdir -p "$MOUNT_DIR/etc/systemd/network"
    cat <<EOF > "$MOUNT_DIR/etc/systemd/network/20-wired.network"
[Match]
Name=eth0

[Network]
DHCP=yes
EOF
}

configure_ssh() {
    log_info "Installing SSH authorized_keys from $SSH_KEY"
    install -d -m 0700 "$MOUNT_DIR/root/.ssh"
    install -m 0600 "$SSH_KEY" "$MOUNT_DIR/root/.ssh/authorized_keys"
}

configure_locale() {
    log_info "Configuring locale en_US.UTF-8"
    local locale_gen="$MOUNT_DIR/etc/locale.gen"

    if [[ ! -f "$locale_gen" ]]; then
        touch "$locale_gen"
    fi

    if ! grep -q '^en_US.UTF-8 UTF-8' "$locale_gen"; then
        echo "en_US.UTF-8 UTF-8" >> "$locale_gen"
    fi

    arch-chroot "$MOUNT_DIR" locale-gen
    echo "LANG=en_US.UTF-8" > "$MOUNT_DIR/etc/locale.conf"
}

configure_timezone() {
    log_info "Setting timezone to UTC"
    arch-chroot "$MOUNT_DIR" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
}

enable_services() {
    log_info "Enabling SSH and systemd-networkd services"
    arch-chroot "$MOUNT_DIR" systemctl enable sshd.service systemd-networkd.service
}

disable_root_password() {
    log_info "Disabling root password"
    arch-chroot "$MOUNT_DIR" passwd -d root
}

main() {
    parse_args "$@"
    validate_size
    require_root
    ensure_dependencies
    select_ssh_key
    cleanup_on_exit "cleanup_image"

    log_info "Building Arch Linux base template"
    create_disk_image
    mount_disk_image
    install_base_system
    configure_network
    configure_ssh
    configure_timezone
    configure_locale
    enable_services
    disable_root_password

    BUILD_SUCCESS="true"
    log_info "Base template ready at $OUTPUT_IMAGE"
}

main "$@"
