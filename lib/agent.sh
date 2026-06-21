#!/usr/bin/env bash
#
# Agent Foundry - Agent Session Management
#
# Functions for managing AI agent sessions in VMs including starting,
# stopping, attaching to sessions, and viewing logs.
#
# Supported agent types (see lib/agent-registry.sh for the source of truth):
# - ralph: ralph-claude-code autonomous agent (runs in tmux)
# - ralph-orchestrator: ralph-orchestrator autonomous agent (runs in tmux)
# - kimi-ralph: Kimi Code CLI autonomous agent in Ralph mode (runs in tmux)
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
if [[ -f "${SCRIPT_DIR}/agent-registry.sh" ]]; then
    source "${SCRIPT_DIR}/agent-registry.sh"
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
    if agent_is_valid "$agent_type"; then
        return 0
    fi
    log_error "Invalid agent type: $agent_type (valid: $(agent_valid_list))"
    return 1
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

_scp_to_vm_path() {
    local vm_name="$1"
    local source="$2"
    local dest="$3"
    local vm_ip ssh_key

    vm_ip=$(registry_get "$vm_name" ".ip")
    ssh_key=$(registry_get "$vm_name" ".ssh_key")
    ssh_key="${ssh_key%\"}"
    ssh_key="${ssh_key#\"}"

    if [[ -z "$ssh_key" || "$ssh_key" == "null" ]]; then
        scp $FOUNDRY_SSH_OPTS -r "$source" "${FOUNDRY_SSH_USER}@${vm_ip}:${dest}"
    else
        scp -i "$ssh_key" $FOUNDRY_SSH_OPTS -r "$source" "${FOUNDRY_SSH_USER}@${vm_ip}:${dest}"
    fi
}

_sync_gh_watcher_scripts() {
    local vm_name="$1"
    local watcher_root="$AGENT_FOUNDRY_BASE_DIR/templates/gh-watcher"
    local vm_helper_dir="/opt/foundry/gh-watcher"
    local chmod_paths=""

    _ssh_cmd "$vm_name" "mkdir -p $vm_helper_dir" || return 1

    # Core watcher files. Array entries are "host_src:vm_dst".
    local files=(
        "$watcher_root/gh_watcher.sh:$vm_helper_dir/gh_watcher.sh"
        "$watcher_root/gh_watcher.sh:/opt/foundry/ralph_gh_watcher.sh"
        "$watcher_root/gh_watcher_common.sh:$vm_helper_dir/gh_watcher_common.sh"
    )

    # One adapter per autonomous agent type; registry is the source of truth.
    local agent adapter_src adapter_dst
    for agent in $(agent_autonomous_types); do
        adapter_src=$(agent_watcher_adapter "$agent")
        if [[ -z "$adapter_src" || ! -f "$adapter_src" ]]; then
            log_debug "No watcher adapter found for agent '$agent', skipping"
            continue
        fi
        adapter_dst="$vm_helper_dir/$(basename "$adapter_src")"
        files+=("$adapter_src:$adapter_dst")
    done

    local pair src dst
    for pair in "${files[@]}"; do
        src="${pair%%:*}"
        dst="${pair##*:}"
        _scp_to_vm_path "$vm_name" "$src" "$dst" || return 1
        chmod_paths="$chmod_paths $dst"
    done

    _ssh_cmd "$vm_name" "chmod 755$chmod_paths" || return 1
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

_get_watcher_agent_type() {
    local vm_name="$1"
    local project_dir="${2:-}"
    local agent_type

    # Prefer the agent type currently recorded in the VM registry.
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null || true)
    agent_type="${agent_type%\"}"
    agent_type="${agent_type#\"}"

    if agent_is_autonomous "$agent_type" 2>/dev/null; then
        echo "$agent_type"
        return 0
    fi

    # If no agent has been started yet, derive the autonomous agent type from
    # the project's agents.json. This lets `gh-watcher init` work for a freshly
    # created/synced VM before the agent has ever been started manually.
    if [[ -z "$project_dir" ]]; then
        project_dir=$(registry_get "$vm_name" ".project_dir" 2>/dev/null || true)
        project_dir="${project_dir%\"}"
        project_dir="${project_dir#\"}"
    fi

    if [[ -n "$project_dir" && -f "$project_dir/agents.json" ]]; then
        local agent_entry
        while IFS= read -r agent_entry; do
            agent_type=$(agent_type_from_agents_json "$agent_entry")
            if agent_is_autonomous "$agent_type" 2>/dev/null; then
                echo "$agent_type"
                return 0
            fi
        done < <(jq -r '.agents[]' "$project_dir/agents.json" 2>/dev/null)
    fi

    # Fallback to legacy Ralph variant detection.
    local installed_variant
    installed_variant=$(_get_installed_ralph_variant "$vm_name")
    case "$installed_variant" in
        "$RALPH_VARIANT_ORCHESTRATOR")
            echo "ralph-orchestrator"
            ;;
        "$RALPH_VARIANT_CLAUDE_CODE"|unknown)
            echo "ralph"
            ;;
        *)
            # Final fallback
            echo "ralph"
            ;;
    esac
}

