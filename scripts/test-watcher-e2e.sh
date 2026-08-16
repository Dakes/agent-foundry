#!/usr/bin/env bash
#
# End-to-end test for the Forgejo watcher.
#
# Not part of the normal gates: it builds an image, creates a sandbox and
# posts real HTTP, which takes minutes and needs sbx. Run it after touching
# anything under templates/forgejo/ or lib/watcher.sh.
#
#   ./scripts/test-watcher-e2e.sh
#
# It exercises what unit tests cannot: that the receiver binds the configured
# port, that the signature is actually enforced, and that a triggering comment
# reaches the watcher. Each of those has been broken in a way every other
# check passed through - the receiver listening on its own default port, and
# handle-request running without the secret and accepting anything.
#
# No real forge is involved: the instance URL is unreachable on purpose, so
# the run stops where it would call the API. Everything before that is real.

# pass and fail both return 0, so the `cond && pass || fail` idiom used
# throughout cannot run fail after a successful pass.
# shellcheck disable=SC2015

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

BOX="foundry-e2e-watcher"
IMAGE="foundry-agent:e2e"
WORK="$(mktemp -d)"

# A free port, not a fixed one: the obvious choice (9174) is a port real
# projects publish, so running this on a host with a project up failed on a
# collision that had nothing to do with the watcher.
pick_free_port() {
    local port attempt
    for attempt in $(seq 1 50); do
        port=$(( 20000 + RANDOM % 30000 ))
        if command -v ss >/dev/null 2>&1; then
            ss -lnt 2>/dev/null | grep -q ":${port} " && continue
        fi
        # Nothing may hold it on the host, and no sandbox may publish it.
        sbx ls 2>/dev/null | grep -q ":${port}->" && continue
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 2>/dev/null; continue; }
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

if [[ -n "${FOUNDRY_E2E_PORT:-}" ]]; then
    PORT="$FOUNDRY_E2E_PORT"
elif ! PORT="$(pick_free_port)"; then
    echo "could not find a free port; set FOUNDRY_E2E_PORT" >&2
    exit 1
fi

PASS=0
FAIL=0

pass() { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); return 0; }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); return 0; }

cleanup() {
    sbx rm --force "$BOX" >/dev/null 2>&1 || true
    sbx template rm "$IMAGE" >/dev/null 2>&1 || true
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v sbx >/dev/null || { echo "sbx is required" >&2; exit 1; }

echo "== building $IMAGE (minutes)"
# Keep the output: a swallowed build error leaves "build failed" and nothing
# to act on, which is exactly the shape of bug this script exists to catch.
if ! docker build -f docker/foundry-agent.Dockerfile \
    --build-arg "AGENT_UID=$(id -u)" --build-arg "AGENT_GID=$(id -g)" \
    -t "$IMAGE" . > "$WORK/build.log" 2>&1; then
    echo "build failed:" >&2
    tail -20 "$WORK/build.log" >&2
    exit 1
fi

docker save "$IMAGE" -o "$WORK/img.tar" >/dev/null 2>&1
if ! sbx template load "$WORK/img.tar" > "$WORK/load.log" 2>&1; then
    echo "template load failed:" >&2
    tail -10 "$WORK/load.log" >&2
    exit 1
fi

export FOUNDRY_BASE="$ROOT_DIR"
# shellcheck source=../lib/utils.sh
source lib/utils.sh
# shellcheck source=../lib/config.sh
source lib/config.sh
# shellcheck source=../lib/agent-registry.sh
source lib/agent-registry.sh
# shellcheck source=../lib/sandbox.sh
source lib/sandbox.sh
# shellcheck source=../lib/policy.sh
source lib/policy.sh
# shellcheck source=../lib/project.sh
source lib/project.sh
# shellcheck source=../lib/watcher.sh
source lib/watcher.sh

export FOUNDRY_VOLUME_DIR="$WORK/vols"
root="$FOUNDRY_VOLUME_DIR/e2e"
project_scaffold e2e >/dev/null 2>&1
printf 'faketoken\n' > "$root/secrets/forgejo-token.txt"
jq --arg p "$PORT" '.agent="claude-goal" | .watcher={kind:"forgejo",
    instance_url:"https://forge.invalid", receiver_port:($p|tonumber),
    trigger_keyword:"@bot", watched_repos:["acme/widgets"],
    token_file:"secrets/forgejo-token.txt", public_url:"http://localhost"}' \
    "$root/foundry.json" > "$root/t" && mv "$root/t" "$root/foundry.json"

