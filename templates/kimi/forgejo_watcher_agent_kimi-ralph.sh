#!/usr/bin/env bash
#
# Forgejo watcher adapter for Kimi Code CLI running in Ralph mode.
# This file is sourced by forgejo_watcher.sh and must implement the standard
# adapter interface:
#   prepare_agent_workspace <context_file>
#   start_agent_loop()
#   evaluate_agent_outcome [run_start_epoch]
#

set -euo pipefail

KIMI_WORKSPACE="${KIMI_WORKSPACE:-/root}"
KIMI_DOTFOLDER="$KIMI_WORKSPACE/.kimi"
KIMI_TASK_PROMPT_FILE="$KIMI_DOTFOLDER/task_prompt.md"
KIMI_LOG_FILE="$KIMI_WORKSPACE/logs/kimi-ralph.log"
KIMI_SESSION_LEDGER="${KIMI_SESSION_LEDGER:-/root/.config/foundry/sessions.json}"

# Shared prompt builder: single source of truth for the execution contract,
# task modes, and the identity string. See docs/PROMPT-ARCHITECTURE.md.
FOUNDRY_PROMPT_LIB="${FOUNDRY_PROMPT_LIB:-/opt/foundry/prompt-lib.sh}"
if [[ -f "$FOUNDRY_PROMPT_LIB" ]]; then
    # shellcheck source=../prompt-lib.sh
    source "$FOUNDRY_PROMPT_LIB"
fi

# Internal: run a command inside the Kimi workspace.
_kimi_in_workspace() {
    (
        cd "$KIMI_WORKSPACE" || exit 1
        "$@"
    )
}

# Load shared session ledger helpers if available.
if [[ -f /opt/foundry/agent-session.sh ]]; then
    # shellcheck source=/opt/foundry/agent-session.sh
    source /opt/foundry/agent-session.sh
else
    ensure_agent_session_ledger() {
        local ledger_dir
        ledger_dir="$(dirname "$KIMI_SESSION_LEDGER")"
        [[ -d "$ledger_dir" ]] || mkdir -p "$ledger_dir"
        [[ -f "$KIMI_SESSION_LEDGER" ]] || jq -n '{version: "1.0", sessions: {}}' > "$KIMI_SESSION_LEDGER"
    }

    get_agent_session_id() {
        local thread_key="$1"
        [[ -f "$KIMI_SESSION_LEDGER" ]] || { echo ""; return 0; }
        jq -r --arg key "$thread_key" '.sessions[$key].session_id // empty' "$KIMI_SESSION_LEDGER" 2>/dev/null
    }

    update_agent_session() {
        local thread_key="$1" agent_type="$2" session_id="$3" status="$4" task_prompt_file="$5" log_file="$6"
        ensure_agent_session_ledger
        local now tmp_file
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        tmp_file="$(mktemp)"
        jq --arg key "$thread_key" --arg agent_type "$agent_type" \
           --arg session_id "$session_id" --arg status "$status" --arg now "$now" \
           --arg task_prompt_file "$task_prompt_file" --arg log_file "$log_file" \
           '.sessions[$key] = {agent_type: $agent_type, session_id: $session_id, status: $status, started_at: (.sessions[$key].started_at // $now), last_active_at: $now, task_prompt_file: $task_prompt_file, log_file: $log_file}' \
           "$KIMI_SESSION_LEDGER" > "$tmp_file" && mv "$tmp_file" "$KIMI_SESSION_LEDGER"
    }

    capture_agent_session_id() {
        local log_file="$1" captured session_dir latest
        captured="$(grep -oE 'kimi -r[[:space:]]+[A-Za-z0-9_-]+' "$log_file" 2>/dev/null | tail -n 1 | awk '{print $NF}')"
        [[ -n "$captured" ]] && { echo "$captured"; return 0; }
        for session_dir in "$HOME/.kimi-code/sessions" "$HOME/.config/kimi-code/sessions" "$HOME/.local/share/kimi-code/sessions"; do
            if [[ -d "$session_dir" ]]; then
                latest="$(find "$session_dir" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
                [[ -n "$latest" ]] && { basename "$latest"; return 0; }
            fi
        done
        echo ""
    }
fi

# Compute a thread key from the watcher context file.
# The argument is optional and defaults to $CONTEXT_FILE.
# shellcheck disable=SC2120
_kimi_thread_key() {
    local context_file="${1:-$CONTEXT_FILE}"
    if [[ -z "$context_file" || ! -f "$context_file" ]]; then
        echo ""
        return 0
    fi
    local repo number
    repo=$(jq -r '.repo // empty' "$context_file" 2>/dev/null)
    number=$(jq -r '.number // empty' "$context_file" 2>/dev/null)
    if [[ -z "$repo" || -z "$number" ]]; then
        echo ""
        return 0
    fi
    echo "${repo}#${number}"
}