_require_gh_watcher_supported_agent() {
    local vm_name="$1"
    local agent_type
    agent_type=$(_get_watcher_agent_type "$vm_name")

    if agent_is_autonomous "$agent_type" 2>/dev/null; then
        return 0
    fi

    log_error "Unsupported agent type for GitHub watcher: $agent_type"
    return 1
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
# agent_type: ralph (default), ralph-orchestrator, kimi-ralph, claude, gemini, codex
agent_start() {
    local vm_name="${1:-}"
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

    log_info "Starting $(agent_display_name "$agent_type") in VM '$vm_name'..."

    local workspace_path="${WORKSPACE_BASE}"
    local rc=0

    case "$(agent_category "$agent_type")" in
        autonomous)
            _start_autonomous_agent "$vm_name" "$workspace_path" "$agent_type"
            rc=$?
            ;;
        interactive)
            _start_interactive "$vm_name" "$workspace_path" "$agent_type"
            rc=$?
            ;;
        *)
            log_error "Unknown agent category for '$agent_type'"
            return 1
            ;;
    esac

    if [[ $rc -eq 0 ]]; then
        # Update registry
        registry_update "$vm_name" ".agent.type" "\"$agent_type\""
        registry_update "$vm_name" ".agent.status" "\"running\""
        registry_update "$vm_name" ".agent.session" "\"$(agent_session_name "$agent_type")\""

        log_info "Agent started successfully"
        log_info "  Type: $agent_type"
        log_info "  Attach with: foundry agent attach $vm_name"
    fi

    return $rc
}

# Render an autonomous agent start script inside the VM.
# Usage: _render_autonomous_start_script <vm_name> <workspace_path> <agent_type>
_render_autonomous_start_script() {
    local vm_name="$1"
    local workspace_path="$2"
    local agent_type="$3"

    local template_path
    template_path=$(agent_start_template "$agent_type")
    if [[ -z "$template_path" || ! -f "$template_path" ]]; then
        log_error "No start template for agent '$agent_type'"
        return 1
    fi

    local binary
    binary=$(agent_binary "$agent_type")

    local session_name
    session_name=$(agent_session_name "$agent_type")

    local log_file
    log_file=$(agent_log_file "$agent_type" "$workspace_path")

    local task_prompt_file
    task_prompt_file=$(agent_task_prompt_file "$agent_type" "$workspace_path")

    local max_iterations
    max_iterations=$(agent_max_iterations "$agent_type")

    local timeout_minutes
    timeout_minutes=$(agent_default_timeout_minutes "$agent_type")

    local ralph_variant="ralph-claude-code"
    if [[ "$agent_type" == "ralph-orchestrator" ]]; then
        ralph_variant="ralph-orchestrator"
    fi

    local start_script="/tmp/start-${agent_type}.sh"

    # Build a header that exports the variables the template references.
    local header
    header=$(cat <<EOF
#!/bin/bash
# Auto-generated by Agent Foundry for agent: $agent_type
export AGENT_WORKSPACE="$workspace_path"
export AGENT_TYPE="$agent_type"
export AGENT_BINARY="$binary"
export AGENT_SESSION_NAME="$session_name"
export AGENT_LOG_FILE="$log_file"
export AGENT_TASK_PROMPT_FILE="$task_prompt_file"
export AGENT_MAX_ITERATIONS="$max_iterations"
export AGENT_TIMEOUT_MINUTES="$timeout_minutes"
export AGENT_RALPH_VARIANT="$ralph_variant"
EOF
)

    # Copy template into place and prepend the variable header.
    local tmp_template
    tmp_template=$(mktemp)
    printf '%s\n' "$header" > "$tmp_template"
    cat "$template_path" >> "$tmp_template"
    _scp_to_vm_path "$vm_name" "$tmp_template" "$start_script" || {
        rm -f "$tmp_template"
        return 1
    }
    rm -f "$tmp_template"

    _ssh_cmd "$vm_name" "chmod +x '$start_script'" || return 1
    echo "$start_script"
}

# Start an autonomous agent in a tmux session.
# Usage: _start_autonomous_agent <vm_name> <workspace_path> <agent_type>
_start_autonomous_agent() {
    local vm_name="$1"
    local workspace_path="$2"
    local agent_type="$3"

    log_debug "Starting $(agent_display_name "$agent_type") in tmux session..."

    if ! agent_is_autonomous "$agent_type"; then
        log_error "Agent '$agent_type' is not autonomous"
        return 1
    fi

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

    # Agent-specific preflight checks.
    case "$agent_type" in
        ralph|ralph-orchestrator)
            local installed_variant effective_variant
            installed_variant=$(_get_installed_ralph_variant "$vm_name")
            _validate_requested_ralph_variant "$agent_type" "$installed_variant" || return 1

            effective_variant="$installed_variant"
            if [[ "$effective_variant" == "unknown" ]]; then
                if [[ "$agent_type" == "ralph-orchestrator" ]]; then
                    effective_variant="$RALPH_VARIANT_ORCHESTRATOR"
                else
                    effective_variant="$RALPH_VARIANT_CLAUDE_CODE"
                fi
                log_warn "Unable to detect Ralph variant from VM metadata; assuming '$effective_variant'"
            fi
            log_info "Using Ralph variant: $effective_variant"

            if [[ "$effective_variant" == "$RALPH_VARIANT_ORCHESTRATOR" ]]; then
                if ! _ssh_cmd "$vm_name" "test -f '$workspace_path/ralph.yml'"; then
                    log_error "Ralph Orchestrator config not found: $workspace_path/ralph.yml"
                    log_info "Add ralph.yml to your project and run: foundry workspace sync $vm_name"
                    return 1
                fi
            else
                if ! _ssh_cmd "$vm_name" "test -d '$workspace_path/.ralph'"; then
                    log_error "Ralph configuration directory not found: $workspace_path/.ralph"
                    log_info "Initialize workspace first with: foundry workspace init $vm_name"
                    return 1
                fi
            fi
            ;;
        kimi-ralph)
            if ! _ssh_cmd "$vm_name" "command -v kimi >/dev/null 2>&1"; then
                log_error "kimi binary not found in VM PATH"
                log_info "Ensure kimi is installed (run workspace init/sync)"
                return 1
            fi
            ;;
    esac

    local binary session_name start_script
    binary=$(agent_binary "$agent_type")
    session_name=$(agent_session_name "$agent_type")

    # Verify binary is present.
    if ! _ssh_cmd "$vm_name" "command -v '$binary' >/dev/null 2>&1"; then
        log_error "'$binary' binary not found in VM PATH"
        log_info "Ensure $(agent_display_name "$agent_type") is installed"
        return 1
    fi

    # Kill existing session if any
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t '$session_name' 2>/dev/null || true"

    # Create logs directory if it doesn't exist
    _ssh_cmd "$vm_name" "mkdir -p '$workspace_path/logs'"

    # Render start script from template.
    start_script=$(_render_autonomous_start_script "$vm_name" "$workspace_path" "$agent_type")
    if [[ -z "$start_script" ]]; then
        log_error "Failed to render start script for '$agent_type'"
        return 1
    fi

    # Try to start tmux session (use _ssh_cmd_tty for PTY allocation)
    local tmux_output tmux_rc
    tmux_output=$(_ssh_cmd_tty "$vm_name" "tmux new-session -d -s '$session_name' '$start_script' 2>&1")
    tmux_rc=$?
    if [[ $tmux_rc -ne 0 ]]; then
        log_error "Tmux command failed (exit code: $tmux_rc)"
        log_error "Tmux output: $tmux_output"
    fi

    # Verify session started
    sleep 1
    if _ssh_cmd_tty "$vm_name" "tmux has-session -t '$session_name' 2>/dev/null"; then
        log_debug "$(agent_display_name "$agent_type") tmux session started"
        return 0
    else
        log_error "Failed to start $(agent_display_name "$agent_type") tmux session"
        log_debug "Checking for tmux server..."
        _ssh_cmd_tty "$vm_name" "tmux list-sessions 2>&1" || log_debug "No tmux sessions found"
        log_debug "Checking $binary process..."
        _ssh_cmd "$vm_name" "pgrep -a '$binary'" || log_debug "No $binary process found"
        return 1
    fi
}

