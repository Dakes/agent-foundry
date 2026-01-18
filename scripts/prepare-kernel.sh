#!/usr/bin/env bash
#
# Agent Foundry - Prepare Firecracker Kernel
#
# Downloads or extracts a Firecracker-compatible Linux kernel and
# the matching microvm config, then installs them to the foundry
# kernels directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/utils.sh"

KERNEL_VERSION="5.10.84"
FIRECRACKER_RELEASE="v1.3.0"
KERNEL_NAME="vmlinux-${KERNEL_VERSION}-microvm"
CONFIG_NAME="linux-${KERNEL_VERSION}-microvm.config"
KERNEL_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_RELEASE}/${KERNEL_NAME}"
CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/kernel/${CONFIG_NAME}"
INSTALL_DIR="${HOME}/.local/share/foundry/vms/kernels"
KERNEL_PATH="${INSTALL_DIR}/${KERNEL_NAME}"
CONFIG_PATH="${INSTALL_DIR}/${CONFIG_NAME}"

FORCE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -f, --force     Re-fetch kernel and config even if already installed
  -h, --help      Show this help and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE=true
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

download_remote_asset() {
    local url="$1"
    local dest="$2"
    local label="$3"

    mkdir -p "$(dirname "$dest")"
    local tmp
    tmp="$(mktemp)"

    if check_command curl; then
        if ! curl --proto '=https' --fail --show-error --location --retry 3 --output "$tmp" "$url"; then
            log_error "Failed to download $label from $url"
            rm -f "$tmp"
            return 1
        fi
    elif check_command wget; then
        if ! wget --https-only --quiet --output-document="$tmp" "$url"; then
            log_error "Failed to download $label from $url"
            rm -f "$tmp"
            return 1
        fi
    else
        log_error "curl or wget is required to download $label"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    chmod 0644 "$dest"
    log_info "Stored $label in $dest"
}

extract_arch_kernel() {
    if ! check_command pacman; then
        log_debug "pacman not available; skipping Arch extraction"
        return 1
    fi

    local version
    if ! version="$(pacman -Q linux 2>/dev/null | awk '{print $2}')"; then
        log_warn "Unable to query installed linux package version"
        return 1
    fi

    local candidates=(/var/cache/pacman/pkg/linux-"${version}"-*.pkg.tar.*)
    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_warn "No linux package found in pacman cache for version ${version}"
        return 1
    fi

    local pkg="${candidates[0]}"
    log_info "Extracting Firecracker-compatible kernel from ${pkg##*/}"

    if ! check_command zstd; then
        log_warn "zstd is required to unpack ${pkg##*/}"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    if ! tar --use-compress-program="zstd -d" -xf "$pkg" -C "$tmpdir" boot/vmlinux-linux boot/vmlinux-linux-fallback; then
        log_warn "Failed to extract vmlinux binaries from ${pkg##*/}"
        trap - RETURN
        rm -rf "$tmpdir"
        return 1
    fi

    local candidate="$tmpdir/boot/vmlinux-linux"
    if [[ ! -f "$candidate" ]]; then
        candidate="$tmpdir/boot/vmlinux-linux-fallback"
    fi

    if [[ ! -f "$candidate" ]]; then
        log_warn "No vmlinux binary found inside ${pkg##*/}"
        trap - RETURN
        rm -rf "$tmpdir"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp -- "$candidate" "$KERNEL_PATH"
    chmod 0644 "$KERNEL_PATH"
    log_info "Extracted kernel saved to $KERNEL_PATH"

    trap - RETURN
    rm -rf "$tmpdir"
    return 0
}

download_kernel() {
    log_info "Downloading Firecracker kernel ${KERNEL_NAME}"
    download_remote_asset "$KERNEL_URL" "$KERNEL_PATH" "Firecracker kernel"
}

ensure_install_dir() {
    if ! mkdir -p "$INSTALL_DIR"; then
        log_error "Unable to create kernel directory $INSTALL_DIR"
        exit 1
    fi
}

ensure_kernel() {
    if [[ -f "$KERNEL_PATH" && "$FORCE" != true ]]; then
        log_info "Kernel already available at $KERNEL_PATH"
        return 0
    fi

    if [[ -f "$KERNEL_PATH" && "$FORCE" == true ]]; then
        log_info "Refreshing existing kernel at $KERNEL_PATH"
        rm -f "$KERNEL_PATH"
    fi

    if extract_arch_kernel; then
        return 0
    fi

    download_kernel
}

ensure_config() {
    if [[ -f "$CONFIG_PATH" && "$FORCE" != true ]]; then
        log_info "MicroVM kernel config already located at $CONFIG_PATH"
        return 0
    fi

    if [[ -f "$CONFIG_PATH" && "$FORCE" == true ]]; then
        rm -f "$CONFIG_PATH"
    fi

    log_info "Downloading Firecracker microvm kernel config"
    download_remote_asset "$CONFIG_URL" "$CONFIG_PATH" "Firecracker microvm config"
}

main() {
    parse_args "$@"
    log_info "Preparing Firecracker kernel for Agent Foundry"
    ensure_install_dir
    ensure_kernel
    ensure_config
    log_info "Kernel preparation complete: $KERNEL_PATH"
    log_info "MicroVM config available at: $CONFIG_PATH"
}

main "$@"
