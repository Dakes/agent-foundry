#!/usr/bin/env bash
#
# Agent Foundry - Agent Session Management
#
# Functions for managing AI agent sessions in VMs including starting,
# stopping, attaching to sessions, and viewing logs.
#
# Supported agent types:
# - ralph: ralph-claude-code autonomous agent (runs in tmux)
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

# Default agent type
FOUNDRY_DEFAULT_AGENT="${FOUNDRY_DEFAULT_AGENT:-ralph}"

# Session names
AGENT_TMUX_SESSION="foundry-agent"
AGENT_SCREEN_SESSION="foundry-agent"

# Agent paths in VM
RALPH_PATH="/opt/ralph/ralph"
WORKSPACE_BASE="/work"

# SSH settings (inherit from vm.sh)
FOUNDRY_SSH_USER="${FOUNDRY_SSH_USER:-root}"
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

_validate_agent_type() {
    local agent_type="$1"
    case "$agent_type" in
        ralph|claude|gemini|codex)
            return 0
            ;;
        *)
            log_error "Invalid agent type: $agent_type (valid: ralph, claude, gemini, codex)"
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
    local vm_ip="$1"
    shift
    ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "$@"
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

# ============================================================================
# AGENT START
# ============================================================================

# Start an agent in the VM
# Usage: agent_start <vm_name> [agent_type]
# agent_type: ralph (default), claude, gemini, codex
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

    local workspace_name
    workspace_name=$(_get_workspace_name "$vm_name")
    local workspace_path="${WORKSPACE_BASE}/${workspace_name}"

    case "$agent_type" in
        ralph)
            _start_ralph "$vm_ip" "$workspace_path"
            ;;
        claude)
            _start_interactive "$vm_ip" "$workspace_path" "claude"
            ;;
        gemini)
            _start_interactive "$vm_ip" "$workspace_path" "gemini"
            ;;
        codex)
            _start_interactive "$vm_ip" "$workspace_path" "codex"
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
    local vm_ip="$1"
    local workspace_path="$2"

    log_debug "Starting Ralph in tmux session..."

    # Check if workspace exists
    if ! _ssh_cmd "$vm_ip" "test -d '$workspace_path'"; then
        log_error "Workspace not found: $workspace_path"
        log_info "Initialize workspace first with: foundry workspace init $vm_name"
        return 1
    fi

    # Check if Ralph is installed
    if ! _ssh_cmd "$vm_ip" "command -v ralph >/dev/null 2>&1"; then
        log_error "Ralph not installed in VM"
        log_info "Initialize Ralph with: foundry workspace init-ralph $vm_name"
        return 1
    fi

    # Kill existing session if any
    _ssh_cmd "$vm_ip" "tmux kill-session -t $AGENT_TMUX_SESSION 2>/dev/null || true"

    # Start Ralph in new tmux session
    # Ralph runs with --yes to auto-confirm and --no-input for non-interactive
    _ssh_cmd "$vm_ip" "tmux new-session -d -s $AGENT_TMUX_SESSION -c '$workspace_path' \
        'ralph --yes 2>&1 | tee -a logs/ralph.log'"

    # Verify session started
    sleep 1
    if _ssh_cmd "$vm_ip" "tmux has-session -t $AGENT_TMUX_SESSION 2>/dev/null"; then
        log_debug "Ralph tmux session started"
        return 0
    else
        log_error "Failed to start Ralph tmux session"
        return 1
    fi
}

