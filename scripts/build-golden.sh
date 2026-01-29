#!/usr/bin/env bash
#
# Agent Foundry - Build Golden Template
#
# Creates the golden template by cloning the base template, mounting it, entering
# the chroot to install AI tooling and writing the final
# disk image to the templates directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"

usage() {
    cat <<'EOF'
Usage: build-golden.sh [--packages <path>]

Options:
  --packages <path>  Override the packages.txt file used during template build.
  -h, --help         Show this help message.
EOF
    exit 1
}

HOST_USER() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "${SUDO_USER}"
    elif [[ -n "${DOAS_USER:-}" ]]; then
        echo "${DOAS_USER}"
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

    # Initialize dpkg and apt if needed
    if [[ ! -f "$chroot_dir/var/lib/dpkg/status" ]]; then
        log_info "Initializing dpkg and apt directories"
        mkdir -p "$chroot_dir/var/lib/dpkg"
        touch "$chroot_dir/var/lib/dpkg/status"
        mkdir -p "$chroot_dir/var/lib/dpkg/updates"
        mkdir -p "$chroot_dir/var/lib/dpkg/info"
        mkdir -p "$chroot_dir/var/cache/apt/archives/partial"
        mkdir -p "$chroot_dir/var/lib/apt/lists/partial"
        mkdir -p "$chroot_dir/var/log/apt"
    fi

    # Ensure machine-id exists for dbus
    if [[ ! -f "$chroot_dir/etc/machine-id" ]]; then
        log_info "Generating machine-id"
        if [[ -f /etc/machine-id ]]; then
             cat /etc/machine-id > "$chroot_dir/etc/machine-id"
        else
             echo "b08dfa6083e7567a1921a715000001fb" > "$chroot_dir/etc/machine-id"
        fi
    fi
    mkdir -p "$chroot_dir/var/lib/dbus"
    if [[ ! -f "$chroot_dir/var/lib/dbus/machine-id" ]]; then
         ln -sf /etc/machine-id "$chroot_dir/var/lib/dbus/machine-id"
    fi

    # Prevent services from starting in chroot
    cat > "$chroot_dir/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x "$chroot_dir/usr/sbin/policy-rc.d"

    chroot "$chroot_dir" apt-get update
    
    # Attempt install
    if ! DEBIAN_FRONTEND=noninteractive chroot "$chroot_dir" apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${packages[@]}"; then
        
        log_warn "Initial install failed. Attempting to fix broken dependencies..."
        DEBIAN_FRONTEND=noninteractive chroot "$chroot_dir" apt-get install --fix-broken -y
        
        # Retry install
        DEBIAN_FRONTEND=noninteractive chroot "$chroot_dir" apt-get install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${packages[@]}"
    fi

    # Remove policy-rc.d so services can start normally when VM boots
    rm -f "$chroot_dir/usr/sbin/policy-rc.d"
}

install_python_cli_pkg() {
    local description="$1"
    local package="$2"

    log_info "Installing ${description}"
    if chroot "$MOUNT_DIR" python3 -m pip install --upgrade "$package"; then
        log_info "${description} installed"
    else
        log_warn "Failed to install ${description} (package: $package)"
    fi
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
        "${MOUNT_DIR}/tmp"
        "${MOUNT_DIR}"
    )

    for target in "${targets[@]}"; do
        if is_mounted "$target"; then
            umount -l "$target" >/dev/null 2>&1 || true
        fi
    done
}

