#!/usr/bin/env bash
#
# GitHub watcher adapter for mikeyobrien/ralph-orchestrator.
#
# Prompt content is built by the shared library at /opt/foundry/prompt-lib.sh
# so that the execution contract, task modes, and identity string stay
# identical across every agent and forge. See docs/PROMPT-ARCHITECTURE.md.
#

set -euo pipefail

RALPH_WORKSPACE="${RALPH_WORKSPACE:-/root}"
ORCHESTRATOR_WATCHER_PROMPT="${ORCHESTRATOR_WATCHER_PROMPT:-$RALPH_WORKSPACE/.ralph/gh_task_prompt.md}"

FOUNDRY_PROMPT_LIB="${FOUNDRY_PROMPT_LIB:-/opt/foundry/prompt-lib.sh}"
if [[ -f "$FOUNDRY_PROMPT_LIB" ]]; then
    # shellcheck source=../prompt-lib.sh
    source "$FOUNDRY_PROMPT_LIB"
fi

# ralph-orchestrator gates loop completion on this promise (see ralph.yml).
FOUNDRY_COMPLETION_PROMISE="LOOP_COMPLETE"

prepare_ralph_orchestrator_workspace() {
    local context_file="$1"
    local kind mode

    if ! declare -F foundry_build_task_prompt >/dev/null; then
        log_error "Prompt library missing at $FOUNDRY_PROMPT_LIB"
        log_error "Re-run: foundry agent gh-watcher init <vm>"
        return 1
    fi

    kind=$(jq -r '.kind' "$context_file")

    mkdir -p "$(dirname "$ORCHESTRATOR_WATCHER_PROMPT")" "$RALPH_WORKSPACE/logs"

    case "$kind" in
        issue | pr)
            mode=$(foundry_task_mode "$context_file")
            # No mode stated: reply with the syntax and run no agent. The
            # watcher posts FOUNDRY_REPLY_FILE on this exit code.
            if [[ "$mode" == "help" ]]; then
                log_info "No task mode stated; replying with usage"
                foundry_write_help_reply
                return $?
            fi
            log_info "Resolved task mode: $mode (kind: $kind)"
            foundry_build_task_prompt "$context_file" "$mode" \
                > "$ORCHESTRATOR_WATCHER_PROMPT" || return 1
            ;;
        pipeline_failure)
            log_info "Resolved task mode: fix (kind: pipeline_failure)"
            foundry_build_pipeline_prompt "$context_file" \
                > "$ORCHESTRATOR_WATCHER_PROMPT" || return 1
            ;;
        *)
            log_error "Unsupported context kind for ralph-orchestrator: $kind"
            return 1
            ;;
    esac

    log_info "Prepared ralph-orchestrator watcher prompt at $ORCHESTRATOR_WATCHER_PROMPT"
}

start_ralph_orchestrator_loop() {
    log_info "Starting ralph-orchestrator..."

    cd "$RALPH_WORKSPACE" || {
        log_error "Failed to change directory to $RALPH_WORKSPACE"
        return 1
    }

    if [[ ! -f "$RALPH_WORKSPACE/ralph.yml" ]]; then
        log_error "Ralph Orchestrator config missing: $RALPH_WORKSPACE/ralph.yml"
        return 1
    fi

    start_tmux_runner "ralph run -c ralph.yml -P .ralph/gh_task_prompt.md --autonomous"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started ralph-orchestrator in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start ralph-orchestrator tmux session"
    return 1
}

evaluate_ralph_orchestrator_outcome() {
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:backend_limit"
    else
        echo "failure:exit_code_${exit_code:-missing}"
    fi
}

# Standard generic interface used by the agent-aware GitHub watcher.
prepare_agent_workspace() { prepare_ralph_orchestrator_workspace "$@"; }
start_agent_loop() { start_ralph_orchestrator_loop; }
evaluate_agent_outcome() { evaluate_ralph_orchestrator_outcome "$@"; }
