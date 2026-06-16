#!/usr/bin/env bash
#
# Agent Foundry - Agent Registry
#
# Single source of truth for supported AI agent types and their runtime
# properties. This file is sourced by lib/agent.sh, lib/workspace.sh,
# bin/foundry, and standalone watcher scripts inside VMs, so it must stay
# plain bash 4+ compatible and self-contained.
#

# Whitespace-separated list of valid agent type identifiers.
AGENT_TYPES="ralph ralph-orchestrator kimi-ralph claude gemini codex"

# Returns 0 if the agent type is supported.
agent_is_valid() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator|kimi-ralph|claude|gemini|codex)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Echoes the display name for an agent type.
agent_display_name() {
    local agent="$1"
    case "$agent" in
        ralph) echo "Ralph (claude-code)" ;;
        ralph-orchestrator) echo "Ralph Orchestrator" ;;
        kimi-ralph) echo "Kimi Code CLI (Ralph mode)" ;;
        claude) echo "Claude Code CLI" ;;
        gemini) echo "Gemini CLI" ;;
        codex) echo "OpenAI Codex CLI" ;;
        *) echo "$agent" ;;
    esac
}

# Echoes "autonomous" or "interactive".
agent_category() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator|kimi-ralph)
            echo "autonomous"
            ;;
        claude|gemini|codex)
            echo "interactive"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Returns 0 if the agent is autonomous.
agent_is_autonomous() {
    [[ "$(agent_category "$1")" == "autonomous" ]]
}

# Returns 0 if the agent is interactive.
agent_is_interactive() {
    [[ "$(agent_category "$1")" == "interactive" ]]
}

# Echoes the session backend: "tmux" or "screen".
agent_session_backend() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator|kimi-ralph)
            echo "tmux"
            ;;
        claude|gemini|codex)
            echo "screen"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Echoes the binary name as it appears in PATH.
agent_binary() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator) echo "ralph" ;;
        kimi-ralph) echo "kimi" ;;
        claude) echo "claude" ;;
        gemini) echo "gemini" ;;
        codex) echo "codex" ;;
        *) echo "" ;;
    esac
}

# Echoes the installable package identifier.
agent_package() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator) echo "ralph" ;;
        kimi-ralph) echo "kimi-code" ;;
        claude) echo "@anthropic-ai/claude-code" ;;
        gemini) echo "@google/gemini-cli" ;;
        codex) echo "@openai/codex" ;;
        *) echo "" ;;
    esac
}

# Echoes the installer used by workspace provisioning: npm, uv, or ralph.
agent_install_method() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator) echo "ralph" ;;
        kimi-ralph) echo "kimi-code" ;;
        claude|gemini|codex) echo "npm" ;;
        *) echo "" ;;
    esac
}

# Echoes the dotfolder name synced from the project into the VM workspace.
agent_dotfolder() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator) echo ".ralph" ;;
        kimi-ralph) echo ".kimi" ;;
        claude) echo ".claude" ;;
        gemini) echo ".gemini" ;;
        codex) echo ".codex" ;;
        *) echo "" ;;
    esac
}

# Echoes the default session name used for attach/stop/status.
agent_session_name() {
    local agent="${1:-}"
    # Historically Ralph used "ralph-loop" for the watcher work session and
    # "foundry-agent" for the manually-started agent session. We keep the
    # manual session name generic so only one autonomous agent runs at a time.
    case "$agent" in
        ralph|ralph-orchestrator|kimi-ralph)
            echo "foundry-agent"
            ;;
        claude|gemini|codex)
            echo "foundry-agent"
            ;;
        *)
            echo "foundry-agent"
            ;;
    esac
}

# Echoes the watcher work session name (the session the GitHub watcher starts
# for an autonomous run).
agent_watcher_session_name() {
    echo "ralph-loop"
}

# Echoes the host-side start-script template path.
agent_start_template() {
    local agent="$1"
    local base_dir="${AGENT_FOUNDRY_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    case "$agent" in
        ralph|ralph-orchestrator)
            echo "$base_dir/templates/ralph/start-ralph.sh.template"
            ;;
        kimi-ralph)
            echo "$base_dir/templates/kimi/start-kimi-ralph.sh.template"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Echoes the host-side GitHub watcher adapter path.