echo "== starting sandbox on port $PORT"
sbx rm --force "$BOX" >/dev/null 2>&1
if ! sandbox_create "$BOX" "$IMAGE" "" "" "$root" "" "0.0.0.0:${PORT}:${PORT}" \
        > "$WORK/create.log" 2>&1; then
    echo "could not create the sandbox:" >&2
    tail -10 "$WORK/create.log" >&2
    exit 1
fi
sandbox_start "$BOX" >/dev/null 2>&1
sandbox_link_home "$BOX" "$root" >/dev/null 2>&1

echo "== watcher"
if watcher_start e2e "$BOX" "$root" >/dev/null 2>&1; then
    pass "watcher starts"
else
    fail "watcher starts"
    tail -5 "$root/.config/forgejo-watcher/watcher.log" 2>/dev/null
    exit 1
fi

cfg="$root/.config/forgejo-watcher"
for f in processed.json retries.json; do
    [[ -f "$cfg/$f" ]] && pass "$f created" || fail "$f created"
done

grep -q ":${PORT} (socat)" "$cfg/receiver.log" 2>/dev/null \
    && pass "receiver binds the configured port" \
    || fail "receiver binds the configured port (see receiver.log)"

sleep 1
secret="$(cat "$cfg/webhook-secret")"
body='{"action":"created","issue":{"number":7,"state":"open","title":"t","body":"b","user":{"login":"u"}},"comment":{"id":42,"body":"@bot review this","user":{"login":"u"}},"repository":{"full_name":"acme/widgets","name":"widgets","clone_url":"https://forge.invalid/acme/widgets.git","default_branch":"main"}}'
sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}')"

post() {
    curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}/webhook" \
        -H 'Content-Type: application/json' -H 'X-Forgejo-Event: issue_comment' \
        -H "X-Hub-Signature-256: sha256=$1" -d "$body"
}

[[ "$(post "$sig")" == "200" ]] && pass "signed webhook accepted" || fail "signed webhook accepted"
[[ "$(post "deadbeef")" == "401" ]] && pass "forged signature rejected" || fail "forged signature rejected"

code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null)"
[[ "$code" == "404" ]] && pass "wrong path rejected" || fail "wrong path rejected (got $code)"

# A body ending in a newline, which is what Go's json.Encoder sends and what
# the forge signs. Reading it through $(...) stripped that byte, so the digest
# never matched and every real delivery was rejected as a forgery - while
# curl's newline-free bodies verified fine.
printf '%s\n' "$body" > "$WORK/body_nl.json"
sig_nl="$(openssl dgst -sha256 -hmac "$secret" < "$WORK/body_nl.json" | awk '{print $NF}')"
code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}/webhook" \
    -H 'Content-Type: application/json' -H 'X-Forgejo-Event: issue_comment' \
    -H "X-Hub-Signature-256: sha256=$sig_nl" --data-binary "@$WORK/body_nl.json")"
[[ "$code" == "200" ]] \
    && pass "newline-terminated body verifies" \
    || fail "newline-terminated body verifies (got $code)"

# Forgejo's own header carries a bare hex digest, with no sha256= prefix.
code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}/webhook" \
    -H 'Content-Type: application/json' -H 'X-Forgejo-Event: issue_comment' \
    -H "X-Forgejo-Signature: $sig_nl" --data-binary "@$WORK/body_nl.json")"
[[ "$code" == "200" ]] \
    && pass "X-Forgejo-Signature accepted" \
    || fail "X-Forgejo-Signature accepted (got $code)"

sleep 4
grep -q "Found trigger in issue_comment" "$cfg/watcher.log" 2>/dev/null \
    && pass "watcher picks the trigger up" \
    || fail "watcher picks the trigger up"

# Every signed post above carries the same comment id, so the ledger must hold
# exactly one entry: the forged one never got in, and the repeats were seen as
# already processed.
if jq -e '.processed | keys | length == 1' "$cfg/processed.json" >/dev/null 2>&1; then
    pass "only signed events reached the ledger"
else
    fail "only signed events reached the ledger ($(jq -c '.processed|keys' "$cfg/processed.json" 2>/dev/null))"
fi

# sbx stops a sandbox about a minute after the last exec returns, and what
# runs inside does not count as activity. A watcher waiting for webhooks is
# idle by definition, so it used to take the whole sandbox down with it and
# the forge got "connection refused" from a project that looked up. Nothing
# else here notices: every check above passes in the first few seconds.
echo "== surviving the idle window (about 80s)"
sleep 80

if [[ "$(sbx ls 2>/dev/null | awk -v b="$BOX" '$1==b{print $3}')" == "running" ]]; then
    pass "sandbox still running after the idle window"
else
    fail "sandbox stopped while the watcher was idle"
fi

[[ "$(post "$sig")" == "200" ]] \
    && pass "receiver still answers after the idle window" \
    || fail "receiver still answers after the idle window"

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