prepare_agent_workspace() {
    local context_file="$1"
    local kind mode

    if ! declare -F foundry_build_task_prompt >/dev/null; then
        log_error "Prompt library missing at $FOUNDRY_PROMPT_LIB"
        log_error "Re-run the watcher init command for this VM"
        return 1
    fi

    kind=$(jq -r '.kind' "$context_file")

    mkdir -p "$KIMI_DOTFOLDER" "$KIMI_WORKSPACE/logs"

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
                > "$KIMI_TASK_PROMPT_FILE" || return 1
            ;;
        pipeline_failure)
            log_info "Resolved task mode: fix (kind: pipeline_failure)"
            foundry_build_pipeline_prompt "$context_file" \
                > "$KIMI_TASK_PROMPT_FILE" || return 1
            ;;
        *)
            log_error "Unsupported context kind for kimi-ralph: $kind"
            return 1
            ;;
    esac

    log_info "Prepared kimi-ralph watcher workspace"
}

start_agent_loop() {
    log_info "Starting kimi-ralph (Kimi Code CLI)..."

    if [[ ! -f "$KIMI_TASK_PROMPT_FILE" ]]; then
        log_error "Task prompt missing: $KIMI_TASK_PROMPT_FILE"
        return 1
    fi

    cd "$KIMI_WORKSPACE" || {
        log_error "Failed to change directory to $KIMI_WORKSPACE"
        return 1
    }

    local thread_key session_id
    thread_key="$(_kimi_thread_key)"
    session_id=""
    if [[ -n "$thread_key" ]]; then
        session_id="$(get_agent_session_id "$thread_key")"
        if [[ -n "$session_id" ]]; then
            log_info "Resuming existing Kimi session for $thread_key: $session_id"
        else
            log_info "No existing session for $thread_key; starting fresh"
        fi
    fi

    local runner_script
    runner_script="/tmp/kimi-runner-$(date +%s).sh"
    cat > "$runner_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/root/.kimi-code/bin:/root/.local/bin:/usr/local/bin:\$PATH"

AGENT_TYPE="kimi-ralph"
AGENT_THREAD_KEY="$thread_key"
AGENT_SESSION_ID="$session_id"
AGENT_LOG_FILE="$KIMI_LOG_FILE"
AGENT_TASK_PROMPT_FILE="$KIMI_TASK_PROMPT_FILE"
AGENT_MAX_ITERATIONS=""

# shellcheck source=/opt/foundry/agent-session.sh
source /opt/foundry/agent-session.sh 2>/dev/null || true

mkdir -p "\$(dirname "\$AGENT_LOG_FILE")"

kimi_args=()
if [[ -n "\$AGENT_SESSION_ID" ]]; then
    echo "[INFO] Resuming Kimi session \$AGENT_SESSION_ID for thread \$AGENT_THREAD_KEY" | tee -a "\$AGENT_LOG_FILE"
    kimi_args+=(-S "\$AGENT_SESSION_ID")
fi
kimi_args+=(-p "\$(cat "\$AGENT_TASK_PROMPT_FILE")")

update_agent_session "\$AGENT_THREAD_KEY" "\$AGENT_TYPE" "\$AGENT_SESSION_ID" "running" "\$AGENT_TASK_PROMPT_FILE" "\$AGENT_LOG_FILE"

set +e
kimi "\${kimi_args[@]}" 2>&1 | tee -a "\$AGENT_LOG_FILE"
exit_code=\${PIPESTATUS[0]}
set -e

if [[ -z "\$AGENT_SESSION_ID" && -n "\$AGENT_THREAD_KEY" ]]; then
    AGENT_SESSION_ID="\$(capture_agent_session_id "\$AGENT_LOG_FILE")"
fi

if [[ \$exit_code -eq 0 ]]; then
    update_agent_session "\$AGENT_THREAD_KEY" "\$AGENT_TYPE" "\$AGENT_SESSION_ID" "completed" "\$AGENT_TASK_PROMPT_FILE" "\$AGENT_LOG_FILE"
else
    update_agent_session "\$AGENT_THREAD_KEY" "\$AGENT_TYPE" "\$AGENT_SESSION_ID" "failed" "\$AGENT_TASK_PROMPT_FILE" "\$AGENT_LOG_FILE"
fi

exit \$exit_code
EOF
    chmod +x "$runner_script"

    start_tmux_runner "$runner_script"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started kimi-ralph in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start kimi-ralph tmux session"
    return 1
}

evaluate_agent_outcome() {
    local run_start_epoch="${1:-}"
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:backend_limit"
        return 0
    fi

    echo "failure:exit_code_${exit_code:-missing}"
}
