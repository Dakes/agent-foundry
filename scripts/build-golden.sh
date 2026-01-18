#!/usr/bin/env bash
#
# Agent Foundry - Build Golden Template
#
# Creates the golden template by cloning the base template, mounting it, entering
# the chroot to install AI tooling, copying SSH credentials, and writing the final
# disk image to the templates directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"

usage() {
    cat <<'EOF'
Usage: build-golden.sh [--packages <path>] [--ssh-key <path>]

Options:
  --packages <path>  Override the packages.txt file used during template build.
  --ssh-key <path>   Copy the specified SSH key (file or directory) into the template.
  -h, --help         Show this help message.
EOF
    exit 1
}

HOST_USER() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "${SUDO_USER}"
    elif [[ -n "${USER:-}" ]]; then
        echo "${USER}"
    else
        id -un
    fi
}

HOST_HOME() {
    local user="$1"
    local home=""

    if [[ -n "$user" ]] && check_command getent; then
        home="$(getent passwd "$user" | cut -d: -f6 || true)"
    fi

    if [[ -z "$home" ]]; then
        home="${HOME:-/root}"
    fi

    echo "$home"
}

expand_user_path() {
    local value="$1"
    if [[ "$value" == "~" ]]; then
        echo "${FOUND_HOST_HOME}"
    elif [[ "$value" == "~/"* ]]; then
        echo "${FOUND_HOST_HOME}/${value#~/}"
    else
        echo "$value"
    fi
}

trim() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf '%s' "$val"
}

read_packages_file() {
    local file="$1"
    local -n result="$2"

    if [[ ! -f "$file" ]]; then
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        if [[ "$line" == "AUR:"* ]]; then
            log_warn "Skipping AUR entry (unsupported): $line"
            continue
        fi
        result+=("$line")
    done <"$file"
}

install_packages() {
    local chroot_dir="$1"
    shift
    local packages=("$@")

    if [[ "${#packages[@]}" -eq 0 ]]; then
        return
    fi

    log_info "Installing packages: ${packages[*]}"
    arch-chroot "$chroot_dir" pacman -Sy --noconfirm --needed "${packages[@]}"
}

install_python_cli_pkg() {
    local description="$1"
    local package="$2"

    log_info "Installing ${description}"
    if arch-chroot "$MOUNT_DIR" python -m pip install --upgrade "$package"; then
        log_info "${description} installed"
    else
        log_warn "Failed to install ${description} (package: $package)"
    fi
}

copy_ssh_keys() {
    local target_dir="$1"
    local source_path="$2"
    local copied=false

    rm -rf "${target_dir:?}"
    mkdir -p "$target_dir"

    if [[ -n "$source_path" ]]; then
        if [[ -d "$source_path" ]]; then
            cp -a "${source_path}/." "$target_dir"
            copied=true
        elif [[ -f "$source_path" ]]; then
            cp "$source_path" "$target_dir/"
            if [[ -f "${source_path}.pub" ]]; then
                cp "${source_path}.pub" "$target_dir/"
            fi
            copied=true
        else
            log_warn "SSH key path not found: $source_path"
        fi
    fi

    [[ "$copied" == false ]] && return

    find "$target_dir" -type d -exec chmod 700 {} \; >/dev/null 2>&1 || true
    find "$target_dir" -type f -exec chmod 600 {} \; >/dev/null 2>&1 || true
    chown -R root:root "$target_dir"
}

is_mounted() {
    local target="$1"
    if check_command mountpoint; then
        mountpoint -q "$target" >/dev/null 2>&1
        return $?
    fi
    grep -qs "[[:space:]]${target}[[:space:]]" /proc/mounts
}

teardown_chroot() {
    local targets=(
        "${MOUNT_DIR}/dev/pts"
        "${MOUNT_DIR}/dev"
        "${MOUNT_DIR}/proc"
        "${MOUNT_DIR}/sys"
        "${MOUNT_DIR}/run"
        "${MOUNT_DIR}"
    )

    for target in "${targets[@]}"; do
        if is_mounted "$target"; then
            umount -l "$target" >/dev/null 2>&1 || true
        fi
    done
}

