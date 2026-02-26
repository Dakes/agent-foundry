#!/usr/bin/env bash
#
# Agent Foundry - Prepare Firecracker Kernel
#
# Builds a Firecracker-compatible Linux kernel from the official
# microvm config plus an optional local config fragment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/utils.sh"

KERNEL_VERSION="${KERNEL_VERSION:-5.10.84}"
CONFIG_NAME="linux-${KERNEL_VERSION}-microvm.config"
CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/kernel/${CONFIG_NAME}"
KERNEL_SOURCE_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_PROFILE="${KERNEL_PROFILE:-docker-netfilter}"
KERNEL_OUTPUT_NAME="${KERNEL_OUTPUT_NAME:-vmlinux}"
KERNEL_JOBS="${KERNEL_JOBS:-$(nproc)}"

HOST_HOME="$(resolve_host_home)"
INSTALL_DIR="${INSTALL_DIR:-${HOST_HOME}/.local/share/foundry/vms/kernels}"
KERNEL_PATH="${INSTALL_DIR}/${KERNEL_OUTPUT_NAME}"
CONFIG_PATH="${INSTALL_DIR}/${CONFIG_NAME}"
FINAL_CONFIG_PATH="${INSTALL_DIR}/${KERNEL_OUTPUT_NAME}.config"
KERNEL_FRAGMENT_PATH="${REPO_ROOT}/config/kernel/docker-netfilter.fragment"

FORCE=false
BUILD_KERNEL=true

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -f, --force                  Rebuild/re-fetch even if output exists
      --no-build               Only fetch/update config files
      --install-dir <path>     Override kernel install directory
      --output-name <name>     Kernel output filename (default: vmlinux)
      --jobs <n>               Number of parallel build jobs
      --profile <name>         Kernel profile (default: docker-netfilter)
  -h, --help                   Show this help and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE=true
                shift
                ;;
            --no-build)
                BUILD_KERNEL=false
                shift
                ;;
            --install-dir)
                if [[ $# -lt 2 ]]; then
                    log_error "--install-dir requires a value"
                    exit 1
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            --output-name)
                if [[ $# -lt 2 ]]; then
                    log_error "--output-name requires a value"
                    exit 1
                fi
                KERNEL_OUTPUT_NAME="$2"
                shift 2
                ;;
            --jobs)
                if [[ $# -lt 2 ]]; then
                    log_error "--jobs requires a value"
                    exit 1
                fi
                KERNEL_JOBS="$2"
                shift 2
                ;;
            --profile)
                if [[ $# -lt 2 ]]; then
                    log_error "--profile requires a value"
                    exit 1
                fi
                KERNEL_PROFILE="$2"
                shift 2
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

    KERNEL_PATH="${INSTALL_DIR}/${KERNEL_OUTPUT_NAME}"
    FINAL_CONFIG_PATH="${INSTALL_DIR}/${KERNEL_OUTPUT_NAME}.config"

    if [[ "$KERNEL_PROFILE" != "docker-netfilter" ]]; then
        log_error "Unsupported kernel profile: $KERNEL_PROFILE"
        exit 1
    fi
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

require_tools() {
    local missing=0
    local tools=(tar make gcc bc bison flex)
    local tool
    for tool in "${tools[@]}"; do
        if ! check_command "$tool"; then
            log_error "Missing required tool: $tool"
            missing=1
        fi
    done
    if ! check_command curl && ! check_command wget; then
        log_error "Missing required downloader: curl or wget"
        missing=1
    fi
    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

apply_config_fragment() {
    local target_config="$1"
    local fragment="$2"

    [[ -f "$fragment" ]] || {
        log_error "Kernel fragment not found: $fragment"
        exit 1
    }

    local line key
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"
        sed -i "/^${key}=.*/d" "$target_config"
        sed -i "/^# ${key} is not set$/d" "$target_config"
        echo "$line" >> "$target_config"
    done < "$fragment"
}

validate_required_config() {
    local cfg="$1"
    local missing=0
    local required=(
        CONFIG_NETFILTER
        CONFIG_NF_TABLES
        CONFIG_NF_NAT
        CONFIG_IP_NF_NAT
        CONFIG_BRIDGE
        CONFIG_BRIDGE_NETFILTER
        CONFIG_IP_NF_IPTABLES
        CONFIG_IP_NF_TARGET_MASQUERADE
    )

    local key
    for key in "${required[@]}"; do
        if ! grep -Eq "^${key}=y$" "$cfg"; then
            log_error "Kernel config requirement not satisfied: ${key}=y"
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        log_error "Kernel config validation failed for Docker bridge/NAT"
        exit 1
    fi
}

prepare_kernel_config() {
    local workdir="$1"
    local source_dir="$2"
    local build_dir="$3"
    local build_config="${workdir}/kernel.config"

    cp "$CONFIG_PATH" "$build_config"

    if [[ "$KERNEL_PROFILE" == "docker-netfilter" ]]; then
        log_info "Applying kernel profile: ${KERNEL_PROFILE}"
        apply_config_fragment "$build_config" "$KERNEL_FRAGMENT_PATH"
    fi

    cp "$build_config" "$build_dir/.config"
    make -C "$source_dir" O="$build_dir" olddefconfig >/dev/null
    validate_required_config "$build_dir/.config"
}

build_kernel() {
    if [[ -f "$KERNEL_PATH" && "$FORCE" != true ]]; then
        log_info "Kernel already available at $KERNEL_PATH"
        return 0
    fi

    require_tools

    local workdir
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' RETURN

    local tarball="${workdir}/linux-${KERNEL_VERSION}.tar.xz"
    local source_dir="${workdir}/linux-${KERNEL_VERSION}"
    local build_dir="${workdir}/build"
    mkdir -p "$build_dir"

    log_info "Downloading Linux source ${KERNEL_VERSION}"
    download_remote_asset "$KERNEL_SOURCE_URL" "$tarball" "Linux source tarball"

    log_info "Extracting Linux source"
    tar -xf "$tarball" -C "$workdir"

    log_info "Preparing kernel config"
    prepare_kernel_config "$workdir" "$source_dir" "$build_dir"

    log_info "Building kernel (jobs: ${KERNEL_JOBS})"
    make -C "$source_dir" O="$build_dir" -j"$KERNEL_JOBS" vmlinux >/dev/null

    cp "$build_dir/vmlinux" "$KERNEL_PATH"
    cp "$build_dir/.config" "$FINAL_CONFIG_PATH"
    chmod 0644 "$KERNEL_PATH" "$FINAL_CONFIG_PATH"

    log_info "Built kernel saved to $KERNEL_PATH"
    log_info "Final config saved to $FINAL_CONFIG_PATH"

    trap - RETURN
    rm -rf "$workdir"
}

ensure_install_dir() {
    if ! mkdir -p "$INSTALL_DIR"; then
        log_error "Unable to create kernel directory $INSTALL_DIR"
        exit 1
    fi
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
    ensure_config
    if [[ "$BUILD_KERNEL" == true ]]; then
        build_kernel
    fi
    log_info "Kernel preparation complete: $KERNEL_PATH"
    log_info "MicroVM config available at: $CONFIG_PATH"
}

main "$@"
