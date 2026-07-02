#!/usr/bin/env bash
#
# Agent Foundry - Shared VM-side session ledger helpers.
# Sourced by autonomous agent start scripts and watcher adapters inside VMs.

set -euo pipefail

AGENT_SESSION_LEDGER="${AGENT_SESSION_LEDGER:-/root/.config/foundry/sessions.json}"

# Ensure the session ledger file exists.
ensure_agent_session_ledger() {
    local ledger_dir
    ledger_dir="$(dirname "$AGENT_SESSION_LEDGER")"
    if [[ ! -d "$ledger_dir" ]]; then
        mkdir -p "$ledger_dir"
    fi
    if [[ ! -f "$AGENT_SESSION_LEDGER" ]]; then
        jq -n '{version: "1.0", sessions: {}}' > "$AGENT_SESSION_LEDGER"
    fi
}

# Echo the session ID for a thread key, or empty if none.
get_agent_session_id() {
    local thread_key="$1"
    if [[ ! -f "$AGENT_SESSION_LEDGER" ]]; then
        echo ""
        return 0
    fi
    jq -r --arg key "$thread_key" '.sessions[$key].session_id // empty' "$AGENT_SESSION_LEDGER" 2>/dev/null
}

# Echo the full session JSON for a thread key, or empty if none.
get_agent_session() {
    local thread_key="$1"
    if [[ ! -f "$AGENT_SESSION_LEDGER" ]]; then
        echo ""
        return 0
    fi
    jq -r --arg key "$thread_key" '.sessions[$key] // empty' "$AGENT_SESSION_LEDGER" 2>/dev/null
}

# Update or create a session entry.
update_agent_session() {
    local thread_key="$1"
    local agent_type="$2"
    local session_id="$3"
    local status="$4"
    local task_prompt_file="$5"
    local log_file="$6"

    ensure_agent_session_ledger

    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local tmp_file
    tmp_file="$(mktemp)"

    jq --arg key "$thread_key" \
       --arg agent_type "$agent_type" \
       --arg session_id "$session_id" \
       --arg status "$status" \
       --arg now "$now" \
       --arg task_prompt_file "$task_prompt_file" \
       --arg log_file "$log_file" \
       '.sessions[$key] = {
            agent_type: $agent_type,
            session_id: $session_id,
            status: $status,
            started_at: (.sessions[$key].started_at // $now),
            last_active_at: $now,
            task_prompt_file: $task_prompt_file,
            log_file: $log_file
        }' \
       "$AGENT_SESSION_LEDGER" > "$tmp_file" && mv "$tmp_file" "$AGENT_SESSION_LEDGER"
}

# Try to extract a session ID from a Kimi-like resume hint in a log file.
# Falls back to the most recently modified file in known Kimi session dirs.
capture_agent_session_id() {
    local log_file="$1"

    local captured
    captured="$(grep -oE 'kimi -r[[:space:]]+[A-Za-z0-9_-]+' "$log_file" 2>/dev/null | tail -n 1 | awk '{print $NF}')"
    if [[ -n "$captured" ]]; then
        echo "$captured"
        return 0
    fi

    local session_dir
    for session_dir in "$HOME/.kimi-code/sessions" "$HOME/.config/kimi-code/sessions" "$HOME/.local/share/kimi-code/sessions"; do
        if [[ -d "$session_dir" ]]; then
            local latest
            latest="$(find "$session_dir" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
            if [[ -n "$latest" ]]; then
                basename "$latest"
                return 0
            fi
        fi
    done

    echo ""
}
