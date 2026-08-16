#!/usr/bin/env bash
#
# Tests for the agent stream formatter.
#
# The formatter sits inside the pipeline that produces the agent log, so its
# failure modes are losing output and crashing the run. Both are covered here
# along with the rendering itself.
#
#   ./scripts/test-log-format.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

FMT="templates/format-agent-stream.py"
PASS=0
FAIL=0

pass() { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); return 0; }
fail() { printf "  \033[0;31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); return 0; }

# render <json line> -> formatted output
render() { printf '%s\n' "$1" | python3 "$FMT" 2>&1; }

contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label: expected '${needle}' in: ${haystack}"
    fi
}

lacks() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$label: '${needle}' should not appear in: ${haystack}"
    else
        pass "$label"
    fi
}

echo "== prose is kept in full"
out="$(render '{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the gates.\nBoth sides own their own."}]},"timestamp":"2026-08-16T12:12:02Z"}')"
contains "first line" "$out" "Reading the gates."
contains "second line" "$out" "Both sides own their own."

echo "== thinking is dropped"
out="$(render '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret deliberation"},{"type":"text","text":"visible"}]}}')"
lacks "thinking" "$out" "secret deliberation"
contains "text survives" "$out" "visible"

echo "== envelope noise is dropped"
out="$(render '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"hi"}],"usage":{"cache_read_input_tokens":54984}},"request_id":"req_011Ce6","uuid":"d1941690"}')"
lacks "request id" "$out" "req_011Ce6"
lacks "cache counters" "$out" "54984"
lacks "uuid" "$out" "d1941690"

echo "== a bash call shows its command, not its envelope"
out="$(render '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"./check.sh --skip-frontend","description":"Run the backend gates"}}]}}')"
contains "tool name" "$out" "bash"
contains "description" "$out" "Run the backend gates"
contains "command" "$out" "./check.sh --skip-frontend"

echo "== an edit shows the path, never the replacement text"
out="$(render '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"backend/services/sessions.py","old_string":"GRACE = 10","new_string":"GRACE = 30"}}]}}')"
contains "path" "$out" "backend/services/sessions.py"
lacks "body" "$out" "GRACE ="

echo "== a write shows the path, never the content"
out="$(render '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"a/b.py","content":"SECRET_PAYLOAD_LINE"}}]}}')"
contains "path" "$out" "a/b.py"
lacks "content" "$out" "SECRET_PAYLOAD_LINE"

echo "== a successful result collapses, a failing one prints"
out="$(render '{"type":"user","message":{"content":[{"type":"tool_result","content":"one\ntwo\nthree\nfour"}]}}')"
contains "line count" "$out" "4 lines"
lacks "body" "$out" "three"

out="$(render '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"E501 line too long\nFAILED (1)"}]}}')"
contains "failure marked" "$out" "failed"
contains "first line" "$out" "E501 line too long"
contains "rest of it" "$out" "FAILED (1)"

echo "== the run's outcome"
out="$(render '{"type":"result","subtype":"success","is_error":false,"duration_ms":192000,"num_turns":41,"total_cost_usd":0.4231}')"
contains "duration" "$out" "3m12s"
contains "turns" "$out" "41 turns"
contains "cost" "$out" "0.42"

out="$(render '{"type":"result","is_error":true,"api_error_status":401,"duration_ms":380,"result":"Invalid API key"}')"
contains "failure glyph" "$out" "✗"
contains "reason" "$out" "Invalid API key"

echo "== an API error is surfaced, not buried"
out="$(render '{"type":"assistant","is_api_error_message":true,"message":{"content":[{"type":"text","text":"Invalid API key · Fix external API key"}]}}')"
contains "error" "$out" "Invalid API key"

echo "== the init banner keeps three fields and drops the inventory"
out="$(render '{"type":"system","subtype":"init","model":"claude-opus-5","claude_code_version":"2.1.233","session_id":"25c4faae-1245","skills":["deep-research"],"messaging_socket_path":"/run/user/1000/cc-socks/3507.sock"}')"
contains "model" "$out" "claude-opus-5"
lacks "skills" "$out" "deep-research"
lacks "sockets" "$out" "cc-socks"

echo "== nothing is ever swallowed"
out="$(render 'a plain line from another agent')"
contains "passthrough" "$out" "a plain line from another agent"

out="$(render '{"type":"assistant","message":{"content":[{"type":"text",')"
contains "truncated json passes through" "$out" '{"type":"assistant"'

out="$(printf '{"type":"result","duration_ms":"not-a-number"}\n' | python3 "$FMT" 2>&1)"
if [[ -n "$out" ]]; then
    pass "a malformed field does not silence the line"
else
    fail "a malformed field silenced the line"
fi

echo "== a closed pipe is not an error (head, less, Ctrl-C)"
if printf '{"type":"result","duration_ms":1000}\n' | python3 "$FMT" 2>/dev/null | head -1 >/dev/null 2>&1; then
    pass "exits quietly on SIGPIPE"
else
    fail "exits quietly on SIGPIPE"
fi

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
