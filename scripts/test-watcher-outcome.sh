#!/usr/bin/env bash
#
# Tests for evaluate_agent_outcome, the watcher's read on a finished run.
#
# This function was called on the success path and defined nowhere at all. The
# watcher runs under `set -e`, so every completed run exited it with 127; the
# supervisor restarted it, and the restart discarded whatever had queued up
# while the agent worked. The run itself had succeeded, so no log anywhere
# reported a problem - the only symptom was that a request made while the agent
# was busy disappeared.
#
# What is covered is therefore the contract the watcher branches on: the type
# before the colon decides whether the task is marked done, retried, or
# reported as failed, so getting it wrong is a lost or duplicated task.
#
#   ./scripts/test-watcher-outcome.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PASS=0
FAIL=0

pass() { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); return 0; }
fail() { printf "  \033[0;31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); return 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run evaluate_agent_outcome in a shell with the helpers loaded and the two
# inputs it reads staged: the runner's status file and the agent's log.
#
# status: an exit code, or "none" to leave no file - which is what a killed
# session leaves behind.
outcome() {
    local status="$1" log_text="$2" started="${3:-0}"

    rm -rf "$WORK/state" "$WORK/logs"
    mkdir -p "$WORK/state" "$WORK/logs"

    if [[ "$status" != "none" ]]; then
        printf '{"exit_code":%s,"finished_at":"2026-08-17T16:00:00Z"}\n' \
            "$status" > "$WORK/state/run-status.json"
    fi
    printf '%s\n' "$log_text" > "$WORK/logs/agent-watcher.log"

    HOME="$WORK" \
    CONFIG_DIR="$WORK/state" \
    RUN_STATUS_FILE="$WORK/state/run-status.json" \
    AGENT_WORKSPACE="$WORK" \
    bash -c '
        source templates/forgejo/forgejo_watcher_common.sh
        evaluate_agent_outcome "$1"
    ' _ "$started" 2>/dev/null
}

type_of() { printf '%s' "${1%%:*}"; }

check_type() {
    local label="$1" got="$2" want="$3"
    local got_type
    got_type="$(type_of "$got")"
    if [[ "$got_type" == "$want" ]]; then
        pass "$label -> $want"
    else
        fail "$label -> got '${got_type}', wanted '${want}' (full: ${got})"
    fi
}

echo "== the four outcomes the watcher branches on =="

check_type "clean exit" \
    "$(outcome 0 'all done')" success

check_type "non-zero exit" \
    "$(outcome 3 'something broke')" failure

check_type "no status file at all" \
    "$(outcome none 'killed mid-run')" unknown

check_type "usage limit in the log" \
    "$(outcome 1 'Claude AI usage limit reached; resets 3pm UTC')" rate_limited

echo "== a rate limit is found even when nothing recorded a status =="
# The session can be killed while the CLI sits on a limit it already reported.
# Calling that "unknown" loses the retry, which is the whole point of the type.
check_type "limit, no status file" \
    "$(outcome none 'hit your limit - try again later')" rate_limited

echo "== every outcome carries a detail after the colon =="
# The watcher puts this in a comment on the forge when a run fails, so an empty
# detail is a comment that says nothing.
for spec in "0:done" "4:boom" "none:gone"; do
    got="$(outcome "${spec%%:*}" "${spec#*:}")"
    if [[ "$got" == *:* && -n "${got#*:}" ]]; then
        pass "detail present for '${spec%%:*}'"
    else
        fail "no detail for '${spec%%:*}': ${got}"
    fi
done

echo "== the failing run's last log line reaches the detail =="
got="$(outcome 9 'ERROR: the branch is protected')"
if [[ "$got" == *"the branch is protected"* ]]; then
    pass "detail quotes the log"
else
    fail "detail lost the log line: ${got}"
fi

echo "== the detail stays one line, whatever the log holds =="
# It is interpolated into a JSON status record and a forge comment.
got="$(outcome 9 "$(printf 'line one\nline two')")"
if [[ "$(printf '%s' "$got" | wc -l)" -le 1 ]]; then
    pass "detail is a single line"
else
    fail "detail spans lines: ${got}"
fi

echo "== a run with no log at all still classifies =="
rm -rf "$WORK/logs"; mkdir -p "$WORK/state" "$WORK/logs"
check_type "empty log, exit 2" "$(outcome 2 '')" failure

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