# Start interactive agent in screen session
_start_interactive() {
    local vm_name="$1"
    local workspace_path="$2"
    local agent_type="$3"
    local cli_name session_name
    cli_name=$(agent_binary "$agent_type")
    session_name=$(agent_session_name "$agent_type")

    log_debug "Starting $cli_name in screen session..."

    # Check if workspace exists
    if ! _ssh_cmd "$vm_name" "test -d '$workspace_path'"; then
        log_warn "Workspace not found, using home directory"
        workspace_path="/root"
    fi

    # Kill existing session if any
    _ssh_cmd_tty "$vm_name" "screen -S '$session_name' -X quit 2>/dev/null || true"

    # Start CLI in screen session
    _ssh_cmd_tty "$vm_name" "cd '$workspace_path' && screen -dmS '$session_name' '$cli_name'"

    # Verify session started
    sleep 1
    if _ssh_cmd_tty "$vm_name" "screen -list | grep -q '$session_name'"; then
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

    log_info "Stopping $(agent_display_name "$agent_type") in VM '$vm_name'..."

    local session_name
    session_name=$(agent_session_name "$agent_type")

    # Kill tmux session (for autonomous agents)
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t '$session_name' 2>/dev/null || true"

    # Kill screen session (for interactive agents)
    _ssh_cmd_tty "$vm_name" "screen -S '$session_name' -X quit 2>/dev/null || true"

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

    local session_name
    session_name=$(agent_session_name "$agent_type")

    case "$(agent_session_backend "$agent_type")" in
        tmux)
            exec ssh -t $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
                "tmux attach-session -t '$session_name'"
            ;;
        screen)
            exec ssh -t $ssh_key_opt $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
                "screen -r '$session_name'"
            ;;
        *)
            log_error "Unknown session backend for agent type: $agent_type"
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

        local session_name
        session_name=$(agent_session_name "$agent_type")

        case "$(agent_session_backend "$agent_type")" in
            tmux)
                if _ssh_cmd_tty "$vm_name" "tmux has-session -t '$session_name' 2>/dev/null"; then
                    echo "  tmux ($session_name): running"
                    _ssh_cmd_tty "$vm_name" "tmux list-windows -t '$session_name' 2>/dev/null" | \
                        sed 's/^/    /'
                else
                    echo "  tmux ($session_name): not running"
                fi
                ;;
            screen)
                if _ssh_cmd_tty "$vm_name" "screen -list | grep -q '$session_name' 2>/dev/null"; then
                    echo "  screen ($session_name): running"
                else
                    echo "  screen ($session_name): not running"
                fi
                ;;
        esac
    fi

    return 0
}

# ============================================================================
# AGENT LOGS
# ============================================================================

