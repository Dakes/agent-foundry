#!/usr/bin/env bash
#
# Tests for host port availability and receiver port rolling.
#
# The failure this covers is `foundry init` dying at the publish step because
# another sandbox - or anything else on the host - already holds the configured
# receiver port. sbx is stubbed: what is under test is the decision to roll and
# the value written back to foundry.json, not sbx itself.
#
#   ./scripts/test-ports.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PASS=0
FAIL=0

pass() { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); return 0; }
fail() { printf "  \033[0;31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); return 0; }

equals() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label: expected '${want}', got '${got}'"
    fi
}

TMP="$(mktemp -d)"
cleanup() {
    [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- stub sbx -----------------------------------------------------------------
# Driven by files under $TMP/sbx: one per sandbox holding its port mappings as
# the JSON `sbx ports --json` returns, plus a list of running sandboxes.
mkdir -p "$TMP/bin" "$TMP/sbx"
: > "$TMP/sbx/running"

cat > "$TMP/bin/sbx" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    ls)
        names=()
        for f in "$SBX_STATE"/ports-*; do
            [[ -e "$f" ]] || continue
            n="$(basename "$f")"
            names+=("${n#ports-}")
        done
        printf '%s\n' "${names[@]:-}" | jq -R 'select(length > 0) | {name: .}' | jq -s .
        ;;
    ports)
        box="$2"
        [[ "${3:-}" == "--json" ]] || exit 1
        cat "$SBX_STATE/ports-${box}" 2>/dev/null || echo '[]'
        ;;
    *)
        exit 1
        ;;
esac
STUB
chmod +x "$TMP/bin/sbx"
export PATH="$TMP/bin:$PATH"
export SBX_STATE="$TMP/sbx"
export SBX_BIN="$TMP/bin/sbx"

# A sandbox counts as running only if it is listed; the stub of the predicate
# below reads the same file.
sbx_running_set() { printf '%s\n' "$@" > "$TMP/sbx/running"; }
sbx_ports_set() {
    local box="$1" host="$2" guest="$3"
    jq -n --arg h "$host" --arg g "$guest" \
        '[{host_ip: "0.0.0.0", host_port: ($h | tonumber), sandbox_port: ($g | tonumber)}]' \
        > "$TMP/sbx/ports-${box}"
}

# --- library under test -------------------------------------------------------
export FOUNDRY_VOLUME_DIR="$TMP/volumes"
mkdir -p "$FOUNDRY_VOLUME_DIR"

# shellcheck source=/dev/null
source lib/utils.sh
# shellcheck source=/dev/null
source lib/project.sh
# shellcheck source=/dev/null
source lib/sandbox.sh

# Real sandbox_is_running would shell out to the stub for a field it does not
# model; the file written by sbx_running_set is the whole state it needs.
sandbox_is_running() { grep -qxF "$1" "$TMP/sbx/running"; }

LOG_LEVEL=error

# A real listener, so the detection path is the one that runs in production.
python3 -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(600)
' > "$TMP/port" &
LISTENER_PID=$!
for _ in {1..50}; do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
BOUND_PORT="$(cat "$TMP/port")"
[[ -n "$BOUND_PORT" ]] || { echo "could not start a listener"; exit 1; }

echo "== a bound host port is in use"
if _host_port_bound "$BOUND_PORT"; then pass "bound port detected"; else fail "bound port not detected"; fi

echo "== an unbound host port is free"
FREE_PORT=$(( BOUND_PORT + 7 ))
if _host_port_bound "$FREE_PORT"; then fail "free port reported as bound"; else pass "free port is free"; fi

echo "== the listener table is matched on whole ports"
# The hosts that matter have ss; this sandbox may not, so stub it and exercise
# the parsing that runs there. 19174 must not answer a search for 9174.
cat > "$TMP/bin/ss" <<'SS'
#!/usr/bin/env bash
cat <<'TABLE'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096        0.0.0.0:19174       0.0.0.0:*
LISTEN 0      4096      127.0.0.1:9100        0.0.0.0:*
LISTEN 0      4096           [::]:9101           [::]:*
TABLE
SS
chmod +x "$TMP/bin/ss"
if _host_port_bound 19174; then pass "exact match found"; else fail "exact match missed"; fi
if _host_port_bound 9174; then fail "suffix of 19174 matched 9174"; else pass "suffix is not a match"; fi
if _host_port_bound 9100; then pass "loopback listener found"; else fail "loopback listener missed"; fi
if _host_port_bound 9101; then pass "IPv6 listener found"; else fail "IPv6 listener missed"; fi
if _host_port_bound 9102; then fail "absent port reported bound"; else pass "absent port is free"; fi
rm -f "$TMP/bin/ss"

