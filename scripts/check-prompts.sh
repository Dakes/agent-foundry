#!/usr/bin/env bash
#
# Guards the prompt architecture documented in docs/PROMPT-ARCHITECTURE.md.
#
# Every rule here corresponds to a contradiction that previously shipped and
# cost the agent reasoning tokens on every run. Re-introducing one is easy and
# invisible in review, so it is checked mechanically.
#
# Usage: ./scripts/check-prompts.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

FAIL=0

RULE_FAILED=0

fail() {
    printf 'FAIL: %s\n' "$1"
    FAIL=$((FAIL + 1))
    RULE_FAILED=1
}

# Prints the rule's pass line only if nothing failed since the last rule.
ok() {
    [[ "$RULE_FAILED" -eq 0 ]] && printf 'ok:   %s\n' "$1"
    RULE_FAILED=0
}

ADAPTERS=(templates/ralph/*.sh templates/kimi/*_watcher_agent_*.sh)

# ---------------------------------------------------------------------------
# 1. Identity strings must come from the prompt library, not be hardcoded.
# ---------------------------------------------------------------------------
hits=$(grep -rn 'Task Completed' templates/ projects/ 2>/dev/null \
    | grep -v '^templates/prompt-lib.sh:' \
    | grep -v 'AGENT_IDENTITY' || true)
if [[ -n "$hits" ]]; then
    fail "hardcoded completion header outside prompt-lib.sh:"
    printf '%s\n' "$hits" | sed 's/^/      /'
else
    ok "no hardcoded completion headers"
fi

# ---------------------------------------------------------------------------
# 2. Adapters must use the shared builder rather than hand-rolling prompts.
# ---------------------------------------------------------------------------
for f in "${ADAPTERS[@]}"; do
    [[ -f "$f" ]] || continue
    if ! grep -q 'foundry_build_task_prompt' "$f"; then
        fail "$f does not use foundry_build_task_prompt"
    fi
    if ! grep -q 'FOUNDRY_PROMPT_LIB' "$f"; then
        fail "$f does not source the shared prompt library"
    fi
done
ok "all adapters use the shared prompt builder"

# ---------------------------------------------------------------------------
# 3. Adapters must not carry their own task instructions. Objectives live in
#    one place; a second copy is how review-vs-implement drift returns.
# ---------------------------------------------------------------------------
for f in "${ADAPTERS[@]}"; do
    [[ -f "$f" ]] || continue
    hits=$(grep -nE '^[^|]*-( \[ \])? (Navigate to /root|Implement the solution|Create a pull request|Review all PR|Make the necessary|Push fixes to|Address all relevant)' "$f" || true)
    if [[ -n "$hits" ]]; then
        fail "$f contains inline task instructions:"
        printf '%s\n' "$hits" | sed 's/^/      /'
    fi
done
ok "no inline task instructions in adapters"

# ---------------------------------------------------------------------------
# 4. Durable project files must not restate mission, identity, or workflow.
#    They answer "how", never "whether" or "what".
# ---------------------------------------------------------------------------
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    hits=$(grep -niE 'identify yourself|start your comment with|create a pull request|open a pull request|ask clarifying|interactive session' "$f" || true)
    if [[ -n "$hits" ]]; then
        fail "$f (durable file) restates workflow or identity:"
        printf '%s\n' "$hits" | sed 's/^/      /'
    fi
done < <(find projects templates -name 'AGENT.md' -o -name 'AGENT.md.template' 2>/dev/null)
ok "durable agent files carry no workflow or identity rules"

# ---------------------------------------------------------------------------
# 5. Durable prompt files must not hardcode a repository path. The watcher
#    supplies the repo per task; a baked-in path contradicts it.
# ---------------------------------------------------------------------------
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    hits=$(grep -nE '/root/repos/[a-zA-Z0-9_-]+' "$f" || true)
    if [[ -n "$hits" ]]; then
        fail "$f hardcodes a repository path:"
        printf '%s\n' "$hits" | sed 's/^/      /'
    fi
done < <(find projects -name 'PROMPT.md' 2>/dev/null)
ok "no hardcoded repository paths in durable prompts"

# ---------------------------------------------------------------------------
# 6. Every task mode must state at least one explicit prohibition. The
#    observed failure mode is a plausible adjacent action, which only an
#    explicit "Do not" suppresses.
# ---------------------------------------------------------------------------
for mode in review implement fix answer default; do
    block=$(awk -v m="        $mode)" '
        $0 ~ "^" m {found=1}
        found {print}
        found && /^            ;;/ {exit}
    ' templates/prompt-lib.sh)
    if [[ "$mode" == "default" ]]; then
        block=$(awk '/default \| \*\)/{found=1} found{print} found && /^            ;;/{exit}' templates/prompt-lib.sh)
    fi
    if [[ -z "$block" ]] || ! grep -q '_foundry_never' <<< "$block"; then
        fail "mode '$mode' has no explicit prohibition in prompt-lib.sh"
    fi
done
ok "every task mode states explicit prohibitions"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "All prompt checks passed."
else
    printf '%d prompt check(s) failed.\n' "$FAIL"
fi
[[ "$FAIL" -eq 0 ]]
