#!/usr/bin/env bash
#
# Agent Foundry - Agent Session Management
#
# Functions for managing AI agent sessions in VMs including starting,
# stopping, attaching to sessions, and viewing logs.
#
# Supported agent types:
# - ralph: ralph-claude-code autonomous agent (runs in tmux)
# - ralph-orchestrator: ralph-orchestrator autonomous agent (runs in tmux)
# - claude: Claude Code CLI interactive session (runs in screen)
# - gemini: Gemini CLI interactive session (runs in screen)
# - codex: OpenAI Codex CLI interactive session (runs in screen)
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
if [[ -f "${SCRIPT_DIR}/vm.sh" ]]; then
    source "${SCRIPT_DIR}/vm.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default agent type (tracks configured Ralph image variant unless explicitly overridden)
if [[ -z "${FOUNDRY_DEFAULT_AGENT:-}" ]]; then
    case "${RALPH_AGENT_VARIANT:-}" in
        ralph-orchestrator)
            FOUNDRY_DEFAULT_AGENT="ralph-orchestrator"
            ;;
        *)
            FOUNDRY_DEFAULT_AGENT="ralph"
            ;;
    esac
fi

# Session names
AGENT_TMUX_SESSION="foundry-agent"
AGENT_SCREEN_SESSION="foundry-agent"

# Agent paths in VM
RALPH_PATH="/opt/ralph/ralph"
WORKSPACE_BASE="/root"
RALPH_VARIANT_MARKER="/opt/foundry/ralph-agent-type"
RALPH_VARIANT_CLAUDE_CODE="ralph-claude-code"
RALPH_VARIANT_ORCHESTRATOR="ralph-orchestrator"

# SSH settings (inherit from vm.sh)
FOUNDRY_SSH_USER="${FOUNDRY_SSH_USER:-root}"
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o PasswordAuthentication=no}"
AGENT_FOUNDRY_BASE_DIR="${FOUNDRY_BASE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

_validate_agent_type() {
    local agent_type="$1"
    case "$agent_type" in
        ralph|ralph-orchestrator|claude|gemini|codex)
            return 0
            ;;
        *)
            log_error "Invalid agent type: $agent_type (valid: ralph, ralph-orchestrator, claude, gemini, codex)"
            return 1
            ;;
    esac
}

_get_vm_ip() {
    local vm_name="$1"
    registry_get "$vm_name" ".ip"
}

_get_workspace_name() {
    local vm_name="$1"
    # Workspace name is typically same as VM name or stored in registry
    local workspace
    workspace=$(registry_get "$vm_name" ".workspace" 2>/dev/null)
    if [[ -z "$workspace" || "$workspace" == "null" ]]; then
        echo "$vm_name"
    else
        echo "$workspace"
    fi
}

_ssh_cmd() {
    local vm_name="$1"
    shift

    local vm_ip ssh_key
    vm_ip=$(registry_get "$vm_name" ".ip")
    ssh_key=$(registry_get "$vm_name" ".ssh_key")

    # Remove quotes if present (jq output)
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"

    # Run command in login shell to source profile files (ensures PATH is set correctly)
    # Use same quoting as vm_ssh for consistency (shell-escape arguments)
    local quoted_cmd
    printf -v quoted_cmd '%q ' "$@"

    log_debug "_ssh_cmd executing: $*"

    # Use -n flag to prevent SSH from reading stdin (avoids password prompts and I/O deadlocks)
    # BatchMode=yes in FOUNDRY_SSH_OPTS ensures no interactive prompts
    if [[ -z "$ssh_key" || "$ssh_key" == "null" ]]; then
        ssh -n $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
    else
        ssh -n -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
    fi
    local rc=$?

    log_debug "_ssh_cmd exit code: $rc"
    return $rc
}

# SSH command with TTY allocation (for tmux/screen)
_ssh_cmd_tty() {
    local vm_name="$1"
    shift

    local vm_ip ssh_key
    vm_ip=$(registry_get "$vm_name" ".ip")
    ssh_key=$(registry_get "$vm_name" ".ssh_key")

    # Remove quotes if present (jq output)
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"

    # Use same quoting as vm_ssh for consistency
    local quoted_cmd
    printf -v quoted_cmd '%q ' "$@"

    log_debug "_ssh_cmd_tty executing: $*"

    # Use -t to force PTY allocation (needed for tmux/screen)
    # Still use -n to prevent stdin blocking
    if [[ -z "$ssh_key" || "$ssh_key" == "null" ]]; then
        ssh -t -n $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
    else
        ssh -t -n -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
    fi
    local rc=$?

    log_debug "_ssh_cmd_tty exit code: $rc"
    return $rc
}

_get_vm_ssh_key() {
    local vm_name="$1"
    local ssh_key
    ssh_key=$(registry_get "$vm_name" ".ssh_key" 2>/dev/null || true)
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"
    if [[ "$ssh_key" == "null" ]]; then
        ssh_key=""
    fi
    echo "$ssh_key"
}

_check_vm_running() {
    local vm_name="$1"
    local status
    status=$(registry_get "$vm_name" ".status" 2>/dev/null)
    if [[ "$status" != "running" ]]; then
        log_error "VM '$vm_name' is not running (status: ${status:-unknown})"
        return 1
    fi
    return 0
}