echo "== the next free port skips what is taken"
equals "rolls past the listener" "$(sandbox_next_free_port "$BOUND_PORT")" "$((BOUND_PORT + 1))"
equals "keeps a free port" "$(sandbox_next_free_port "$FREE_PORT")" "$FREE_PORT"

echo "== another sandbox's mapping counts as taken, even stopped"
sbx_ports_set "foundry-other" "$FREE_PORT" "$FREE_PORT"
sbx_running_set ""
if sandbox_host_port_in_use "$FREE_PORT" "foundry-mine"; then
    pass "stopped sandbox's mapping is a conflict"
else
    fail "stopped sandbox's mapping was ignored"
fi

echo "== our own mapping is not a conflict while we run"
sbx_ports_set "foundry-mine" "$BOUND_PORT" "$BOUND_PORT"
sbx_running_set "foundry-mine"
if sandbox_host_port_in_use "$BOUND_PORT" "foundry-mine"; then
    fail "rolled away from our own published port"
else
    pass "own mapping kept"
fi

echo "== our own mapping is a conflict while we are stopped and it is bound"
sbx_running_set ""
if sandbox_host_port_in_use "$BOUND_PORT" "foundry-mine"; then
    pass "port taken while down is a conflict"
else
    fail "would have started onto a port someone else holds"
fi

# --- the config rewrite -------------------------------------------------------
mkdir -p "$FOUNDRY_VOLUME_DIR/proj"
write_config() {
    jq -n --arg p "$1" --arg u "${2:-}" '
        {name: "proj", agent: "claude-goal",
         watcher: ({kind: "forgejo", receiver_port: ($p | tonumber)}
                   + (if $u == "" then {} else {public_url: $u} end))}' \
        > "$FOUNDRY_VOLUME_DIR/proj/foundry.json"
}
config_port() { jq -r '.watcher.receiver_port' "$FOUNDRY_VOLUME_DIR/proj/foundry.json"; }

echo "== a free receiver port is left alone"
rm -f "$TMP/sbx"/ports-*
write_config "$FREE_PORT"
project_resolve_receiver_port "proj" "foundry-proj" >/dev/null 2>&1
equals "port unchanged" "$(config_port)" "$FREE_PORT"

echo "== a taken receiver port rolls and is written back"
write_config "$BOUND_PORT"
project_resolve_receiver_port "proj" "foundry-proj" >/dev/null 2>&1
equals "port rolled" "$(config_port)" "$((BOUND_PORT + 1))"

echo "== a stale public_url is called out"
write_config "$BOUND_PORT" "http://forge.example:${BOUND_PORT}"
out="$(project_resolve_receiver_port "proj" "foundry-proj" 2>&1)"
if [[ "$out" == *"public_url"* ]]; then pass "warned about public_url"; else fail "no warning: $out"; fi

echo "== up refuses a taken port instead of moving it"
# Rolling is init's alone: the forge posts to this number, so a start that
# bumped it would orphan every registered hook.
write_config "$BOUND_PORT"
if out="$(project_check_receiver_port "proj" "foundry-proj" 2>&1)"; then
    fail "started onto a port someone else holds"
else
    pass "refused the taken port"
fi
equals "port left alone" "$(config_port)" "$BOUND_PORT"
if [[ "$out" == *"receiver_port"* ]]; then pass "says what to change"; else fail "no guidance: $out"; fi

echo "== up accepts a free port"
write_config "$FREE_PORT"
if project_check_receiver_port "proj" "foundry-proj" >/dev/null 2>&1; then
    pass "free port accepted"
else
    fail "free port rejected"
fi

echo "== up accepts the port our own running sandbox publishes"
write_config "$BOUND_PORT"
sbx_ports_set "foundry-proj" "$BOUND_PORT" "$BOUND_PORT"
sbx_running_set "foundry-proj"
if project_check_receiver_port "proj" "foundry-proj" >/dev/null 2>&1; then
    pass "own published port accepted"
else
    fail "rejected the port we publish ourselves"
fi
rm -f "$TMP/sbx"/ports-*
sbx_running_set ""

echo "== no watcher port means nothing to resolve"
jq -n '{name: "proj", agent: "claude"}' > "$FOUNDRY_VOLUME_DIR/proj/foundry.json"
if project_resolve_receiver_port "proj" "foundry-proj" >/dev/null 2>&1; then
    pass "no-op without a receiver port"
else
    fail "failed on a project without a watcher"
fi

echo ""
printf 'Results: \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
