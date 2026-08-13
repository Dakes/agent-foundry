#!/usr/bin/env bash
#
# Agent Foundry - Sandbox Layer
#
# Wraps the Docker Sandboxes CLI (`sbx`). Replaces lib/vm.sh (Firecracker).
#
# Design notes:
#   - A sandbox is named "foundry-<project>" and is 1:1 with a project.
#   - The project's volume root is mounted at its own absolute host path
#     (sbx mounts every workspace at the same path it has on the host), and
#     HOME inside the sandbox is pointed at it. Everything the agent writes
#     to ~ therefore lands on the host filesystem live.
#   - Every function surfaces sbx's own stderr on failure. A command that
#     cannot complete must exit non-zero with the real error (see AGENTS.md).
#
# Requires: sbx, jq
#

# ============================================================================
# CONSTANTS
# ============================================================================

SBX_BIN="${SBX_BIN:-sbx}"

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

# Run an sbx command, capturing stderr so callers can surface it.
# Usage: _sbx <args...>
# Sets: _SBX_STDERR with the captured error output
_sbx() {
    local stderr_file
    stderr_file="$(mktemp)"

    local rc=0
    "$SBX_BIN" "$@" 2>"$stderr_file" || rc=$?

    _SBX_STDERR="$(cat "$stderr_file")"
    rm -f "$stderr_file"

    return "$rc"
}

# Run an sbx command and report its failure with the real sbx error.
# Usage: _sbx_checked "creating sandbox" create shell ...
_sbx_checked() {
    local what="$1"
    shift

    if ! _sbx "$@"; then
        log_error "sbx failed while ${what}"
        if [[ -n "${_SBX_STDERR:-}" ]]; then
            printf '%s\n' "$_SBX_STDERR" >&2
        fi
        return 1
    fi

    return 0
}

