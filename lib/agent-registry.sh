#!/usr/bin/env bash
#
# Agent Foundry - Agent Registry
#
# Single source of truth for supported AI agent types and their runtime
# properties. This file is sourced by lib/agent-sandbox.sh and by standalone
# watcher scripts running inside a sandbox, so it must stay plain bash 4+
# compatible and self-contained.
#
# Two categories:
#
#   interactive  claude, gemini, codex - a human drives them in a terminal.
#   autonomous   *-goal and claude-fleet - the run is unattended, which is what
#                a watcher can drive.
#
# The goal agents differ only in which binary is invoked; everything else
# about them is identical, which is why so many cases below collapse to one.
#
# claude-fleet is the exception: same binary as claude-goal, different launcher.
# It runs one Claude process as an orchestrator that delegates to builder and
# critic subagents behind a measured gate. It is not a different CLI, it is a
# different way of using the same one, which is why it shares the goal agent's
# watcher adapter and diverges only at the launcher.
#

# Whitespace-separated list of valid agent type identifiers.
AGENT_TYPES="claude gemini codex claude-goal codex-goal agy-goal claude-fleet"

# Returns 0 if the agent type is supported.
agent_is_valid() {
    local agent="$1"
    case "$agent" in
        claude|gemini|codex|claude-goal|codex-goal|agy-goal|claude-fleet)
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
        claude) echo "Claude Code CLI" ;;
        claude-goal) echo "Claude Code (goal loop)" ;;
        claude-fleet) echo "Claude Code (fleet)" ;;
        codex-goal) echo "Codex (goal loop)" ;;
        agy-goal) echo "Antigravity (goal loop)" ;;
        gemini) echo "Gemini CLI" ;;
        codex) echo "OpenAI Codex CLI" ;;
        *) echo "$agent" ;;
    esac
}

# Echoes the short identity the agent uses when speaking on an issue or PR.
#
# This is deliberately separate from agent_display_name: display names are
# verbose ("Claude Code (goal loop)") and belong in logs, while comment
# headers need a short, stable name. Every generated prompt and every watcher
# comment derives its header from this one function, so the name cannot drift
# between adapters.
agent_identity_name() {
    local agent="$1"
    case "$agent" in
        claude|claude-goal|claude-fleet) echo "Claude" ;;
        codex|codex-goal) echo "Codex" ;;
        agy-goal) echo "Antigravity" ;;
        gemini) echo "Gemini" ;;
        *) echo "Agent" ;;
    esac
}

# Echoes "autonomous" or "interactive".
agent_category() {
    local agent="$1"
    case "$agent" in
        claude-goal|codex-goal|agy-goal|claude-fleet)
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
        claude-goal|codex-goal|agy-goal|claude-fleet)
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
        claude|claude-goal|claude-fleet) echo "claude" ;;
        codex|codex-goal) echo "codex" ;;
        agy-goal) echo "agy" ;;
        gemini) echo "gemini" ;;
        *) echo "" ;;
    esac
}

# Echoes the installable package identifier.
agent_package() {
    local agent="$1"
    case "$agent" in
        claude|claude-goal|claude-fleet) echo "@anthropic-ai/claude-code" ;;
        codex|codex-goal) echo "@openai/codex" ;;
        agy-goal) echo "antigravity-cli" ;;
        gemini) echo "@google/gemini-cli" ;;
        *) echo "" ;;
    esac
}

# Echoes the installer the image build uses: npm, or the vendor's own script.
agent_install_method() {
    local agent="$1"
    case "$agent" in
        claude|gemini|codex|claude-goal|codex-goal|claude-fleet) echo "npm" ;;
        agy-goal) echo "installer" ;;
        *) echo "" ;;
    esac
}

# Echoes the dotfolder the agent keeps its own state in, under the volume root.
agent_dotfolder() {
    local agent="$1"
    case "$agent" in
        claude|claude-goal|claude-fleet) echo ".claude" ;;
        codex|codex-goal) echo ".codex" ;;
        agy-goal|gemini) echo ".gemini" ;;
        *) echo "" ;;
    esac
}

# Echoes the session name used for attach/stop/status.
#
# One name for every agent: only one agent runs per project, so a per-agent
# name would only make attach harder to predict.
agent_session_name() {
    echo "foundry-agent"
}

# Echoes the session name the watcher starts an autonomous run in.
#
# Kept distinct from agent_session_name so a manually attached agent and a
# watcher-driven run cannot silently be the same session.
agent_watcher_session_name() {
    echo "foundry-work"
}