main() {
    local packages_arg=""
    local ssh_key_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --packages)
                packages_arg="${2:-}"
                if [[ -z "$packages_arg" ]]; then
                    log_error "--packages requires a file path"
                    usage
                fi
                shift 2
                ;;
            --ssh-key)
                ssh_key_arg="${2:-}"
                if [[ -z "$ssh_key_arg" ]]; then
                    log_error "--ssh-key requires a path"
                    usage
                fi
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    if ! check_command arch-chroot || ! check_command pacman || ! check_command git || ! check_command mount || ! check_command umount; then
        log_error "Required commands missing (arch-chroot, pacman, git, mount, umount)"
        exit 1
    fi

    if ! config_load >/dev/null; then
        log_error "Failed to load configuration"
        exit 1
    fi

    FOUND_HOST_USER="$(HOST_USER)"
    FOUND_HOST_HOME="$(HOST_HOME "$FOUND_HOST_USER")"

    local template_dir="${TEMPLATE_DIR:-${HOME}/.local/share/foundry/vms/templates}"
    local base_template="${template_dir}/arch-base.ext4"
    local golden_template="${template_dir}/golden.ext4"

    mkdir -p "$template_dir"

    if [[ ! -f "$base_template" ]]; then
        log_error "Base template missing: $base_template"
        log_error "Run scripts/build-arch-base.sh first"
        exit 1
    fi

    local packages_file=""
    if [[ -n "$packages_arg" ]]; then
        packages_file="$(expand_user_path "$packages_arg")"
        if [[ ! -f "$packages_file" ]]; then
            log_error "Packages file not found: $packages_file"
            exit 1
        fi
    else
        local user_packages="${CONFIG_DIR}/packages.txt"
        if [[ -f "$user_packages" ]]; then
            packages_file="$user_packages"
        elif [[ -f "${PROJECT_ROOT}/config/packages.txt" ]]; then
            packages_file="${PROJECT_ROOT}/config/packages.txt"
        fi
    fi

    local custom_packages=()
    if [[ -n "$packages_file" ]]; then
        log_info "Reading package list: $packages_file"
        read_packages_file "$packages_file" custom_packages
    else
        log_info "No packages.txt found; skipping custom package list"
    fi

    local mount_dir
    local work_dir

    work_dir="$(mktemp -d /tmp/foundry-golden-XXXXXX)"
    cleanup_on_exit "rm -rf '$work_dir'"
    local temp_image="${work_dir}/golden.ext4"
    log_info "Copying base template to temporary image"
    cp "$base_template" "$temp_image"

    mount_dir="$(mktemp -d /tmp/foundry-golden-mount-XXXXXX)"
    cleanup_on_exit "rm -rf '$mount_dir'"
    MOUNT_DIR="$mount_dir"
    cleanup_on_exit "teardown_chroot"

    log_info "Mounting temporary image"
    mount -o loop "$temp_image" "$mount_dir"

    for target in dev dev/pts proc sys run; do
        mkdir -p "$mount_dir/$target"
        mount --bind "/$target" "$mount_dir/$target"
    done

    log_info "Copying SSH credentials"
    local ssh_source=""
    if [[ -n "$ssh_key_arg" ]]; then
        ssh_source="$(expand_user_path "$ssh_key_arg")"
    else
        ssh_source="${FOUND_HOST_HOME}/.ssh"
    fi

    copy_ssh_keys "$mount_dir/root/.ssh" "$ssh_source"

    local core_packages=(git nodejs npm python python-pip docker docker-buildx)
    local all_packages=("${core_packages[@]}" "${custom_packages[@]}")
    install_packages "$mount_dir" "${all_packages[@]}"

    log_info "Installing Claude Code CLI"
    arch-chroot "$mount_dir" npm install -g @anthropic-ai/claude-code

    install_python_cli_pkg "Gemini CLI" "gemini-cli"
    install_python_cli_pkg "OpenAI CLI" "openai"

    log_info "Setting up ralph-claude-code"
    arch-chroot "$mount_dir" /bin/bash -c '
set -euo pipefail
install -d /opt
rm -rf /opt/ralph
git clone https://github.com/frankbria/ralph-claude-code.git /opt/ralph
cd /opt/ralph
./install.sh
'

    log_info "Creating /work directory"
    arch-chroot "$mount_dir" mkdir -p /work

    local host_git_config="${FOUND_HOST_HOME}/.gitconfig"
    if [[ -f "$host_git_config" ]]; then
        local git_name git_email
        git_name="$(git config --file "$host_git_config" --get user.name 2>/dev/null || true)"
        git_email="$(git config --file "$host_git_config" --get user.email 2>/dev/null || true)"
        [[ -n "$git_name" ]] && arch-chroot "$mount_dir" git config --global user.name "$git_name"
        [[ -n "$git_email" ]] && arch-chroot "$mount_dir" git config --global user.email "$git_email"
    fi

    log_info "Syncing filesystem"
    sync

    log_info "Cleaning up mounts"
    teardown_chroot

    log_info "Finalizing golden template"
    mv -f "$temp_image" "$golden_template"
    chmod 644 "$golden_template"

    log_info "Golden template ready: $golden_template"
}

main "$@"