# Extract a field from `sbx ls --json` for one sandbox.
# The exact key names in sbx's JSON output are not contractually stable, so
# accept the common spellings rather than hard-failing on a schema change.
# Usage: _sandbox_field <name> <field> [field...]
_sandbox_field() {
    local name="$1"
    shift

    local json
    if ! json="$("$SBX_BIN" ls --json 2>/dev/null)"; then
        return 1
    fi

    # Normalize: sbx may emit an array, or an object with a .sandboxes key.
    local field
    for field in "$@"; do
        local value
        value="$(printf '%s' "$json" | jq -r --arg n "$name" --arg f "$field" '
            (if type == "array" then . else (.sandboxes // .items // []) end)
            | map(select((.name // .Name // "") == $n))
            | first
            | (.[$f] // empty)
        ' 2>/dev/null)"

        if [[ -n "$value" && "$value" != "null" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done

    return 1
}

# ============================================================================
# AVAILABILITY
# ============================================================================

# Verify the sbx CLI is installed and usable.
# Usage: sandbox_require || exit 1
sandbox_require() {
    if ! check_command "$SBX_BIN"; then
        log_error "The 'sbx' CLI is not installed or not in PATH"
        log_error "Install it, then run 'foundry doctor --fix':"
        log_error "  curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh"
        log_error "  sudo apt-get install docker-sbx"
        return 1
    fi

    if ! check_command jq; then
        log_error "jq is required but not installed"
        return 1
    fi

    return 0
}

# Check whether KVM is reachable.
#
# On Linux, sbx runs sandboxes as containers and does not require KVM, so this
# is advisory only and never blocks a command - the authoritative check is
# whether sbx itself works (sandbox_check_login). It stays because a missing
# /dev/kvm is still worth naming when sandbox creation fails on a host where
# Docker is configured to back sandboxes with a VM.
# Usage: sandbox_check_kvm || log_warn "..."
sandbox_check_kvm() {
    if ! check_kvm; then
        log_debug "KVM unavailable or /dev/kvm not accessible"
        log_debug "Only relevant if this host backs sandboxes with a VM."
        return 1
    fi

    return 0
}

# Check the user is signed in to Docker (sbx requires it).
# Usage: sandbox_check_login || return 1
sandbox_check_login() {
    # `sbx ls` is the cheapest command that fails when signed out.
    if ! _sbx ls >/dev/null; then
        log_error "sbx is not usable - are you signed in? Run: sbx login"
        if [[ -n "${_SBX_STDERR:-}" ]]; then
            printf '%s\n' "$_SBX_STDERR" >&2
        fi
        return 1
    fi

    return 0
}

# ============================================================================
# NAMING & STATE
# ============================================================================

# Sandbox name for a project.
# Usage: box="$(sandbox_name_for "pocetude")"
sandbox_name_for() {
    local project="$1"

    if [[ -z "$project" ]]; then
        log_error "sandbox_name_for: project name required"
        return 1
    fi

    printf 'foundry-%s\n' "$project"
}

# Does the sandbox exist (running or stopped)?
# Usage: sandbox_exists "$box" && ...
sandbox_exists() {
    local name="$1"

    local json
    if ! json="$("$SBX_BIN" ls --json 2>/dev/null)"; then
        return 1
    fi

    printf '%s' "$json" | jq -e --arg n "$name" '
        (if type == "array" then . else (.sandboxes // .items // []) end)
        | map(select((.name // .Name // "") == $n))
        | length > 0
    ' >/dev/null 2>&1
}

# Print the sandbox state: running | stopped | absent
# Usage: state="$(sandbox_state "$box")"
sandbox_state() {
    local name="$1"

    if ! sandbox_exists "$name"; then
        echo "absent"
        return 0
    fi

    local raw
    raw="$(_sandbox_field "$name" status state Status State || true)"

    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
        *running*|*up*)
            echo "running"
            ;;
        "")
            # Exists but no readable status field - treat as stopped so callers
            # take the (idempotent) start path rather than assuming it is live.
            echo "stopped"
            ;;
        *)
            echo "stopped"
            ;;
    esac
}

# Is the sandbox running?
# Usage: sandbox_is_running "$box" && ...
sandbox_is_running() {
    [[ "$(sandbox_state "$1")" == "running" ]]
}

# ============================================================================
# LIFECYCLE
# ============================================================================

# Create a sandbox for a project.
#
# Usage: sandbox_create <name> <image> <cpus> <memory> <volume_root> \
#                       [shared_root] [publish_spec...]
#
# The volume root is the primary workspace. The shared root, when given, is
# mounted read-only. Ports passed here are applied at creation; they must be
# re-applied with sandbox_publish after every restart (sbx does not persist
# port mappings across restarts).
sandbox_create() {
    local name="$1"
    local image="$2"
    local cpus="$3"
    local memory="$4"
    local volume_root="$5"
    local shared_root="${6:-}"
    if [[ $# -ge 6 ]]; then
        shift 6
    else
        shift $#
    fi

    if [[ -z "$name" || -z "$volume_root" ]]; then
        log_error "sandbox_create: name and volume root required"
        return 1
    fi

    if [[ ! -d "$volume_root" ]]; then
        log_error "sandbox_create: volume root does not exist: $volume_root"
        return 1
    fi

    if sandbox_exists "$name"; then
        log_debug "Sandbox already exists: $name"
        return 0
    fi

    local -a args=(create shell --name "$name")

    if [[ -n "$image" ]]; then
        args+=(-t "$image")
    fi
    if [[ -n "$cpus" ]]; then
        args+=(--cpus "$cpus")
    fi
    if [[ -n "$memory" ]]; then
        args+=(-m "$memory")
    fi

    local spec
    for spec in "$@"; do
        [[ -n "$spec" ]] && args+=(-p "$spec")
    done

    # Workspaces: primary first, then read-only shared context.
    args+=("$volume_root")
    if [[ -n "$shared_root" && -d "$shared_root" ]]; then
        args+=("${shared_root}:ro")
    fi

    log_info "Creating sandbox: $name"
    log_debug "sbx ${args[*]}"

    _sbx_checked "creating sandbox '$name'" "${args[@]}" || return 1

    return 0
}

# Start (or resume) a sandbox without attaching.
# Usage: sandbox_start <name>
sandbox_start() {
    local name="$1"

    if ! sandbox_exists "$name"; then
        log_error "Sandbox does not exist: $name"
        log_error "Run 'foundry init' first."
        return 1
    fi

    if sandbox_is_running "$name"; then
        log_debug "Sandbox already running: $name"
        return 0
    fi

    log_info "Starting sandbox: $name"
    _sbx_checked "starting sandbox '$name'" run -d --name "$name" || return 1

    return 0
}

# Stop a sandbox, keeping its state.
# Usage: sandbox_stop <name>
sandbox_stop() {
    local name="$1"

    if ! sandbox_exists "$name"; then
        log_debug "Sandbox does not exist, nothing to stop: $name"
        return 0
    fi

    if ! sandbox_is_running "$name"; then
        log_debug "Sandbox already stopped: $name"
        return 0
    fi

    log_info "Stopping sandbox: $name"
    _sbx_checked "stopping sandbox '$name'" stop "$name" || return 1

    return 0
}

# Remove a sandbox and everything inside it. The volume root is untouched.
# Usage: sandbox_rm <name>
sandbox_rm() {
    local name="$1"

    if ! sandbox_exists "$name"; then
        log_debug "Sandbox does not exist, nothing to remove: $name"
        return 0
    fi

    log_info "Removing sandbox: $name"
    # --force: `sbx rm` prompts for confirmation otherwise, which would hang a
    # non-interactive run, and refuses to remove a box that is still in use.
    _sbx_checked "removing sandbox '$name'" rm --force "$name" || return 1

    return 0
}

# Import a locally built docker image into the sandbox runtime's image store.
#
# The two stores are separate: `sbx create -t <tag>` resolves the tag against
# the sandbox runtime and, finding nothing, tries to pull it from a registry -
# which fails with 403 for an image that only exists in the local docker
# daemon. Round-tripping through a tar is the supported bridge
# (`sbx template load`).
#
# Usage: sandbox_load_image <tag>
sandbox_load_image() {
    local tag="$1"

    if [[ -z "$tag" ]]; then
        log_error "sandbox_load_image: image tag required"
        return 1
    fi

    if ! check_command docker; then
        log_error "docker is required to export the image for the sandbox runtime"
        return 1
    fi

    local tar
    tar="$(mktemp -t foundry-image-XXXXXX.tar)" || return 1

    log_info "Loading ${tag} into the sandbox runtime"

    if ! docker save "$tag" -o "$tar"; then
        log_error "Failed to export image: $tag"
        rm -f "$tar"
        return 1
    fi

    if ! _sbx_checked "loading image '$tag' into the sandbox runtime" \
        template load "$tar"; then
        rm -f "$tar"
        return 1
    fi

    rm -f "$tar"
    return 0
}

# ============================================================================
# EXECUTION
# ============================================================================

# The user commands run as inside the sandbox.
#
# This is the host user's numeric UID, not root. Everything the agent writes
# lands in the mounted volume root - a host directory - so running as root
# would leave root-owned files the user cannot edit from the host, breaking the
# "the volume root is your workspace" premise. The agent image creates a
# matching user (see docker/foundry-agent.Dockerfile), so the UID also resolves
# to a real passwd entry, which git and tmux require.
#
# Override with FOUNDRY_SANDBOX_USER when the image uses a different account.
sandbox_user() {
    printf '%s\n' "${FOUNDRY_SANDBOX_USER:-$(resolve_host_uid)}"
}

# Run a command inside a sandbox, with HOME and cwd set to the volume root.
# Usage: sandbox_exec <name> <home> <cmd> [args...]
sandbox_exec() {
    local name="$1"
    local home="$2"
    shift 2

    if [[ $# -eq 0 ]]; then
        log_error "sandbox_exec: command required"
        return 1
    fi

    "$SBX_BIN" exec -u "$(sandbox_user)" -e "HOME=${home}" -w "$home" "$name" "$@"
}

# Same, with a TTY attached (interactive shells, tmux attach).
# Usage: sandbox_exec_tty <name> <home> <cmd> [args...]
sandbox_exec_tty() {
    local name="$1"
    local home="$2"
    shift 2

    "$SBX_BIN" exec -it -u "$(sandbox_user)" -e "HOME=${home}" -w "$home" "$name" "$@"
}

# Run a command detached inside the sandbox.
# Usage: sandbox_exec_detached <name> <home> <cmd> [args...]
sandbox_exec_detached() {
    local name="$1"
    local home="$2"
    shift 2

    "$SBX_BIN" exec -d -u "$(sandbox_user)" -e "HOME=${home}" -w "$home" "$name" "$@"
}

# Run a command as root inside the sandbox (package installs, chown).
# Usage: sandbox_exec_root <name> <home> <cmd> [args...]
sandbox_exec_root() {
    local name="$1"
    local home="$2"
    shift 2

    "$SBX_BIN" exec -u root -e "HOME=${home}" -w "$home" "$name" "$@"
}

# ============================================================================
# PORTS
# ============================================================================

# Publish ports on a running sandbox.
#
# Port mappings do NOT survive a sandbox restart, so this must be called on
# every start. Specs are passed through verbatim:
#   [[HOST_IP:]HOST_PORT:]SANDBOX_PORT[/PROTOCOL]
#
# Omitting HOST_IP binds loopback only - callers that need the port reachable
# from outside the host (webhook receivers) must pass 0.0.0.0 explicitly.
#
# Usage: sandbox_publish <name> <spec> [spec...]
sandbox_publish() {
    local name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local -a args=(ports "$name")
    local spec
    for spec in "$@"; do
        [[ -n "$spec" ]] && args+=(--publish "$spec")
    done

    log_debug "Publishing ports on $name: $*"
    _sbx_checked "publishing ports on '$name'" "${args[@]}" || return 1

    return 0
}

# List published ports for a sandbox (raw sbx output).
# Usage: sandbox_ports <name>
sandbox_ports() {
    local name="$1"

    "$SBX_BIN" ports "$name" 2>/dev/null || true
}

# Is a given sandbox port currently published?
# Usage: sandbox_port_published <name> <sandbox_port> && ...
sandbox_port_published() {
    local name="$1"
    local port="$2"

    local json
    if json="$("$SBX_BIN" ports "$name" --json 2>/dev/null)"; then
        printf '%s' "$json" | jq -e --arg p "$port" '
            (if type == "array" then . else (.ports // []) end)
            | map(select(((.sandbox_port // .SandboxPort // .target // "") | tostring) == $p))
            | length > 0
        ' >/dev/null 2>&1 && return 0
        return 1
    fi

    # Fall back to text output if --json is unavailable in this sbx version.
    sandbox_ports "$name" | grep -qE "(^|[^0-9])${port}([^0-9]|$)"
}

# ============================================================================
# TEMPLATES (snapshots)
# ============================================================================

# Save a running sandbox as a reusable template image.
# Usage: sandbox_snapshot <name> <tag>
sandbox_snapshot() {
    local name="$1"
    local tag="$2"

    if [[ -z "$tag" ]]; then
        log_error "sandbox_snapshot: tag required"
        return 1
    fi

    log_info "Saving sandbox '$name' as template '$tag'"
    _sbx_checked "saving template '$tag'" template save "$name" "$tag" || return 1

    return 0
}

# ============================================================================
# LISTING
# ============================================================================

# Print all sandboxes as raw JSON (array).
# Usage: sandbox_list_json
sandbox_list_json() {
    local json
    if ! json="$("$SBX_BIN" ls --json 2>/dev/null)"; then
        echo "[]"
        return 1
    fi

    printf '%s' "$json" | jq '
        if type == "array" then . else (.sandboxes // .items // []) end
    ' 2>/dev/null || echo "[]"
}