main() {
    log_info "=== BUILD-GOLDEN.SH STARTING (with resolve_host_home fix) ==="
    local packages_arg=""

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

    if ! check_command chroot || ! check_command git || ! check_command mount || ! check_command umount; then
        log_error "Required commands missing (chroot, git, mount, umount)"
        exit 1
    fi

    if ! config_load >/dev/null; then
        log_error "Failed to load configuration"
        exit 1
    fi

    log_debug "Environment check: SUDO_USER='${SUDO_USER:-}' DOAS_USER='${DOAS_USER:-}' USER='${USER:-}'"

    FOUND_HOST_USER="$(HOST_USER)"
    FOUND_HOST_HOME="$(HOST_HOME "$FOUND_HOST_USER")"

    local host_home
    host_home="$(resolve_host_home)"
    log_debug "Resolved host home: $host_home"
    log_debug "SUDO_USER=${SUDO_USER:-not set}, DOAS_USER=${DOAS_USER:-not set}, USER=${USER:-not set}"
    local template_dir="${TEMPLATE_DIR:-${host_home}/.local/share/foundry/vms/templates}"
    local base_template="${template_dir}/ubuntu-base.ext4"
    local golden_template="${template_dir}/golden.ext4"

    mkdir -p "$template_dir"

    if [[ ! -f "$base_template" ]]; then
        log_error "Base template missing: $base_template"
        log_error "Run 'foundry template build base' first"
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

    for target in dev dev/pts proc sys; do
        mkdir -p "$mount_dir/$target"
        mount --bind "/$target" "$mount_dir/$target"
    done
    
    # Use tmpfs for /run and /tmp within chroot to avoid contaminating host or vice-versa
    mkdir -p "$mount_dir/run" "$mount_dir/tmp"
    mount -t tmpfs tmpfs "$mount_dir/run"
    mount -t tmpfs tmpfs "$mount_dir/tmp"

    log_info "Configuring DNS in chroot"
    # STAGE 1: Static DNS for build process (chroot doesn't run systemd-resolved)
    rm -f "$mount_dir/etc/resolv.conf"
    cat > "$mount_dir/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # STAGE 2: Configure systemd-resolved for the final VM
    mkdir -p "$mount_dir/etc/systemd/resolved.conf.d"
    cat > "$mount_dir/etc/systemd/resolved.conf.d/10-static-dns.conf" <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
EOF

    # Enable systemd-resolved to start on boot
    log_info "Enabling systemd-resolved for boot"
    chroot "$mount_dir" systemctl enable systemd-resolved 2>/dev/null || true


    local core_packages=(
        # Base
        git python3 python3-pip docker.io jq

        # System Monitoring
        htop btop ncdu lsof

        # Modern Search & Navigation
        ripgrep fd-find fzf

        # File Utilities
        bat tree vim neovim nano tmux screen

        # Networking
        httpie curl wget iputils-ping net-tools

        # Build & Dev Tools
        build-essential shellcheck
    )
    local all_packages=("${core_packages[@]}" "${custom_packages[@]}")
    install_packages "$mount_dir" "${all_packages[@]}"

    log_info "Installing nvm and Node.js 24"
    # Install nvm
    # shellcheck disable=SC2016  # Variables should expand in chroot, not host
    chroot "$mount_dir" /bin/bash -c '
set -euo pipefail
export HOME=/root
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 24
nvm alias default 24
nvm use default
'

    # Add nvm to shell profiles for automatic loading
    log_info "Configuring nvm in shell profiles"
    cat >> "$mount_dir/root/.bashrc" <<'EOF'

# Add ~/.local/bin to PATH for user-installed binaries (ralph, etc.)
export PATH="$HOME/.local/bin:$PATH"

# NVM configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF

    cat >> "$mount_dir/root/.profile" <<'EOF'

# Add ~/.local/bin to PATH for user-installed binaries (ralph, etc.)
export PATH="$HOME/.local/bin:$PATH"

# NVM configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
EOF

    log_info "Configuring system-wide PATH for user binaries"
    mkdir -p "$mount_dir/etc/profile.d"
    cat > "$mount_dir/etc/profile.d/local-bin-path.sh" <<'EOF'
# Add ~/.local/bin to PATH for all sessions (interactive and non-interactive)
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
EOF
    chmod 644 "$mount_dir/etc/profile.d/local-bin-path.sh"

    log_info "Installing Claude Code CLI"
    # shellcheck disable=SC2016  # Variables should expand in chroot, not host
    chroot "$mount_dir" /bin/bash -c '
set -euo pipefail
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
npm install -g @anthropic-ai/claude-code
'

    install_python_cli_pkg "Gemini CLI" "gemini-cli"
    install_python_cli_pkg "OpenAI CLI" "openai"

    log_info "Setting up ralph-claude-code"
    # shellcheck disable=SC2016  # Variables should expand in chroot, not host
    chroot "$mount_dir" /bin/bash -c '
set -euo pipefail
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
install -d /opt
rm -rf /opt/ralph
git clone https://github.com/frankbria/ralph-claude-code.git /opt/ralph
cd /opt/ralph
./install.sh
'

    log_info "Creating /work directory"
    chroot "$mount_dir" mkdir -p /work

    local host_git_config="${FOUND_HOST_HOME}/.gitconfig"
    if [[ -f "$host_git_config" ]]; then
        local git_name git_email
        git_name="$(git config --file "$host_git_config" --get user.name 2>/dev/null || true)"
        git_email="$(git config --file "$host_git_config" --get user.email 2>/dev/null || true)"
        [[ -n "$git_name" ]] && chroot "$mount_dir" git config --global user.name "$git_name"
        [[ -n "$git_email" ]] && chroot "$mount_dir" git config --global user.email "$git_email"
    fi

    log_info "Finalizing DNS configuration for VM runtime"
    # Replace static resolv.conf with systemd-resolved symlink
    # The resolved.conf.d config will be used when systemd-resolved starts in the VM
    rm -f "$mount_dir/etc/resolv.conf"
    ln -sf /run/systemd/resolve/stub-resolv.conf "$mount_dir/etc/resolv.conf"

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