_resolve_agent_log_path() {
    local vm_name="$1"
    local agent_type="${2:-}"

    if [[ -z "$agent_type" || "$agent_type" == "null" ]]; then
        agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null || true)
    fi

    local primary_log
    if agent_is_valid "$agent_type" 2>/dev/null; then
        primary_log=$(agent_log_file "$agent_type" "$WORKSPACE_BASE")
    else
        primary_log="${WORKSPACE_BASE}/logs/ralph.log"
    fi

    # Watcher-driven autonomous runs log to a separate file.
    local watcher_log="${WORKSPACE_BASE}/logs/ralph-watcher.log"

    # Prefer the log that matches the currently active agent session.
    if _ssh_cmd "$vm_name" "tmux has-session -t ralph-loop 2>/dev/null"; then
        echo "$watcher_log"
        return 0
    fi
    if _ssh_cmd "$vm_name" "tmux has-session -t foundry-agent 2>/dev/null"; then
        echo "$primary_log"
        return 0
    fi

    # No active session: return whichever log file exists, defaulting to primary.
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

    if ! agent_is_autonomous "$agent_type"; then
        log_error "Autostart is only supported for autonomous agents (got: $agent_type)"
        return 1
    fi

    log_info "Enabling autostart for $(agent_display_name "$agent_type") in VM '$vm_name'..."

    local workspace_path="${WORKSPACE_BASE}"
    local session_name start_script
    session_name=$(agent_session_name "$agent_type")
    start_script="/tmp/start-${agent_type}.sh"

    # The start script must already exist from a previous agent_start, or we
    # render it now so the service has something stable to run.
    if ! _ssh_cmd "$vm_name" "test -x '$start_script'"; then
        start_script=$(_render_autonomous_start_script "$vm_name" "$workspace_path" "$agent_type")
        if [[ -z "$start_script" ]]; then
            log_error "Failed to render start script for autostart"
            return 1
        fi
    fi

    # Create systemd service
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=Agent Foundry - $(agent_display_name "$agent_type")
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=$workspace_path
ExecStart=/usr/bin/tmux new-session -d -s $session_name $start_script
ExecStop=/usr/bin/tmux kill-session -t $session_name
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
    local vm_name="${1:-}"
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
    _require_gh_watcher_supported_agent "$vm_name" || return 1

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

    local watcher_agent_type watcher_display_name project_dir
    if [[ -n "$project_config" ]]; then
        project_dir=$(dirname "$project_config")
    fi
    watcher_agent_type=$(_get_watcher_agent_type "$vm_name" "$project_dir")
    watcher_display_name=$(agent_display_name "$watcher_agent_type")

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

# Agent execution timeout in minutes
AGENT_TIMEOUT=$ralph_timeout

# Autonomous agent type that will handle triggered tasks
AGENT_TYPE="$watcher_agent_type"
AGENT_DISPLAY_NAME="$watcher_display_name"

# Legacy Ralph timeout (kept for backward compatibility)
RALPH_TIMEOUT=$ralph_timeout

# Post error comments on failure
POST_ERROR_COMMENTS=$post_error_comments
EOF
)

    _write_gh_watcher_vm_files "$vm_name" "$config_content" "$github_token"

    # Mark all existing trigger mentions as processed so the first start does
    # not immediately begin working through historical issues/PRs.
    agent_gh_watcher_mark_all "$vm_name" || return 1

    log_info "GitHub watcher initialized successfully"
    log_info "  Watching: $watched_repos"
    log_info "  Agent type: $watcher_agent_type"
    log_info "  Agent workspace: /root"
    if [[ -n "$project_config" ]]; then
        log_info "  Config source: $project_config"
    fi
    log_info ""
    log_info "Start watcher with: foundry agent gh-watcher start $vm_name"

    return 0
}