agent_watcher_adapter() {
    local agent="$1"
    local base_dir="${AGENT_FOUNDRY_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    case "$agent" in
        ralph)
            echo "$base_dir/templates/ralph/gh_watcher_agent_ralph.sh"
            ;;
        ralph-orchestrator)
            echo "$base_dir/templates/ralph/gh_watcher_agent_ralph-orchestrator.sh"
            ;;
        kimi-ralph)
            echo "$base_dir/templates/kimi/gh_watcher_agent_kimi-ralph.sh"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Echoes the default log file path inside the VM for an autonomous agent.
agent_log_file() {
    local agent="$1"
    local workspace="${2:-/root}"
    echo "$workspace/logs/${agent}.log"
}

# Echoes the default task prompt file path inside the VM for an autonomous
# agent. The GitHub watcher writes the rendered task here before starting.
agent_task_prompt_file() {
    local agent="$1"
    local workspace="${2:-/root}"
    local dotfolder
    dotfolder="$(agent_dotfolder "$agent")"
    if [[ -n "$dotfolder" ]]; then
        echo "$workspace/$dotfolder/task_prompt.md"
    else
        echo "$workspace/.foundry/task_prompt.md"
    fi
}

# Echoes the default max Ralph iterations for agents that use a loop mode.
# 0 means "not applicable"; positive values are used directly.
agent_max_iterations() {
    local agent="$1"
    case "$agent" in
        kimi-ralph)
            echo "100"
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Echoes the default timeout in minutes for autonomous agent runs.
agent_default_timeout_minutes() {
    local agent="$1"
    case "$agent" in
        ralph|ralph-orchestrator)
            echo "120"
            ;;
        kimi-ralph)
            echo "120"
            ;;
        *)
            echo "120"
            ;;
    esac
}

# Echoes a comma-separated list of valid agent types (for error messages).
agent_valid_list() {
    local list=""
    local agent
    for agent in $AGENT_TYPES; do
        if [[ -n "$list" ]]; then
            list="$list, $agent"
        else
            list="$agent"
        fi
    done
    echo "$list"
}

# Echoes a space-separated list of autonomous agent types.
agent_autonomous_types() {
    local list=""
    local agent
    for agent in $AGENT_TYPES; do
        if agent_is_autonomous "$agent"; then
            list="$list $agent"
        fi
    done
    echo "${list# }"
}

# Echoes a space-separated list of interactive agent types.
agent_interactive_types() {
    local list=""
    local agent
    for agent in $AGENT_TYPES; do
        if agent_is_interactive "$agent"; then
            list="$list $agent"
        fi
    done
    echo "${list# }"
}

# Maps an agents.json identifier to the canonical agent type.
agent_type_from_agents_json() {
    local identifier="$1"
    case "$identifier" in
        frankbria/ralph-claude-code|ralph-claude-code)
            echo "ralph"
            ;;
        mikeyobrien/ralph-orchestrator|ralph-orchestrator)
            echo "ralph-orchestrator"
            ;;
        kimi-cli|moonshot-ai/kimi-cli|MoonshotAI/kimi-cli)
            echo "kimi-ralph"
            ;;
        @anthropic-ai/claude-code|anthropic-ai/claude-code|claude-code)
            echo "claude"
            ;;
        @openai/codex|openai/codex)
            echo "codex"
            ;;
        @google/gemini-cli|google/gemini-cli|gemini-cli)
            echo "gemini"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Echoes a space-separated list of supported agents.json identifiers.
agents_json_supported_identifiers() {
    echo "frankbria/ralph-claude-code mikeyobrien/ralph-orchestrator kimi-cli @anthropic-ai/claude-code @openai/codex @google/gemini-cli"
}

# Returns 0 if the agents.json identifier is supported.
agents_json_identifier_is_valid() {
    local identifier="$1"
    [[ -n "$(agent_type_from_agents_json "$identifier")" ]]
}
