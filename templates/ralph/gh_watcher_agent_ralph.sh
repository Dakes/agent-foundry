#!/usr/bin/env bash
#
# Adapter for frankbria/ralph-claude-code watcher tasks.
#
# Prompt content is built by the shared library at /opt/foundry/prompt-lib.sh
# so that the execution contract, task modes, and identity string stay
# identical across every agent and forge. See docs/PROMPT-ARCHITECTURE.md.
#

set -euo pipefail

FOUNDRY_PROMPT_LIB="${FOUNDRY_PROMPT_LIB:-/opt/foundry/prompt-lib.sh}"
if [[ -f "$FOUNDRY_PROMPT_LIB" ]]; then
    # shellcheck source=../prompt-lib.sh
    source "$FOUNDRY_PROMPT_LIB"
fi

# ralph-claude-code consumes fix_plan.md as a task checklist.
FOUNDRY_OBJECTIVE_STYLE="checklist"

prepare_ralph_claude_code_workspace() {
    local context_file="$1"
    local kind mode

    if ! declare -F foundry_build_task_prompt >/dev/null; then
        log_error "Prompt library missing at $FOUNDRY_PROMPT_LIB"
        log_error "Re-run: foundry agent gh-watcher init <vm>"
        return 1
    fi

    kind=$(jq -r '.kind' "$context_file")

    mkdir -p "$RALPH_WORKSPACE/.ralph" "$RALPH_WORKSPACE/logs"

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
                > "$RALPH_WORKSPACE/.ralph/fix_plan.md" || return 1
            ;;
        pipeline_failure)
            log_info "Resolved task mode: fix (kind: pipeline_failure)"
            foundry_build_pipeline_prompt "$context_file" \
                > "$RALPH_WORKSPACE/.ralph/fix_plan.md" || return 1
            ;;
        *)
            log_error "Unsupported context kind for ralph-claude-code: $kind"
            return 1
            ;;
    esac

    log_info "Prepared ralph-claude-code watcher workspace"
}

start_ralph_claude_code_loop() {
    log_info "Starting ralph-claude-code with ${RALPH_TIMEOUT}-minute timeout..."

    cd "$RALPH_WORKSPACE" || {
        log_error "Failed to change directory to $RALPH_WORKSPACE"
        return 1
    }

    ralph --reset-circuit >/dev/null 2>&1 || true
    start_tmux_runner "timeout ${RALPH_TIMEOUT}m ralph --monitor --timeout ${RALPH_TIMEOUT}"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started ralph-claude-code in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start ralph-claude-code tmux session"
    return 1
}

evaluate_ralph_claude_code_outcome() {
    local run_start_epoch="${1:-}"
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:claude_usage_limit"
        return 0
    fi

    echo "failure:exit_code_${exit_code:-missing}"
}

# Standard generic interface used by the agent-aware GitHub watcher.
prepare_agent_workspace() { prepare_ralph_claude_code_workspace "$@"; }
start_agent_loop() { start_ralph_claude_code_loop; }
evaluate_agent_outcome() { evaluate_ralph_claude_code_outcome "$@"; }