# Start GitHub watcher daemon
# Usage: agent_gh_watcher_start <vm_name> [--new|--all]
agent_gh_watcher_start() {
    local vm_name="${1:-}"
    shift || true
    local flags="$*"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1
    _require_gh_watcher_supported_agent "$vm_name" || return 1

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

    # Sync latest watcher scripts before starting
    _sync_gh_watcher_scripts "$vm_name" || return 1

    # Start watcher in tmux session
    _ssh_cmd_tty "$vm_name" "tmux new-session -d -s ralph-gh-watcher '/opt/foundry/gh-watcher/gh_watcher.sh start $flags'"

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

# Mark all existing mentions as processed
# Usage: agent_gh_watcher_mark_all <vm_name>
agent_gh_watcher_mark_all() {
    local vm_name="${1:-}"
    local watcher_was_running=false

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1
    _require_gh_watcher_supported_agent "$vm_name" || return 1

    if _ssh_cmd "$vm_name" "tmux has-session -t ralph-gh-watcher" >/dev/null 2>&1; then
        watcher_was_running=true
        log_info "Stopping running GitHub watcher before mark-all to avoid state races..."
        _ssh_cmd "$vm_name" "tmux kill-session -t ralph-gh-watcher 2>/dev/null || true" || return 1
    fi

    log_info "Syncing local GitHub watcher scripts into VM '$vm_name'..."
    _sync_gh_watcher_scripts "$vm_name" || return 1

    log_info "Marking all existing trigger mentions as processed in VM '$vm_name'..."
    if ! _ssh_cmd "$vm_name" "/opt/foundry/gh-watcher/gh_watcher.sh mark-all"; then
        log_error "GitHub watcher mark-all failed"
        return 1
    fi

    log_info "Verified existing !ralph mentions are marked as processed"
    if [[ "$watcher_was_running" == "true" ]]; then
        log_info "Watcher was stopped for mark-all. Restart it with: foundry agent gh-watcher start $vm_name"
    fi
}

# Stop GitHub watcher daemon
# Usage: agent_gh_watcher_stop <vm_name>
agent_gh_watcher_stop() {
    local vm_name="${1:-}"

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

    local watcher_agent_type
    watcher_agent_type=$(_get_watcher_agent_type "$vm_name")
    echo "  Agent type: $watcher_agent_type"
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
# FORGEJO WATCHER MANAGEMENT
# ============================================================================

_sync_forgejo_watcher_scripts() {
    local vm_name="$1"
    local watcher_root="$AGENT_FOUNDRY_BASE_DIR/templates/forgejo"
    local vm_helper_dir="/opt/foundry/forgejo"
    local chmod_paths=""

    _ssh_cmd "$vm_name" "mkdir -p $vm_helper_dir" || return 1

    local files=(
        "$watcher_root/forgejo_watcher.sh:$vm_helper_dir/forgejo_watcher.sh"
        "$watcher_root/forgejo_watcher_common.sh:$vm_helper_dir/forgejo_watcher_common.sh"
        "$watcher_root/forgejo_receiver.sh:$vm_helper_dir/forgejo_receiver.sh"
        "$watcher_root/forgejo_hook_manager.sh:$vm_helper_dir/forgejo_hook_manager.sh"
    )

    local agent adapter_src adapter_dst
    for agent in $(agent_autonomous_types); do
        adapter_src=$(agent_watcher_adapter_for "$agent" forgejo)
        if [[ -z "$adapter_src" || ! -f "$adapter_src" ]]; then
            log_debug "No Forgejo watcher adapter found for agent '$agent', skipping"
            continue
        fi
        adapter_dst="$vm_helper_dir/$(basename "$adapter_src")"
        files+=("$adapter_src:$adapter_dst")
    done

    local pair src dst
    for pair in "${files[@]}"; do
        src="${pair%%:*}"
        dst="${pair##*:}"
        _scp_to_vm_path "$vm_name" "$src" "$dst" || return 1
        chmod_paths="$chmod_paths $dst"
    done

    _ssh_cmd "$vm_name" "chmod 755$chmod_paths" || return 1
}

_resolve_forgejo_watcher_project_config_path() {
    local vm_name="$1"
    local host_home config_root candidate project_dir project_name

    host_home="$(resolve_host_home)"
    config_root="${FOUNDRY_CONFIG_DIR:-${host_home}/.config/foundry}/projects"

    project_dir=$(registry_get "$vm_name" ".project_dir" 2>/dev/null || true)
    project_dir="${project_dir%\"}"
    project_dir="${project_dir#\"}"
    if [[ -n "$project_dir" && "$project_dir" != "null" ]]; then
        candidate="$project_dir/forgejo-watcher.json"
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

        candidate="$config_root/$project_name/forgejo-watcher.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi

        candidate="${AGENT_FOUNDRY_BASE_DIR}/projects/$project_name/forgejo-watcher.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

_load_forgejo_watcher_config() {
    local config_path="$1"
    local instance_url_var="$2"
    local watched_repos_var="$3"
    local token_var="$4"
    local webhook_secret_var="$5"
    local webhook_url_var="$6"
    local listen_port_var="$7"
    local agent_type_var="$8"
    local post_error_comments_var="$9"
    local watcher_enabled_var="${10}"
    local default_branch_var="${11:-}"
    local trigger_keyword_var="${12:-}"

    if ! jq -e . "$config_path" >/dev/null 2>&1; then
        log_error "Invalid forgejo-watcher config JSON: $config_path"
        return 1
    fi

    local cfg_instance_url cfg_watched_repos cfg_token cfg_token_file cfg_token_env
    local cfg_admin_token cfg_admin_token_file
    local cfg_webhook_secret cfg_webhook_secret_file cfg_webhook_url
    local cfg_listen_port cfg_agent_type cfg_post_error_comments cfg_watcher_enabled
    local cfg_default_branch cfg_trigger_keyword
    local token_path secret_path admin_token_path

    cfg_instance_url=$(jq -r '.instance_url // empty' "$config_path")
    cfg_watched_repos=$(jq -r '
        if (.watched_repos | type) == "array" then
            .watched_repos | join(",")
        elif (.watched_repos | type) == "string" then
            .watched_repos
        else
            empty
        end
    ' "$config_path")
    cfg_token=$(jq -r '.token // empty' "$config_path")
    cfg_token_file=$(jq -r '.token_file // empty' "$config_path")
    cfg_token_env=$(jq -r '.token_env // empty' "$config_path")
    cfg_admin_token=$(jq -r '.admin_token // empty' "$config_path")
    cfg_admin_token_file=$(jq -r '.admin_token_file // empty' "$config_path")
    cfg_webhook_secret=$(jq -r '.webhook_secret // empty' "$config_path")
    cfg_webhook_secret_file=$(jq -r '.webhook_secret_file // empty' "$config_path")
    cfg_webhook_url=$(jq -r '.webhook_url // empty' "$config_path")
    cfg_listen_port=$(jq -r '.listen_port // 8080' "$config_path")
    cfg_agent_type=$(jq -r '.agent_type // empty' "$config_path")
    cfg_post_error_comments=$(jq -r '.post_error_comments // true' "$config_path")
    cfg_watcher_enabled=$(jq -r '.enabled // true' "$config_path")
    cfg_default_branch=$(jq -r '.default_branch // "main"' "$config_path")
    cfg_trigger_keyword=$(jq -r '.trigger_keyword // "!ralph"' "$config_path")

    if [[ -n "$cfg_token_file" ]]; then
        token_path=$(_resolve_host_path_from_project_file "$config_path" "$cfg_token_file")
        if [[ ! -f "$token_path" ]]; then
            log_error "Forgejo token file from config not found: $token_path"
            return 1
        fi
        cfg_token="$(<"$token_path")"
    elif [[ -n "$cfg_token_env" ]]; then
        cfg_token="${!cfg_token_env:-}"
    fi

    if [[ -n "$cfg_admin_token_file" ]]; then
        admin_token_path=$(_resolve_host_path_from_project_file "$config_path" "$cfg_admin_token_file")
        if [[ ! -f "$admin_token_path" ]]; then
            log_error "Forgejo admin token file from config not found: $admin_token_path"
            return 1
        fi
        cfg_admin_token="$(<"$admin_token_path")"
    fi

    if [[ -n "$cfg_webhook_secret_file" ]]; then
        secret_path=$(_resolve_host_path_from_project_file "$config_path" "$cfg_webhook_secret_file")
        if [[ ! -f "$secret_path" ]]; then
            log_error "Webhook secret file from config not found: $secret_path"
            return 1
        fi
        cfg_webhook_secret="$(<"$secret_path")"
    fi

    if [[ -z "$cfg_instance_url" ]]; then
        log_error "forgejo-watcher config missing instance_url: $config_path"
        return 1
    fi

    if [[ -z "$cfg_watched_repos" ]]; then
        log_error "forgejo-watcher config missing watched_repos: $config_path"
        return 1
    fi

    printf -v "$instance_url_var" '%s' "$cfg_instance_url"
    printf -v "$watched_repos_var" '%s' "$cfg_watched_repos"
    printf -v "$token_var" '%s' "$cfg_token"
    printf -v "$webhook_secret_var" '%s' "$cfg_webhook_secret"
    printf -v "$webhook_url_var" '%s' "$cfg_webhook_url"
    printf -v "$listen_port_var" '%s' "$cfg_listen_port"
    printf -v "$agent_type_var" '%s' "$cfg_agent_type"
    printf -v "$post_error_comments_var" '%s' "$cfg_post_error_comments"
    printf -v "$watcher_enabled_var" '%s' "$cfg_watcher_enabled"
    if [[ -n "$default_branch_var" ]]; then
        printf -v "$default_branch_var" '%s' "$cfg_default_branch"
    fi
    if [[ -n "$trigger_keyword_var" ]]; then
        printf -v "$trigger_keyword_var" '%s' "$cfg_trigger_keyword"
    fi
}

_write_forgejo_watcher_vm_files() {
    local vm_name="$1"
    local config_content="$2"
    local forgejo_token="$3"
    local webhook_secret="${4:-}"
    local admin_token="${5:-}"
    local tmp_config tmp_processed tmp_token tmp_secret tmp_admin_token vm_ip ssh_key

    tmp_config=""
    tmp_processed=""
    tmp_token=""
    tmp_secret=""
    tmp_admin_token=""

    cleanup_vm_files() {
        [[ -n "$tmp_config" ]] && rm -f "$tmp_config"
        [[ -n "$tmp_processed" ]] && rm -f "$tmp_processed"
        [[ -n "$tmp_token" ]] && rm -f "$tmp_token"
        [[ -n "$tmp_secret" ]] && rm -f "$tmp_secret"
        [[ -n "$tmp_admin_token" ]] && rm -f "$tmp_admin_token"
    }
    trap cleanup_vm_files EXIT

    _ssh_cmd "$vm_name" "mkdir -p /root/.config/forgejo-watcher /root/.config/forgejo-watcher/queue"
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
    printf '%s\n' "$forgejo_token" > "$tmp_token"

    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_config" "/root/.config/forgejo-watcher/config.conf"
    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_processed" "/root/.config/forgejo-watcher/processed.json"
    _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_token" "/root/.config/forgejo-watcher/token"

    if [[ -n "$webhook_secret" ]]; then
        tmp_secret=$(mktemp)
        printf '%s\n' "$webhook_secret" > "$tmp_secret"
        _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_secret" "/root/.config/forgejo-watcher/webhook-secret"
    fi

    if [[ -n "$admin_token" ]]; then
        tmp_admin_token=$(mktemp)
        printf '%s\n' "$admin_token" > "$tmp_admin_token"
        _scp_to_vm "$vm_ip" "$ssh_key" "$tmp_admin_token" "/root/.config/forgejo-watcher/admin-token"
    fi

    _ssh_cmd "$vm_name" "chmod 600 /root/.config/forgejo-watcher/token /root/.config/forgejo-watcher/webhook-secret /root/.config/forgejo-watcher/admin-token 2>/dev/null; touch /root/.config/forgejo-watcher/watcher.log"

    trap - EXIT
    cleanup_vm_files
}

agent_forgejo_watcher_init() {
    local vm_name="${1:-}"
    local instance_url=""
    local watched_repos=""
    local token=""
    local webhook_secret=""
    local webhook_url=""
    local listen_port="8080"
    local agent_type=""
    local post_error_comments="true"
    local watcher_enabled="true"
    local default_branch="main"
    local trigger_keyword="!ralph"
    local admin_token=""
    local project_config=""

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Initializing Forgejo watcher for VM '$vm_name'..."
    project_config=$(_resolve_forgejo_watcher_project_config_path "$vm_name" || true)
    if [[ -n "$project_config" ]]; then
        log_info "Loading watcher config from $project_config"
        _load_forgejo_watcher_config \
            "$project_config" \
            instance_url \
            watched_repos \
            token \
            webhook_secret \
            webhook_url \
            listen_port \
            agent_type \
            post_error_comments \
            watcher_enabled \
            default_branch \
            trigger_keyword \
            admin_token || return 1
    fi

    if [[ -z "$instance_url" ]]; then
        echo ""
        echo "Forgejo Watcher Configuration"
        echo "============================="
        echo ""
        read -r -p "Forgejo instance URL (e.g., https://git.example.com): " instance_url
        if [[ -z "$instance_url" ]]; then
            log_error "No instance URL specified"
            return 1
        fi
    fi

    if [[ -z "$watched_repos" ]]; then
        read -r -p "Enter repositories to watch (comma-separated, e.g., owner/repo1,owner/repo2): " watched_repos
        if [[ -z "$watched_repos" ]]; then
            log_error "No repositories specified"
            return 1
        fi
    fi

    if [[ -z "$token" ]]; then
        echo ""
        echo "Forgejo Token Setup"
        echo "==================="
        echo "You need a Forgejo API token with these permissions:"
        echo "  - repository: write"
        echo "  - issue: write"
        echo "  - pull_request: write"
        echo ""
        read -r -s -p "Enter Forgejo token (input hidden): " token
        echo ""

        if [[ -z "$token" ]]; then
            log_error "No token provided"
            return 1
        fi
    fi

    if [[ -z "$webhook_url" ]]; then
        local vm_ip
        vm_ip=$(_get_vm_ip "$vm_name" 2>/dev/null || true)
        if [[ -n "$vm_ip" ]]; then
            webhook_url="http://${vm_ip}:${listen_port}/webhook"
            log_info "Auto-derived webhook URL: $webhook_url"
        else
            read -r -p "Webhook URL where Forgejo can reach this VM (e.g., https://foundry-vm.example.com:8080/webhook): " webhook_url
        fi
    fi

    if [[ -z "$webhook_secret" ]]; then
        read -r -s -p "Enter webhook secret (input hidden, optional): " webhook_secret
        echo ""
    fi

    local watcher_agent_type watcher_display_name project_dir
    if [[ -n "$project_config" ]]; then
        project_dir=$(dirname "$project_config")
    fi
    watcher_agent_type=$(_get_watcher_agent_type "$vm_name" "$project_dir")
    if [[ -n "$agent_type" ]]; then
        watcher_agent_type="$agent_type"
    fi
    watcher_display_name=$(agent_display_name "$watcher_agent_type")

    local config_content
    config_content=$(cat <<EOF
# Forgejo Watcher Configuration

WATCHER_ENABLED=$watcher_enabled

FORGEJO_INSTANCE_URL="$instance_url"
WATCHED_REPOS="$watched_repos"
FORGEJO_TOKEN_FILE="/root/.config/forgejo-watcher/token"

WEBHOOK_URL="$webhook_url"
WEBHOOK_SECRET_FILE="/root/.config/forgejo-watcher/webhook-secret"
RECEIVER_PORT=$listen_port
RECEIVER_INTERFACE="0.0.0.0"

AGENT_TIMEOUT=120
RALPH_TIMEOUT=120
AGENT_TYPE="$watcher_agent_type"
AGENT_DISPLAY_NAME="$watcher_display_name"

POST_ERROR_COMMENTS=$post_error_comments
TRIGGER_KEYWORD="$trigger_keyword"
DEFAULT_BRANCH="$default_branch"
FORGEJO_ADMIN_TOKEN_FILE="/root/.config/forgejo-watcher/admin-token"
EOF
)

    _write_forgejo_watcher_vm_files "$vm_name" "$config_content" "$token" "$webhook_secret" "$admin_token"

    log_info "Forgejo watcher initialized successfully"
    log_info "  Instance: $instance_url"
    log_info "  Watching: $watched_repos"
    log_info "  Agent type: $watcher_agent_type"
    log_info "  Receiver port: $listen_port"
    if [[ -n "$project_config" ]]; then
        log_info "  Config source: $project_config"
    fi
    log_info ""
    log_info "Register webhooks with: foundry agent forgejo-watcher register-hooks $vm_name"
    log_info "Start watcher with:     foundry agent forgejo-watcher start $vm_name"

    return 0
}

agent_forgejo_watcher_start() {
    local vm_name=""
    local no_mark_all="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-mark-all)
                no_mark_all="true"
                ;;
            --*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$vm_name" ]]; then
                    vm_name="$1"
                else
                    log_error "Unexpected argument: $1"
                    return 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    if ! _ssh_cmd "$vm_name" "test -f /root/.config/forgejo-watcher/config.conf"; then
        log_error "Forgejo watcher not initialized"
        log_info "Run: foundry agent forgejo-watcher init $vm_name"
        return 1
    fi

    if _ssh_cmd_tty "$vm_name" "tmux has-session -t forgejo-watcher 2>/dev/null"; then
        log_warn "Forgejo watcher already running in VM '$vm_name'"
        return 0
    fi

    if [[ "$no_mark_all" != "true" ]]; then
        log_info "Marking existing open issues/PRs as processed before start..."
        agent_forgejo_watcher_mark_all "$vm_name" || {
            log_warn "mark-all failed, continuing with start anyway"
        }
    fi

    log_info "Starting Forgejo watcher in VM '$vm_name'..."

    _sync_forgejo_watcher_scripts "$vm_name" || return 1

    _ssh_cmd_tty "$vm_name" "tmux new-session -d -s forgejo-watcher '/opt/foundry/forgejo/forgejo_watcher.sh start'"

    sleep 1
    if _ssh_cmd_tty "$vm_name" "tmux has-session -t forgejo-watcher 2>/dev/null"; then
        log_info "Forgejo watcher started successfully"
        log_info "  View logs: foundry agent forgejo-watcher logs $vm_name"
        log_info "  Check status: foundry agent forgejo-watcher status $vm_name"
        return 0
    fi

    log_error "Failed to start Forgejo watcher"
    return 1
}

agent_forgejo_watcher_stop() {
    local vm_name="${1:-}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Stopping Forgejo watcher in VM '$vm_name'..."

    _ssh_cmd_tty "$vm_name" "tmux kill-session -t forgejo-watcher 2>/dev/null || true"
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t forgejo-receiver 2>/dev/null || true"

    log_info "Forgejo watcher stopped"
    return 0
}

agent_forgejo_watcher_status() {
    local vm_name="${1:-}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Fetching Forgejo watcher status from VM '$vm_name'..."
    echo ""

    echo "Forgejo Watcher Status"
    echo "======================"

    local config_text enabled watched_repos instance_url listen_port agent_type
    if config_text=$(_ssh_cmd "$vm_name" "cat /root/.config/forgejo-watcher/config.conf" 2>/dev/null); then
        enabled=$(printf '%s\n' "$config_text" | sed -n 's/^WATCHER_ENABLED=//p' | tail -1 | tr -d '"')
        instance_url=$(printf '%s\n' "$config_text" | sed -n 's/^FORGEJO_INSTANCE_URL=//p' | tail -1 | sed 's/^"//; s/"$//')
        watched_repos=$(printf '%s\n' "$config_text" | sed -n 's/^WATCHED_REPOS=//p' | tail -1 | sed 's/^"//; s/"$//')
        listen_port=$(printf '%s\n' "$config_text" | sed -n 's/^RECEIVER_PORT=//p' | tail -1 | tr -d '"')
        agent_type=$(printf '%s\n' "$config_text" | sed -n 's/^AGENT_TYPE=//p' | tail -1 | tr -d '"')
        echo "Configuration: /root/.config/forgejo-watcher/config.conf"
        echo "  Enabled: ${enabled:-unknown}"
        echo "  Instance: ${instance_url:-unknown}"
        echo "  Repos: ${watched_repos:-unknown}"
        echo "  Receiver port: ${listen_port:-unknown}"
        echo "  Agent type: ${agent_type:-unknown}"
    else
        echo "Configuration: Not found"
    fi

    echo ""

    if _ssh_cmd "$vm_name" "tmux has-session -t forgejo-watcher 2>/dev/null"; then
        echo "Watcher session: RUNNING (tmux: forgejo-watcher)"
    else
        echo "Watcher session: NOT RUNNING"
    fi

    if _ssh_cmd "$vm_name" "tmux has-session -t forgejo-receiver 2>/dev/null"; then
        echo "Receiver session: RUNNING (tmux: forgejo-receiver)"
    else
        echo "Receiver session: NOT RUNNING"
    fi

    if _ssh_cmd "$vm_name" "tmux has-session -t ralph-loop 2>/dev/null"; then
        echo "Agent status: WORKING"
    else
        echo "Agent status: IDLE"
    fi

    echo ""

    if _ssh_cmd "$vm_name" "test -f /root/.config/forgejo-watcher/processed.json"; then
        local processed_count last_poll
        processed_count=$(_ssh_cmd "$vm_name" "jq '.processed | length' /root/.config/forgejo-watcher/processed.json" 2>/dev/null)
        last_poll=$(_ssh_cmd "$vm_name" "jq -r '.last_poll' /root/.config/forgejo-watcher/processed.json" 2>/dev/null || true)
        echo "Processed tasks: ${processed_count:-0}"
        echo "Last poll: ${last_poll:-unknown}"
    fi
}

agent_forgejo_watcher_logs() {
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

    local log_path="/root/.config/forgejo-watcher/watcher.log"

    log_info "Viewing Forgejo watcher logs from $log_path"
    if [[ -n "$follow" ]]; then
        log_info "Following logs... (Ctrl+C to stop)"
    fi
    echo ""

    if ! _ssh_cmd "$vm_name" "test -f '$log_path'"; then
        log_warn "Log file not found: $log_path"
        return 0
    fi

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

agent_forgejo_watcher_reset() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_warn "This will clear all Forgejo watcher state"
    if ! confirm "Are you sure?"; then
        log_info "Cancelled"
        return 0
    fi

    log_info "Resetting Forgejo watcher state in VM '$vm_name'..."

    _ssh_cmd "$vm_name" "cat > /root/.config/forgejo-watcher/processed.json" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF

    _ssh_cmd "$vm_name" "rm -f /root/.config/forgejo-watcher/current_task.json /root/.config/forgejo-watcher/current_context.json /root/.config/forgejo-watcher/retries.json /root/.config/forgejo-watcher/run-status.json /root/.config/forgejo-watcher/queue/event-*.json"

    log_info "Forgejo watcher state reset"
}

agent_forgejo_watcher_mark_all() {
    local vm_name="${1:-}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    if ! _ssh_cmd "$vm_name" "test -f /root/.config/forgejo-watcher/config.conf"; then
        log_error "Forgejo watcher not initialized"
        log_info "Run: foundry agent forgejo-watcher init $vm_name"
        return 1
    fi

    log_info "Marking all open issues and PRs as processed in VM '$vm_name'..."

    local vm_ip ssh_key_path mark_all_script
    vm_ip=$(_get_vm_ip "$vm_name")
    ssh_key_path=$(_get_vm_ssh_key "$vm_name")
    mark_all_script="${AGENT_FOUNDRY_BASE_DIR}/templates/forgejo/forgejo_mark_all.sh"

    if [[ ! -f "$mark_all_script" ]]; then
        log_error "Mark-all script not found: $mark_all_script"
        return 1
    fi

    _scp_to_vm "$vm_ip" "$ssh_key_path" "$mark_all_script" "/tmp/forgejo_mark_all.sh"
    _ssh_cmd "$vm_name" "chmod +x /tmp/forgejo_mark_all.sh && /tmp/forgejo_mark_all.sh"
}

agent_forgejo_watcher_register_hooks() {
    local vm_name="${1:-}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    if ! _ssh_cmd "$vm_name" "test -f /root/.config/forgejo-watcher/config.conf"; then
        log_error "Forgejo watcher not initialized"
        log_info "Run: foundry agent forgejo-watcher init $vm_name"
        return 1
    fi

    _sync_forgejo_watcher_scripts "$vm_name" || return 1

    log_info "Registering Forgejo webhooks for VM '$vm_name'..."
    _ssh_cmd "$vm_name" "/opt/foundry/forgejo/forgejo_hook_manager.sh register" || {
        log_error "Failed to register Forgejo webhooks"
        return 1
    }

    log_info "Forgejo webhooks registered"
}

agent_forgejo_watcher_unregister_hooks() {
    local vm_name="${1:-}"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    _sync_forgejo_watcher_scripts "$vm_name" || return 1

    log_info "Unregistering Forgejo webhooks for VM '$vm_name'..."
    _ssh_cmd "$vm_name" "/opt/foundry/forgejo/forgejo_hook_manager.sh unregister" || {
        log_error "Failed to unregister Forgejo webhooks"
        return 1
    }

    log_info "Forgejo webhooks unregistered"
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
#   # Forgejo Watcher
#   foundry agent forgejo-watcher init my-project
#   foundry agent forgejo-watcher register-hooks my-project
#   foundry agent forgejo-watcher start my-project
#   foundry agent forgejo-watcher status my-project
#   foundry agent forgejo-watcher logs my-project --follow
#   foundry agent forgejo-watcher stop my-project
#   foundry agent forgejo-watcher unregister-hooks my-project
#