# Echoes the host-side start-script template path.
agent_start_template() {
    local agent="$1"
    local base_dir="${AGENT_FOUNDRY_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    case "$agent" in
        claude-goal|codex-goal|agy-goal)
            # One template for all three: they differ only in the command line,
            # which it selects on AGENT_TYPE. The loop itself belongs to the
            # CLI, so there is nothing per-agent left to script.
            echo "$base_dir/templates/goal/start-goal.sh.template"
            ;;
        claude-fleet)
            # Its own launcher: the fleet needs its hooks and role definitions
            # materialised and verified before the CLI starts, and a gate that
            # is missing has to stop the run rather than be discovered by an
            # orchestrator halfway through a round.
            echo "$base_dir/templates/fleet/start-fleet.sh.template"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Returns 0 if the agent type can run the orchestrated fleet.
#
# The fleet is built on Claude Code's subagents, skills and hooks. No other CLI
# in the image has that combination, so a fleet request against one of them is
# refused rather than silently downgraded - downgrading would run a large
# change through a single agent while the requester believes a fleet reviewed
# it, which is the worst of both.
agent_supports_fleet() {
    case "$1" in
        claude|claude-goal|claude-fleet) return 0 ;;
        *) return 1 ;;
    esac
}

# Echoes the agent type that actually runs a request, given the configured
# agent and the resolved strategy.
#
# A project configured for claude-goal runs the fleet when a request asks for
# it, and claude-fleet runs a solo goal loop when a request asks for that. The
# configured type sets the default; the request moves it.
#
# Usage: agent_type_for_strategy <configured_agent> <strategy>
agent_type_for_strategy() {
    local agent="$1" strategy="${2:-solo}"

    agent_supports_fleet "$agent" || { printf '%s' "$agent"; return 0; }

    case "$strategy" in
        fleet) printf 'claude-fleet' ;;
        *)     printf 'claude-goal' ;;
    esac
}

# Echoes the strategy an agent type runs by default when a request names none.
agent_default_strategy() {
    case "$1" in
        claude-fleet) echo "fleet" ;;
        *) echo "solo" ;;
    esac
}

# Echoes the host-side watcher adapter path for an agent.
#
# One adapter serves every goal agent and every forge: it writes the task
# prompt and the completion condition, and neither varies by agent or by
# forge - the loop itself belongs to the CLI.
# Usage: agent_watcher_adapter_for <agent> [watcher_type]
agent_watcher_adapter_for() {
    local agent="$1"
    local base_dir="${AGENT_FOUNDRY_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    case "$agent" in
        *-goal|claude-fleet)
            # claude-fleet shares it: the adapter's whole job is resolving the
            # mode and writing the prompt, and neither changes with the
            # strategy. Only the launcher it hands over to differs.
            echo "$base_dir/templates/goal/watcher_agent_goal.sh"
            ;;
        *)
            echo ""
            ;;
    esac
}

agent_watcher_adapter() {
    agent_watcher_adapter_for "$1"
}

# Echoes the iteration cap for an autonomous run; 0 means uncapped.
#
# The goal agents decide when they are done from the goal condition, so
# nothing caps them by count. Kept as a function because the start scripts
# read it, and a per-agent cap may return.
agent_max_iterations() {
    echo "0"
}

# Echoes the default timeout in minutes for autonomous agent runs.
#
# A fleet round is a delegation, a build, a gate run and a critique before
# anything lands, repeated until the gate passes. Two hours is a solo agent's
# budget and would kill most fleet runs mid-round.
agent_default_timeout_minutes() {
    case "$1" in
        claude-fleet) echo "480" ;;
        *) echo "120" ;;
    esac
}

# Echoes the default log file path inside the sandbox for an autonomous agent.
agent_log_file() {
    local agent="$1"
    local workspace="${2:-${HOME:-/home/agent}}"
    echo "$workspace/logs/${agent}.log"
}

# Echoes the default task prompt file path inside the sandbox for an
# autonomous agent. The watcher writes the rendered task here before starting.
agent_task_prompt_file() {
    local agent="$1"
    local workspace="${2:-${HOME:-/home/agent}}"
    local dotfolder
    dotfolder="$(agent_dotfolder "$agent")"
    if [[ -n "$dotfolder" ]]; then
        echo "$workspace/$dotfolder/task_prompt.md"
    else
        echo "$workspace/.foundry/task_prompt.md"
    fi
}