_get_installed_ralph_variant() {
    local vm_name="$1"
    local detected

    detected=$(_ssh_cmd "$vm_name" "if [[ -f '$RALPH_VARIANT_MARKER' ]]; then \
            cat '$RALPH_VARIANT_MARKER'; \
        elif [[ -d /opt/ralph ]]; then \
            echo '$RALPH_VARIANT_CLAUDE_CODE'; \
        elif command -v ralph >/dev/null 2>&1; then \
            version=\$(ralph --version 2>/dev/null | head -n 1 || true); \
            if echo \"\$version\" | grep -qi 'orchestrator'; then \
                echo '$RALPH_VARIANT_ORCHESTRATOR'; \
            else \
                echo unknown; \
            fi; \
        fi" 2>/dev/null || true)

    detected=$(echo "$detected" | tr -d '[:space:]')
    if [[ -z "$detected" ]]; then
        detected="unknown"
    fi
    echo "$detected"
}

_validate_requested_ralph_variant() {
    local requested_agent="$1"
    local installed_variant="$2"

    if [[ -z "$installed_variant" ]]; then
        log_error "No Ralph agent detected in VM image"
        log_info "Rebuild the template with RALPH_AGENT_VARIANT=$RALPH_VARIANT_CLAUDE_CODE or $RALPH_VARIANT_ORCHESTRATOR"
        return 1
    fi

    case "$requested_agent" in
        ralph)
            if [[ "$installed_variant" != "$RALPH_VARIANT_CLAUDE_CODE" && "$installed_variant" != "unknown" ]]; then
                log_error "VM image has Ralph variant '$installed_variant', but you requested 'ralph'"
                log_info "Start with: foundry agent start <vm> ralph-orchestrator"
                return 1
            fi
            ;;
        ralph-orchestrator)
            if [[ "$installed_variant" != "$RALPH_VARIANT_ORCHESTRATOR" && "$installed_variant" != "unknown" ]]; then
                log_error "VM image has Ralph variant '$installed_variant', but you requested 'ralph-orchestrator'"
                log_info "Start with: foundry agent start <vm> ralph"
                return 1
            fi
            ;;
    esac

    return 0
}

_require_gh_watcher_supported_variant() {
    local vm_name="$1"
    local installed_variant
    installed_variant=$(_get_installed_ralph_variant "$vm_name")

    case "$installed_variant" in
        "$RALPH_VARIANT_CLAUDE_CODE"|"$RALPH_VARIANT_ORCHESTRATOR"|unknown)
            return 0
            ;;
        *)
            log_error "Unsupported Ralph variant for GitHub watcher: $installed_variant"
            return 1
            ;;
    esac
}

