#!/usr/bin/env bash
#
# Agent Foundry - fleet hook runtime
#
# Sourced by every fleet hook. Loads the resolved fleet settings the launcher
# wrote, and supplies the few helpers the hooks share.
#
# The settings are read from a file rather than inherited through the
# environment. Hooks are spawned by the agent CLI, which is spawned by the
# launcher, and anything in that chain can reset the environment - a hook that
# silently sees no gate would report PASS on an unmeasured tree, which is the
# one failure this whole mechanism exists to prevent. A missing file is loud.
#

FLEET_RUNTIME_FILE="${FLEET_RUNTIME_FILE:-${HOME}/.foundry/fleet-runtime.env}"

if [[ -f "$FLEET_RUNTIME_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$FLEET_RUNTIME_FILE"
fi

FLEET_ROOT="${FLEET_ROOT:-$HOME}"
FLEET_STATE_DIR="${FLEET_STATE_DIR:-${FLEET_ROOT}/.foundry/fleet-state}"
FLEET_HOOK_LOG="${FLEET_HOOK_LOG:-${FLEET_ROOT}/logs/fleet-hooks.log}"

fleet_log() {
    mkdir -p "$(dirname "$FLEET_HOOK_LOG")" 2>/dev/null || return 0
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-INFO}" "${2:-}" \
        >> "$FLEET_HOOK_LOG" 2>/dev/null || true
}

# Read a field out of the hook's JSON payload on stdin.
#
# Usage: payload=$(cat); fleet_field "$payload" '.tool_name'
fleet_field() {
    local payload="$1" filter="$2" value
    value=$(printf '%s' "$payload" | jq -r "$filter // empty" 2>/dev/null) || value=""
    printf '%s' "$value"
}

# Deny a tool call. PreToolUse only.
#
# Printed as JSON rather than signalled with exit 2, because the reason has to
# reach the agent as a decision it can act on rather than as an error it may
# read as a broken environment.
fleet_deny() {
    local reason="$1"
    jq -n --arg r "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# Allow a tool call, saying nothing.
fleet_allow() {
    exit 0
}

# Counter for how many times the gate has turned an agent back this run.
#
# The fleet's rule is that the gate defines done, with no iteration cap. That
# is right when a human is watching the spend and wrong in an unattended
# sandbox on a metered plan, where the failure mode is a loop that burns a
# week's quota against a gate that will never pass. The counter is the escape
# hatch: past the budget the gate stops blocking and asks for a report instead.
fleet_counter_path() {
    printf '%s/gate-iterations' "$FLEET_STATE_DIR"
}

fleet_counter_read() {
    local f
    f="$(fleet_counter_path)"
    [[ -f "$f" ]] && head -n 1 "$f" 2>/dev/null | tr -cd '0-9' || printf '0'
}

fleet_counter_bump() {
    local f n
    f="$(fleet_counter_path)"
    n=$(fleet_counter_read)
    n=$(( ${n:-0} + 1 ))
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s\n' "$n" > "$f" 2>/dev/null || true
    printf '%s' "$n"
}

fleet_counter_reset() {
    rm -f "$(fleet_counter_path)" 2>/dev/null || true
}