# Start interactive agent in screen session
_start_interactive() {
    local vm_ip="$1"
    local workspace_path="$2"
    local cli_name="$3"

    log_debug "Starting $cli_name in screen session..."

    # Check if workspace exists
    if ! _ssh_cmd "$vm_ip" "test -d '$workspace_path'"; then
        log_warn "Workspace not found, using home directory"
        workspace_path="/root"
    fi

    # Kill existing session if any
    _ssh_cmd "$vm_ip" "screen -S $AGENT_SCREEN_SESSION -X quit 2>/dev/null || true"

    # Start CLI in screen session
    _ssh_cmd "$vm_ip" "cd '$workspace_path' && screen -dmS $AGENT_SCREEN_SESSION $cli_name"

    # Verify session started
    sleep 1
    if _ssh_cmd "$vm_ip" "screen -list | grep -q $AGENT_SCREEN_SESSION"; then
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
    _ssh_cmd "$vm_ip" "tmux kill-session -t $AGENT_TMUX_SESSION 2>/dev/null || true"

    # Kill screen session (for interactive agents)
    _ssh_cmd "$vm_ip" "screen -S $AGENT_SCREEN_SESSION -X quit 2>/dev/null || true"

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

    local vm_ip agent_type agent_status
    vm_ip=$(_get_vm_ip "$vm_name")
    agent_type=$(registry_get "$vm_name" ".agent.type" 2>/dev/null)
    agent_status=$(registry_get "$vm_name" ".agent.status" 2>/dev/null)

    if [[ "$agent_status" != "running" ]]; then
        log_error "Agent not running in VM '$vm_name'"
        log_info "Start with: foundry agent start $vm_name"
        return 1
    fi

    log_info "Attaching to $agent_type session in VM '$vm_name'..."
    log_info "Detach with: Ctrl+b d (tmux) or Ctrl+a d (screen)"

    case "$agent_type" in
        ralph)
            # Attach to tmux
            exec ssh -t $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
                "tmux attach-session -t $AGENT_TMUX_SESSION"
            ;;
        claude|gemini|codex)
            # Attach to screen
            exec ssh -t $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" \
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
        if _ssh_cmd "$vm_ip" "tmux has-session -t $AGENT_TMUX_SESSION 2>/dev/null"; then
            echo "  tmux ($AGENT_TMUX_SESSION): running"
            _ssh_cmd "$vm_ip" "tmux list-windows -t $AGENT_TMUX_SESSION 2>/dev/null" | \
                sed 's/^/    /'
        else
            echo "  tmux ($AGENT_TMUX_SESSION): not running"
        fi

        # Check screen
        if _ssh_cmd "$vm_ip" "screen -list | grep -q $AGENT_SCREEN_SESSION 2>/dev/null"; then
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

    local workspace_name
    workspace_name=$(_get_workspace_name "$vm_name")
    local log_path="${WORKSPACE_BASE}/${workspace_name}/logs/ralph.log"

    log_info "Viewing agent logs from $log_path"
    if [[ -n "$follow" ]]; then
        log_info "Following logs... (Ctrl+C to stop)"
    fi

    # Check if log file exists
    if ! _ssh_cmd "$vm_ip" "test -f '$log_path'"; then
        log_warn "Log file not found: $log_path"
        log_info "Agent may not have started or no logs generated yet"

        # Try alternative log locations
        echo ""
        echo "Checking alternative log locations..."
        _ssh_cmd "$vm_ip" "ls -la ${WORKSPACE_BASE}/${workspace_name}/logs/ 2>/dev/null || echo 'No logs directory'"
        return 0
    fi

    # View or follow logs
    if [[ -n "$follow" ]]; then
        exec ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "tail -f '$log_path'"
    else
        _ssh_cmd "$vm_ip" "tail -100 '$log_path'"
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

    local workspace_name
    workspace_name=$(_get_workspace_name "$vm_name")
    local workspace_path="${WORKSPACE_BASE}/${workspace_name}"

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
ExecStart=/usr/bin/tmux new-session -d -s $AGENT_TMUX_SESSION -c $workspace_path 'ralph --yes 2>&1 | tee -a logs/ralph.log'
ExecStop=/usr/bin/tmux kill-session -t $AGENT_TMUX_SESSION
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)

    # Install service
    _ssh_cmd "$vm_ip" "cat > /etc/systemd/system/foundry-agent.service << 'EOFSERVICE'
$service_content
EOFSERVICE"

    # Enable and start
    _ssh_cmd "$vm_ip" "systemctl daemon-reload"
    _ssh_cmd "$vm_ip" "systemctl enable foundry-agent.service"

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

    _ssh_cmd "$vm_ip" "systemctl disable foundry-agent.service 2>/dev/null || true"
    _ssh_cmd "$vm_ip" "rm -f /etc/systemd/system/foundry-agent.service"
    _ssh_cmd "$vm_ip" "systemctl daemon-reload"

    log_info "Autostart disabled"
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