_resolve_gh_watcher_project_config_path() {
    local vm_name="$1"
    local host_home config_root candidate project_dir project_name

    host_home="$(resolve_host_home)"
    config_root="${FOUNDRY_CONFIG_DIR:-${host_home}/.config/foundry}/projects"

    project_dir=$(registry_get "$vm_name" ".project_dir" 2>/dev/null || true)
    project_dir="${project_dir%\"}"
    project_dir="${project_dir#\"}"
    if [[ -n "$project_dir" && "$project_dir" != "null" ]]; then
        candidate="$project_dir/gh-watcher.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    fi

    for project_name in \
        "$(registry_get "$vm_name" ".project_name" 2>/dev/null || true)" \
        "$vm_name"
    do
        project_name="${project_name%\"}"
        project_name="${project_name#\"}"
        [[ -z "$project_name" || "$project_name" == "null" ]] && continue

        candidate="$config_root/$project_name/gh-watcher.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi

        candidate="${AGENT_FOUNDRY_BASE_DIR}/projects/$project_name/gh-watcher.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

_resolve_host_path_from_project_file() {
    local config_file="$1"
    local raw_path="$2"
    local host_home config_dir

    host_home="$(resolve_host_home)"
    config_dir="$(cd "$(dirname "$config_file")" && pwd)"

    case "$raw_path" in
        ~/*)
            echo "${host_home}/${raw_path#~/}"
            ;;
        /*)
            echo "$raw_path"
            ;;
        *)
            echo "${config_dir}/${raw_path}"
            ;;
    esac
}

_load_gh_watcher_config() {
    local config_path="$1"
    local watched_repos_var="$2"
    local github_token_var="$3"
    local poll_interval_var="$4"
    local ralph_timeout_var="$5"
    local post_error_comments_var="$6"
    local watcher_enabled_var="$7"

    if ! jq -e . "$config_path" >/dev/null 2>&1; then
        log_error "Invalid gh-watcher config JSON: $config_path"
        return 1
    fi

    local cfg_watched_repos cfg_github_token cfg_github_token_file cfg_github_token_env
    local cfg_poll_interval cfg_ralph_timeout cfg_post_error_comments cfg_watcher_enabled token_path

    cfg_watched_repos=$(jq -r '
        if (.watched_repos | type) == "array" then
            .watched_repos | join(",")
        elif (.watched_repos | type) == "string" then
            .watched_repos
        else
            empty
        end
    ' "$config_path")
    cfg_github_token=$(jq -r '.github_token // empty' "$config_path")
    cfg_github_token_file=$(jq -r '.github_token_file // empty' "$config_path")
    cfg_github_token_env=$(jq -r '.github_token_env // empty' "$config_path")
    cfg_poll_interval=$(jq -r '.poll_interval // 60' "$config_path")
    cfg_ralph_timeout=$(jq -r '.ralph_timeout // 120' "$config_path")
    cfg_post_error_comments=$(jq -r '.post_error_comments // true' "$config_path")
    cfg_watcher_enabled=$(jq -r '.enabled // true' "$config_path")

    if [[ -n "$cfg_github_token_file" ]]; then
        token_path=$(_resolve_host_path_from_project_file "$config_path" "$cfg_github_token_file")
        if [[ ! -f "$token_path" ]]; then
            log_error "GitHub token file from gh-watcher config not found: $token_path"
            return 1
        fi
        cfg_github_token="$(<"$token_path")"
    elif [[ -n "$cfg_github_token_env" ]]; then
        cfg_github_token="${!cfg_github_token_env:-}"
    fi

    if [[ -z "$cfg_watched_repos" ]]; then
        log_error "gh-watcher config missing watched_repos: $config_path"
        return 1
    fi

    printf -v "$watched_repos_var" '%s' "$cfg_watched_repos"
    printf -v "$github_token_var" '%s' "$cfg_github_token"
    printf -v "$poll_interval_var" '%s' "$cfg_poll_interval"
    printf -v "$ralph_timeout_var" '%s' "$cfg_ralph_timeout"
    printf -v "$post_error_comments_var" '%s' "$cfg_post_error_comments"
    printf -v "$watcher_enabled_var" '%s' "$cfg_watcher_enabled"
}

_write_gh_watcher_vm_files() {
    local vm_name="$1"
    local config_content="$2"
    local github_token="$3"
    local tmp_config tmp_processed tmp_token vm_ip ssh_key

    _ssh_cmd "$vm_name" "mkdir -p /root/.config/gh-watcher /root/.config/gh"
    vm_ip=$(_get_vm_ip "$vm_name")
    ssh_key=$(_get_vm_ssh_key "$vm_name")

    tmp_config=$(mktemp)
    tmp_processed=$(mktemp)
    tmp_token=$(mktemp)

    printf '%s\n' "$config_content" > "$tmp_config"
    cat > "$tmp_processed" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
    printf '%s\n' "$github_token" > "$tmp_token"

    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_config" "/root/.config/gh-watcher/config.conf"
    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_processed" "/root/.config/gh-watcher/processed.json"
    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_token" "/root/.config/gh/token"
    rm -f "$tmp_config" "$tmp_processed" "$tmp_token"

    _ssh_cmd "$vm_name" "chmod 600 /root/.config/gh/token && touch /root/.config/gh-watcher/watcher.log"
}

# ============================================================================
# AGENT START
# ============================================================================

# Start an agent in the VM
# Usage: agent_start <vm_name> [agent_type]
# agent_type: ralph (default), ralph-orchestrator, claude, gemini, codex
agent_start() {
    local vm_name="$1"
    local agent_type="${2:-$FOUNDRY_DEFAULT_AGENT}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _validate_agent_type "$agent_type" || return 1
    _check_vm_running "$vm_name" || return 1

    local vm_ip
    vm_ip=$(_get_vm_ip "$vm_name")

    # Check if agent already running
    local current_status
    current_status=$(registry_get "$vm_name" ".agent.status" 2>/dev/null)
    if [[ "$current_status" == "running" ]]; then
        log_warn "Agent already running in VM '$vm_name'"
        return 0
    fi

    log_info "Starting $agent_type agent in VM '$vm_name'..."

    local workspace_path="${WORKSPACE_BASE}"

    case "$agent_type" in
        ralph|ralph-orchestrator)
            _start_ralph "$vm_name" "$workspace_path" "$agent_type"
            ;;
        claude)
            _start_interactive "$vm_name" "$workspace_path" "claude"
            ;;
        gemini)
            _start_interactive "$vm_name" "$workspace_path" "gemini"
            ;;
        codex)
            _start_interactive "$vm_name" "$workspace_path" "codex"
            ;;
    esac

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        # Update registry
        registry_update "$vm_name" ".agent.type" "\"$agent_type\""
        registry_update "$vm_name" ".agent.status" "\"running\""
        registry_update "$vm_name" ".agent.session" "\"$AGENT_TMUX_SESSION\""

        log_info "Agent started successfully"
        log_info "  Type: $agent_type"
        log_info "  Attach with: foundry agent attach $vm_name"
    fi

    return $rc
}

# Start Ralph autonomous agent in tmux
_start_ralph() {
    local vm_name="$1"
    local workspace_path="$2"
    local agent_type="$3"

    log_debug "Starting Ralph in tmux session..."

    # Test SSH connectivity first
    log_debug "Testing SSH connectivity to VM..."
    local ssh_test_output
    if ! ssh_test_output=$(_ssh_cmd "$vm_name" "echo 'SSH OK'" 2>&1); then
        log_error "Failed to connect to VM via SSH"
        log_error "SSH error: $ssh_test_output"
        log_info "Ensure VM is running: foundry vm start $vm_name"
        return 1
    fi
    log_debug "SSH connectivity confirmed: $ssh_test_output"

    # Check if Ralph is installed (checking for binary in PATH)
    log_debug "Checking for ralph binary in VM..."
    local ralph_check_output ralph_check_rc
    ralph_check_output=$(_ssh_cmd "$vm_name" "command -v ralph")
    ralph_check_rc=$?
    log_debug "Ralph check output: $ralph_check_output (exit code: $ralph_check_rc)"

    if [[ $ralph_check_rc -ne 0 ]]; then
        log_error "Ralph binary not found in VM PATH"
        log_error "Command output: $ralph_check_output"
        log_info "Ensure Ralph is installed in the VM image"
        return 1
    fi
    log_debug "Ralph found at: $ralph_check_output"

    local installed_variant effective_variant
    installed_variant=$(_get_installed_ralph_variant "$vm_name")
    _validate_requested_ralph_variant "$agent_type" "$installed_variant" || return 1

    effective_variant="$installed_variant"
    if [[ "$effective_variant" == "unknown" ]]; then
        # Fallback for older templates that predate variant markers.
        if [[ "$agent_type" == "ralph-orchestrator" ]]; then
            effective_variant="$RALPH_VARIANT_ORCHESTRATOR"
        else
            effective_variant="$RALPH_VARIANT_CLAUDE_CODE"
        fi
        log_warn "Unable to detect Ralph variant from VM metadata; assuming '$effective_variant'"
    fi
    log_info "Using Ralph variant: $effective_variant"

    # Kill existing session if any
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t $AGENT_TMUX_SESSION 2>/dev/null || true"

    # Create logs directory if it doesn't exist
    _ssh_cmd "$vm_name" "mkdir -p $workspace_path/logs"

    # Create a start script to avoid complex quoting issues with multi-layer shell escaping.
    _ssh_cmd "$vm_name" "echo '#!/bin/bash' > /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo 'cd $workspace_path' >> /tmp/start-ralph.sh"

    case "$effective_variant" in
        "$RALPH_VARIANT_CLAUDE_CODE")
            # Check if Ralph workspace is initialized (checking for .ralph directory)
            log_debug "Checking for .ralph directory at: $workspace_path/.ralph"
            if ! _ssh_cmd "$vm_name" "test -d '$workspace_path/.ralph'"; then
                log_error "Ralph configuration directory not found: $workspace_path/.ralph"
                log_info "Initialize workspace first with: foundry workspace init $vm_name"
                return 1
            fi
            log_debug "Ralph workspace directory found"

            _ssh_cmd "$vm_name" "echo '# Reset circuit breaker if it exists (from previous runs)' >> /tmp/start-ralph.sh"
            _ssh_cmd "$vm_name" "echo 'if [[ -f .ralph/.circuit_breaker_state ]]; then' >> /tmp/start-ralph.sh"
            _ssh_cmd "$vm_name" "echo '    ralph --reset-circuit >/dev/null 2>&1 || true' >> /tmp/start-ralph.sh"
            _ssh_cmd "$vm_name" "echo 'fi' >> /tmp/start-ralph.sh"
            _ssh_cmd "$vm_name" "echo 'exec ralph 2>&1 | tee -a logs/ralph.log' >> /tmp/start-ralph.sh"
            ;;
        "$RALPH_VARIANT_ORCHESTRATOR")
            # Ralph Orchestrator expects project-level config.
            if ! _ssh_cmd "$vm_name" "test -f '$workspace_path/ralph.yml'"; then
                log_error "Ralph Orchestrator config not found: $workspace_path/ralph.yml"
                log_info "Add ralph.yml to your project and run: foundry workspace sync $vm_name"
                return 1
            fi
            _ssh_cmd "$vm_name" "echo 'exec ralph run -c ralph.yml --autonomous 2>&1 | tee -a logs/ralph.log' >> /tmp/start-ralph.sh"
            ;;
        *)
            log_error "Unsupported Ralph variant: $effective_variant"
            return 1
            ;;
    esac

    _ssh_cmd "$vm_name" "chmod +x /tmp/start-ralph.sh"

    # Try to start tmux session (use _ssh_cmd_tty for PTY allocation)
    local tmux_output tmux_rc
    tmux_output=$(_ssh_cmd_tty "$vm_name" "tmux new-session -d -s $AGENT_TMUX_SESSION /tmp/start-ralph.sh 2>&1")
    tmux_rc=$?
    if [[ $tmux_rc -ne 0 ]]; then
        log_error "Tmux command failed (exit code: $tmux_rc)"
        log_error "Tmux output: $tmux_output"
    fi

    # Verify session started
    sleep 1
    if _ssh_cmd_tty "$vm_name" "tmux has-session -t $AGENT_TMUX_SESSION 2>/dev/null"; then
        log_debug "Ralph tmux session started"
        return 0
    else
        log_error "Failed to start Ralph tmux session"
        # Try to get error details
        log_debug "Checking for tmux server..."
        _ssh_cmd_tty "$vm_name" "tmux list-sessions 2>&1" || log_debug "No tmux sessions found"
        log_debug "Checking Ralph process..."
        _ssh_cmd "$vm_name" "pgrep -a ralph" || log_debug "No ralph process found"
        return 1
    fi
}

# Start interactive agent in screen session
_start_interactive() {
    local vm_name="$1"
    local workspace_path="$2"
    local cli_name="$3"

    log_debug "Starting $cli_name in screen session..."

    # Check if workspace exists
    if ! _ssh_cmd "$vm_name" "test -d '$workspace_path'"; then
        log_warn "Workspace not found, using home directory"
        workspace_path="/root"
    fi

    # Kill existing session if any
    _ssh_cmd_tty "$vm_name" "screen -S $AGENT_SCREEN_SESSION -X quit 2>/dev/null || true"

    # Start CLI in screen session
    _ssh_cmd_tty "$vm_name" "cd '$workspace_path' && screen -dmS $AGENT_SCREEN_SESSION $cli_name"

    # Verify session started
    sleep 1
    if _ssh_cmd_tty "$vm_name" "screen -list | grep -q $AGENT_SCREEN_SESSION"; then
        log_debug "$cli_name screen session started"
        return 0
    else
        log_error "Failed to start $cli_name screen session"
        return 1
    fi
}

# ============================================================================
# AGENT STOP
# ============================================================================

# Stop the agent in a VM
# Usage: agent_stop <vm_name>
agent_stop() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip agent_type
    vm_ip=$(_get_vm_ip "$vm_name")
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)

    if [[ -z "$agent_type" || "$agent_type" == "null" ]]; then
        log_debug "No agent configured for VM '$vm_name'"
        return 0
    fi

    log_info "Stopping $agent_type agent in VM '$vm_name'..."

    # Kill tmux session (for Ralph)
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t $AGENT_TMUX_SESSION 2>/dev/null || true"

    # Kill screen session (for interactive agents)
    _ssh_cmd_tty "$vm_name" "screen -S $AGENT_SCREEN_SESSION -X quit 2>/dev/null || true"

    # Update registry
    registry_update "$vm_name" ".agent.status" "\"stopped\""
    registry_update "$vm_name" ".agent.session" "null"

    log_info "Agent stopped"
    return 0
}

# ============================================================================
# AGENT RESTART
# ============================================================================

# Restart agent in VM
# Usage: agent_restart <vm_name>
agent_restart() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    local agent_type
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)

    if [[ -z "$agent_type" || "$agent_type" == "null" ]]; then
        log_error "No agent configured for VM '$vm_name'"
        return 1
    fi

    log_info "Restarting $agent_type agent in VM '$vm_name'..."

    agent_stop "$vm_name" || true
    sleep 1
    agent_start "$vm_name" "$agent_type"
}

# ============================================================================
# AGENT ATTACH
# ============================================================================

# Attach to agent session
# Usage: agent_attach <vm_name>
agent_attach() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip agent_type agent_status ssh_key
    vm_ip=$(_get_vm_ip "$vm_name")
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)
    agent_status=$(registry_get "$vm_name" ".agent.status" 2>/dev/null)
    ssh_key=$(registry_get "$vm_name" ".ssh_key" 2>/dev/null)
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"

    if [[ "$agent_status" != "running" ]]; then
        log_error "Agent not running in VM '$vm_name'"
        log_info "Start with: foundry agent start $vm_name"
        return 1
    fi

    local ssh_key_opt=""
    if [[ -n "$ssh_key" && "$ssh_key" != "null" ]]; then
        ssh_key_opt="-i $ssh_key"
    fi

    log_info "Attaching to $agent_type session in VM '$vm_name'..."
    log_info "Detach with: Ctrl+b d (tmux) or Ctrl+a d (screen)"

    case "$agent_type" in
        ralph|ralph-orchestrator)
            # Attach to tmux
            exec ssh -t $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
                "tmux attach-session -t $AGENT_TMUX_SESSION"
            ;;
        claude|gemini|codex)
            # Attach to screen
            exec ssh -t $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
                "screen -r $AGENT_SCREEN_SESSION"
            ;;
        *)
            log_error "Unknown agent type: $agent_type"
            return 1
            ;;
    esac
}

# ============================================================================
# AGENT STATUS
# ============================================================================

# Show agent status
# Usage: agent_status <vm_name>
agent_status() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    local agent_type agent_status session
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)
    agent_status=$(registry_get "$vm_name" ".agent.status" 2>/dev/null)
    session=$(registry_get "$vm_name" ".agent.session" 2>/dev/null)

    echo "Agent Status for VM: $vm_name"
    echo "  Type: ${agent_type:-none}"
    echo "  Status: ${agent_status:-unknown}"
    echo "  Session: ${session:-none}"

    # If VM is running, check actual session status
    local vm_status
    vm_status=$(registry_get "$vm_name" ".status" 2>/dev/null)

    if [[ "$vm_status" == "running" ]]; then
        local vm_ip
        vm_ip=$(_get_vm_ip "$vm_name")

        echo ""
        echo "Session Status (live check):"

        # Check tmux
        if _ssh_cmd_tty "$vm_name" "tmux has-session -t $AGENT_TMUX_SESSION 2>/dev/null"; then
            echo "  tmux ($AGENT_TMUX_SESSION): running"
            _ssh_cmd_tty "$vm_name" "tmux list-windows -t $AGENT_TMUX_SESSION 2>/dev/null" | \
                sed 's/^/    /'
        else
            echo "  tmux ($AGENT_TMUX_SESSION): not running"
        fi

        # Check screen
        if _ssh_cmd_tty "$vm_name" "screen -list | grep -q $AGENT_SCREEN_SESSION 2>/dev/null"; then
            echo "  screen ($AGENT_SCREEN_SESSION): running"
        else
            echo "  screen ($AGENT_SCREEN_SESSION): not running"
        fi
    fi

    return 0
}

# ============================================================================
# AGENT LOGS
# ============================================================================

_resolve_agent_log_path() {
    local vm_name="$1"
    local primary_log="${WORKSPACE_BASE}/logs/ralph.log"
    local watcher_log="${WORKSPACE_BASE}/logs/ralph-watcher.log"

    if _ssh_cmd "$vm_name" "test -f '$primary_log'"; then
        echo "$primary_log"
        return 0
    fi

    if _ssh_cmd "$vm_name" "test -f '$watcher_log'"; then
        echo "$watcher_log"
        return 0
    fi

    echo "$primary_log"
}

# View agent logs
# Usage: agent_logs <vm_name> [--follow|-f]
agent_logs() {
    local vm_name="$1"
    local follow=""

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f)
                follow="-f"
                ;;
            *)
                log_warn "Unknown option: $1"
                ;;
        esac
        shift
    done

    _check_vm_running "$vm_name" || return 1

    local vm_ip
    vm_ip=$(_get_vm_ip "$vm_name")

    local log_path
    log_path=$(_resolve_agent_log_path "$vm_name")

    log_info "Viewing agent logs from $log_path"
    if [[ -n "$follow" ]]; then
        log_info "Following logs... (Ctrl+C to stop)"
    fi

    # Check if log file exists
    if ! _ssh_cmd "$vm_name" "test -f '$log_path'"; then
        log_warn "Log file not found: $log_path"
        log_info "Agent may not have started or no logs generated yet"

        # Try alternative log locations
        echo ""
        echo "Checking alternative log locations..."
        _ssh_cmd "$vm_name" "ls -la ${WORKSPACE_BASE}/logs/ 2>/dev/null || echo 'No logs directory'"
        return 0
    fi

    # View or follow logs
    if [[ -n "$follow" ]]; then
        local ssh_key
        ssh_key=$(registry_get "$vm_name" ".ssh_key" 2>/dev/null)
        ssh_key="${ssh_key%\"}"
        ssh_key="${ssh_key#\"}"
        local ssh_key_opt=""
        if [[ -n "$ssh_key" && "$ssh_key" != "null" ]]; then
            ssh_key_opt="-i $ssh_key"
        fi
        exec ssh $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "tail -f '$log_path'"
    else
        _ssh_cmd "$vm_name" "tail -100 '$log_path'"
    fi
}

# ============================================================================
# AUTOSTART MANAGEMENT
# ============================================================================

# Enable agent autostart on VM boot
# Usage: agent_enable_autostart <vm_name>
agent_enable_autostart() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip agent_type
    vm_ip=$(_get_vm_ip "$vm_name")
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)

    if [[ -z "$agent_type" || "$agent_type" == "null" ]]; then
        log_error "No agent configured. Start an agent first"
        return 1
    fi

    log_info "Enabling autostart for $agent_type in VM '$vm_name'..."

    local workspace_path="${WORKSPACE_BASE}"

    # Create systemd service
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=Agent Foundry - $agent_type Agent
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=$workspace_path
ExecStart=/usr/bin/tmux new-session -d -s $AGENT_TMUX_SESSION /tmp/start-ralph.sh
ExecStop=/usr/bin/tmux kill-session -t $AGENT_TMUX_SESSION
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)

    # Install service
    echo "$service_content" | _ssh_cmd "$vm_name" "cat > /etc/systemd/system/foundry-agent.service"

    # Enable and start
    _ssh_cmd "$vm_name" "systemctl daemon-reload"
    _ssh_cmd "$vm_name" "systemctl enable foundry-agent.service"

    log_info "Autostart enabled. Agent will start on VM boot"
    return 0
}

# Disable agent autostart
# Usage: agent_disable_autostart <vm_name>
agent_disable_autostart() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip
    vm_ip=$(_get_vm_ip "$vm_name")

    log_info "Disabling autostart in VM '$vm_name'..."

    _ssh_cmd "$vm_name" "systemctl disable foundry-agent.service 2>/dev/null || true"
    _ssh_cmd "$vm_name" "rm -f /etc/systemd/system/foundry-agent.service"
    _ssh_cmd "$vm_name" "systemctl daemon-reload"

    log_info "Autostart disabled"
    return 0
}

# ============================================================================
# GITHUB WATCHER MANAGEMENT
# ============================================================================

# Initialize GitHub watcher for a VM
# Usage: agent_gh_watcher_init <vm_name>
agent_gh_watcher_init() {
    local vm_name="$1"
    local watched_repos=""
    local github_token=""
    local poll_interval="60"
    local ralph_timeout="120"
    local post_error_comments="true"
    local watcher_enabled="true"
    local project_config=""

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1
    _require_gh_watcher_supported_variant "$vm_name" || return 1

    log_info "Initializing GitHub watcher for VM '$vm_name'..."
    project_config=$(_resolve_gh_watcher_project_config_path "$vm_name" || true)
    if [[ -n "$project_config" ]]; then
        log_info "Loading watcher config from $project_config"
        _load_gh_watcher_config \
            "$project_config" \
            watched_repos \
            github_token \
            poll_interval \
            ralph_timeout \
            post_error_comments \
            watcher_enabled || return 1
    fi

    if [[ -z "$watched_repos" ]]; then
        echo ""
        echo "GitHub Watcher Configuration"
        echo "============================="
        echo ""

        read -r -p "Enter repositories to watch (comma-separated, e.g., owner/repo1,owner/repo2): " watched_repos
        if [[ -z "$watched_repos" ]]; then
            log_error "No repositories specified"
            return 1
        fi
    fi

    if [[ -z "$github_token" ]]; then
        echo ""
        echo "GitHub Token Setup"
        echo "=================="
        echo "You need a fine-grained Personal Access Token with these permissions:"
        echo "  - Issues: Read and write"
        echo "  - Pull requests: Read and write"
        echo "  - Contents: Read only"
        echo ""
        echo "Create one at: https://github.com/settings/tokens?type=beta"
        echo ""
        read -r -s -p "Enter GitHub token (input hidden): " github_token
        echo ""

        if [[ -z "$github_token" ]]; then
            log_error "No token provided"
            return 1
        fi
    fi

    # Create config file
    local config_content
    config_content=$(cat <<EOF
# GitHub Watcher Configuration

# Enable automatic polling
WATCHER_ENABLED=$watcher_enabled

# Polling interval in seconds
POLL_INTERVAL=$poll_interval

# Repositories to monitor (comma-separated)
WATCHED_REPOS="$watched_repos"

# GitHub token location
GITHUB_TOKEN_FILE="/root/.config/gh/token"

# Ralph execution timeout in minutes (max 120 per Ralph's limit)
RALPH_TIMEOUT=$ralph_timeout

# Post error comments on failure
POST_ERROR_COMMENTS=$post_error_comments
EOF
)

    _write_gh_watcher_vm_files "$vm_name" "$config_content" "$github_token"

    log_info "GitHub watcher initialized successfully"
    log_info "  Watching: $watched_repos"
    log_info "  Ralph workspace: /root"
    if [[ -n "$project_config" ]]; then
        log_info "  Config source: $project_config"
    fi
    log_info ""
    log_info "Start watcher with: foundry agent gh-watcher start $vm_name"

    return 0
}

# Start GitHub watcher daemon
# Usage: agent_gh_watcher_start <vm_name>
agent_gh_watcher_start() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1
    _require_gh_watcher_supported_variant "$vm_name" || return 1

    # Check if config exists
    if ! _ssh_cmd "$vm_name" "test -f /root/.config/gh-watcher/config.conf"; then
        log_error "GitHub watcher not initialized"
        log_info "Run: foundry agent gh-watcher init $vm_name"
        return 1
    fi

    # Check if watcher already running
    if _ssh_cmd_tty "$vm_name" "tmux has-session -t ralph-gh-watcher 2>/dev/null"; then
        log_warn "GitHub watcher already running in VM '$vm_name'"
        return 0
    fi

    log_info "Starting GitHub watcher in VM '$vm_name'..."

    # Start watcher in tmux session
    _ssh_cmd_tty "$vm_name" "tmux new-session -d -s ralph-gh-watcher '/opt/foundry/ralph_gh_watcher.sh start'"

    # Verify session started
    sleep 1
    if _ssh_cmd_tty "$vm_name" "tmux has-session -t ralph-gh-watcher 2>/dev/null"; then
        log_info "GitHub watcher started successfully"
        log_info "  View logs: foundry agent gh-watcher logs $vm_name"
        log_info "  Check status: foundry agent gh-watcher status $vm_name"
        return 0
    else
        log_error "Failed to start GitHub watcher"
        return 1
    fi
}

# Stop GitHub watcher daemon
# Usage: agent_gh_watcher_stop <vm_name>
agent_gh_watcher_stop() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Stopping GitHub watcher in VM '$vm_name'..."

    # Kill tmux session
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t ralph-gh-watcher 2>/dev/null || true"

    log_info "GitHub watcher stopped"
    return 0
}

# Show GitHub watcher status
# Usage: agent_gh_watcher_status <vm_name>
agent_gh_watcher_status() {
    local vm_name="${1:-}"
    local config_text enabled watched_repos poll_interval variant
    local processed_count last_poll current_task

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Fetching GitHub watcher status from VM '$vm_name'..."
    echo ""

    echo "GitHub Watcher Status"
    echo "====================="

    if config_text=$(_ssh_cmd "$vm_name" "cat /root/.config/gh-watcher/config.conf" 2>/dev/null); then
        enabled=$(printf '%s\n' "$config_text" | sed -n 's/^WATCHER_ENABLED=//p' | tail -1 | tr -d '"')
        watched_repos=$(printf '%s\n' "$config_text" | sed -n 's/^WATCHED_REPOS=//p' | tail -1 | sed 's/^"//; s/"$//')
        poll_interval=$(printf '%s\n' "$config_text" | sed -n 's/^POLL_INTERVAL=//p' | tail -1 | tr -d '"')
        echo "Configuration: /root/.config/gh-watcher/config.conf"
        echo "  Enabled: ${enabled:-unknown}"
        echo "  Repos: ${watched_repos:-unknown}"
        echo "  Poll interval: ${poll_interval:-unknown}s"
    else
        echo "Configuration: Not found"
    fi

    variant=$(_get_installed_ralph_variant "$vm_name")
    echo "  Ralph agent variant: $variant"
    echo ""

    if _ssh_cmd "$vm_name" "tmux has-session -t ralph-gh-watcher 2>/dev/null"; then
        echo "Watcher session: RUNNING (tmux: ralph-gh-watcher)"
    else
        echo "Watcher session: NOT RUNNING"
    fi

    if _ssh_cmd "$vm_name" "tmux has-session -t ralph-loop 2>/dev/null"; then
        echo "Ralph status: WORKING"
    else
        echo "Ralph status: IDLE"
    fi

    echo ""

    if _ssh_cmd "$vm_name" "test -f /root/.config/gh-watcher/processed.json"; then
        if processed_count=$(_ssh_cmd "$vm_name" "jq '.processed | length' /root/.config/gh-watcher/processed.json" 2>/dev/null); then
            last_poll=$(_ssh_cmd "$vm_name" "jq -r '.last_poll' /root/.config/gh-watcher/processed.json" 2>/dev/null || true)
            echo "Processed tasks: ${processed_count:-0}"
            echo "Last poll: ${last_poll:-unknown}"
        else
            echo "Processed tasks: unavailable (invalid JSON in /root/.config/gh-watcher/processed.json)"
        fi
    fi

    if _ssh_cmd "$vm_name" "test -f /root/.config/gh-watcher/current_task.json"; then
        echo ""
        if current_task=$(_ssh_cmd "$vm_name" "jq '.' /root/.config/gh-watcher/current_task.json" 2>/dev/null); then
            echo "Current task:"
            printf '%s\n' "$current_task"
        else
            echo "Current task: unavailable (invalid JSON in /root/.config/gh-watcher/current_task.json)"
        fi
    fi
}

# View GitHub watcher logs
# Usage: agent_gh_watcher_logs <vm_name> [--follow|-f]
agent_gh_watcher_logs() {
    local vm_name="$1"
    local follow=""

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f)
                follow="-f"
                ;;
            *)
                log_warn "Unknown option: $1"
                ;;
        esac
        shift
    done

    _check_vm_running "$vm_name" || return 1

    local log_path="/root/.config/gh-watcher/watcher.log"

    log_info "Viewing GitHub watcher logs from $log_path"
    if [[ -n "$follow" ]]; then
        log_info "Following logs... (Ctrl+C to stop)"
    fi
    echo ""

    # Check if log file exists
    if ! _ssh_cmd "$vm_name" "test -f '$log_path'"; then
        log_warn "Log file not found: $log_path"
        log_info "Watcher may not have started yet"
        return 0
    fi

    # View or follow logs
    if [[ -n "$follow" ]]; then
        local ssh_key
        ssh_key=$(registry_get "$vm_name" ".ssh_key" 2>/dev/null)
        ssh_key="${ssh_key%\"}"
        ssh_key="${ssh_key#\"}"
        local ssh_key_opt=""
        if [[ -n "$ssh_key" && "$ssh_key" != "null" ]]; then
            ssh_key_opt="-i $ssh_key"
        fi

        local vm_ip
        vm_ip=$(_get_vm_ip "$vm_name")

        exec ssh $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "tail -f '$log_path'"
    else
        _ssh_cmd "$vm_name" "tail -100 '$log_path'"
    fi
}

# Reset GitHub watcher state (clear processed tasks)
# Usage: agent_gh_watcher_reset <vm_name>
agent_gh_watcher_reset() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_warn "This will clear all processed task history"
    if ! confirm "Are you sure?"; then
        log_info "Cancelled"
        return 0
    fi

    log_info "Resetting GitHub watcher state in VM '$vm_name'..."

    # Reset processed.json
    _ssh_cmd "$vm_name" "cat > /root/.config/gh-watcher/processed.json" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF

    # Remove active state files
    _ssh_cmd "$vm_name" "rm -f /root/.config/gh-watcher/current_task.json /root/.config/gh-watcher/current_context.json /root/.config/gh-watcher/retries.json /root/.config/gh-watcher/run-status.json"

    log_info "GitHub watcher state reset"
    log_info "All previously processed tasks have been cleared"
    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example workflow:
#
#   # Start Ralph autonomous agent
#   agent_start my-project ralph
#   agent_start my-project ralph-orchestrator
#
#   # Start Claude interactive session
#   agent_start my-project claude
#
#   # Check agent status
#   agent_status my-project
#
#   # Attach to agent session
#   agent_attach my-project
#   # Detach: Ctrl+b d (tmux) or Ctrl+a d (screen)
#
#   # View agent logs
#   agent_logs my-project
#   agent_logs my-project --follow
#
#   # Stop agent
#   agent_stop my-project
#
#   # Enable autostart on boot
#   agent_enable_autostart my-project
#
#   # GitHub Watcher
#   foundry agent gh-watcher init my-project
#   foundry agent gh-watcher start my-project
#   foundry agent gh-watcher status my-project
#   foundry agent gh-watcher logs my-project --follow
#   foundry agent gh-watcher stop my-project
#   foundry agent gh-watcher reset my-project
#
