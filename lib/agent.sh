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
WORKSPACE_BASE="/root"

# SSH settings (inherit from vm.sh)
FOUNDRY_SSH_USER="${FOUNDRY_SSH_USER:-root}"
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o PasswordAuthentication=no}"

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

    local workspace_path="${WORKSPACE_BASE}"

    case "$agent_type" in
        ralph)
            _start_ralph "$vm_name" "$workspace_path"
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

    # Check if Ralph workspace is initialized (checking for .ralph directory)
    log_debug "Checking for .ralph directory at: $workspace_path/.ralph"
    if ! _ssh_cmd "$vm_name" "test -d '$workspace_path/.ralph'"; then
        log_error "Ralph configuration directory not found: $workspace_path/.ralph"
        log_info "Initialize workspace first with: foundry workspace init $vm_name"
        return 1
    fi
    log_debug "Ralph workspace directory found"

    # Kill existing session if any
    _ssh_cmd_tty "$vm_name" "tmux kill-session -t $AGENT_TMUX_SESSION 2>/dev/null || true"

    # Create logs directory if it doesn't exist
    _ssh_cmd "$vm_name" "mkdir -p $workspace_path/logs"

    # Start Ralph in new tmux session
    # Create a start script to avoid complex quoting issues with multi-layer shell escaping
    _ssh_cmd "$vm_name" "echo '#!/bin/bash' > /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo 'cd $workspace_path' >> /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo '# Reset circuit breaker if it exists (from previous runs)' >> /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo 'if [[ -f .ralph/.circuit_breaker_state ]]; then' >> /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo '    ralph --reset-circuit >/dev/null 2>&1 || true' >> /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo 'fi' >> /tmp/start-ralph.sh"
    _ssh_cmd "$vm_name" "echo 'exec ralph 2>&1 | tee -a logs/ralph.log' >> /tmp/start-ralph.sh"
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
        ralph)
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

    local log_path="${WORKSPACE_BASE}/logs/ralph.log"

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

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Initializing GitHub watcher for VM '$vm_name'..."

    # Prompt for configuration
    echo ""
    echo "GitHub Watcher Configuration"
    echo "============================="
    echo ""

    local watched_repos github_token

    # Get repositories to watch
    read -r -p "Enter repositories to watch (comma-separated, e.g., owner/repo1,owner/repo2): " watched_repos
    if [[ -z "$watched_repos" ]]; then
        log_error "No repositories specified"
        return 1
    fi

    # Get GitHub token
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

    # Create config directory in VM
    _ssh_cmd "$vm_name" "mkdir -p /root/.config/gh-watcher /root/.config/gh"

    # Create GitHub token file
    _ssh_cmd "$vm_name" "echo '$github_token' > /root/.config/gh/token"
    _ssh_cmd "$vm_name" "chmod 600 /root/.config/gh/token"

    # Create config file
    local config_content
    config_content=$(cat <<EOF
# GitHub Watcher Configuration

# Enable automatic polling
WATCHER_ENABLED=true

# Polling interval in seconds
POLL_INTERVAL=60

# Repositories to monitor (comma-separated)
WATCHED_REPOS="$watched_repos"

# GitHub token location
GITHUB_TOKEN_FILE="/root/.config/gh/token"

# Ralph execution timeout in minutes (max 120 per Ralph's limit)
RALPH_TIMEOUT=120

# Post error comments on failure
POST_ERROR_COMMENTS=true
EOF
)

    # Write config file using echo (heredoc doesn't work with _ssh_cmd's -n flag)
    local config_escaped
    config_escaped="${config_content//\"/\\\"}"
    _ssh_cmd "$vm_name" "echo \"$config_escaped\" > /root/.config/gh-watcher/config.conf"

    # Initialize processed.json
    _ssh_cmd "$vm_name" 'echo "{
  \\\"version\\\": \\\"1.0\\\",
  \\\"processed\\\": {},
  \\\"last_poll\\\": \\\"1970-01-01T00:00:00Z\\\"
}" > /root/.config/gh-watcher/processed.json'

    # Create log file
    _ssh_cmd "$vm_name" "touch /root/.config/gh-watcher/watcher.log"

    log_info "GitHub watcher initialized successfully"
    log_info "  Watching: $watched_repos"
    log_info "  Ralph workspace: /root"
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

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    log_info "Fetching GitHub watcher status from VM '$vm_name'..."
    echo ""

    _ssh_cmd "$vm_name" "/opt/foundry/ralph_gh_watcher.sh status"
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

    # Remove current task file
    _ssh_cmd "$vm_name" "rm -f /root/.config/gh-watcher/current_task.json"

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