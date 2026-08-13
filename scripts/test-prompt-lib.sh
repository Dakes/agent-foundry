#!/usr/bin/env bash
#
# Tests for templates/prompt-lib.sh.
#
# Mode resolution decides whether the agent writes code or only reads it, so it
# is the one piece of prompt logic that must not regress silently.
#
# Usage: ./scripts/test-prompt-lib.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../templates/prompt-lib.sh
source "$ROOT_DIR/templates/prompt-lib.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

_ctx() {
    local kind="$1" trigger="$2"
    local f="$TMPDIR_TEST/ctx.json"
    jq -n --arg kind "$kind" --arg trigger "$trigger" \
        '{kind: $kind, number: 42, title: "Test", repo: "acme/widgets",
          repo_name: "widgets", branch: "feat/x",
          html_url: "https://example.com/42",
          trigger_body: (if $trigger == "" then null else $trigger end)}' > "$f"
    printf '%s' "$f"
}

check_mode() {
    local kind="$1" trigger="$2" expected="$3"
    local actual
    actual=$(foundry_task_mode "$(_ctx "$kind" "$trigger")")
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: [%s] %-52s expected=%-10s got=%s\n' \
            "$kind" "\"$trigger\"" "$expected" "$actual"
    fi
}

check_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s: missing %q\n' "$label" "$needle"
    fi
}

check_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s: unexpectedly contains %q\n' "$label" "$needle"
    fi
}

echo "== explicit directives =="
check_mode pr    "/review"                              review
check_mode pr    "/implement the caching layer"         implement
check_mode issue "mode: fix"                            fix
check_mode pr    "@foundry-bot review please"           review
check_mode issue "Some context. /answer"                answer

echo "== leading verb, with real-world politeness =="
check_mode pr    "please review this MR"                review
check_mode pr    "review this"                          review
check_mode pr    "Hey bot, can you please review this?" review
check_mode pr    "could you take a look at this"        review
check_mode issue "implement a retry helper"             implement
check_mode issue "Please implement the parser"          implement
check_mode issue "add a --verbose flag"                 implement
check_mode pr    "fix the failing test"                 fix
check_mode pr    "address the review comments"          fix
check_mode issue "why does the uploader time out?"      answer
check_mode issue "explain how retries work"             answer

echo "== generic default when intent is unclear =="
check_mode pr    ""                                     default
check_mode issue ""                                     default
check_mode pr    "thoughts?"                            default
check_mode issue "this is still happening in prod"      default
check_mode pipeline_failure ""                          fix

echo "== review mode must forbid the observed failure mode =="
review_prompt=$(AGENT_IDENTITY=Kimi foundry_build_task_prompt "$(_ctx pr "please review this MR")")
check_contains "review" "$review_prompt" "Mode: **review**"
check_contains "review" "$review_prompt" "Do not open a pull request."
check_contains "review" "$review_prompt" "Do not modify, commit, or push any code."
check_contains "review" "$review_prompt" "## 🤖 Kimi - Task Completed"
check_not_contains "review" "$review_prompt" "Create a new branch"

echo "== contract resolves the repo-AGENTS.md conflict =="
check_contains "contract" "$review_prompt" "Never try to start an"
check_contains "contract" "$review_prompt" "are authoritative for **how**"
check_contains "contract" "$review_prompt" "this contract and the"

echo "== the triggering request outranks background =="
check_contains "order" "$review_prompt" "## Triggering Request"
req_pos=$(awk '/## Triggering Request/{print NR; exit}' <<< "$review_prompt")
bg_pos=$(awk '/## Background/{print NR; exit}' <<< "$review_prompt")
if [[ -n "$req_pos" && -n "$bg_pos" && "$req_pos" -lt "$bg_pos" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: Triggering Request must appear before Background"
fi

echo "== kind labels are not mangled =="
check_contains "label" "$review_prompt" "# Pull request #42:"

echo "== \"Fixes #N\" only on issue contexts =="
impl_issue=$(foundry_build_task_prompt "$(_ctx issue "implement a retry helper")")
impl_pr=$(foundry_build_task_prompt "$(_ctx pr "implement the suggested change")")
check_contains "implement/issue" "$impl_issue" 'Fixes #42'
check_not_contains "implement/pr" "$impl_pr" 'Fixes #42'

echo "== identity resolution =="
fallback=$(AGENT_IDENTITY="" AGENT_DISPLAY_NAME="" AGENT_TYPE="" foundry_completion_header)
check_contains "identity/none" "$fallback" "Agent - Task Completed"

# With no AGENT_IDENTITY, the registry must still supply the right short name
# rather than the verbose display name. Watcher configs written before
# AGENT_IDENTITY existed rely on this.
# shellcheck source=../lib/agent-registry.sh
source "$ROOT_DIR/lib/agent-registry.sh"
derived=$(AGENT_IDENTITY="" AGENT_TYPE="kimi-ralph" \
    AGENT_DISPLAY_NAME="Kimi Code CLI (Ralph mode)" foundry_completion_header)
check_contains "identity/derived" "$derived" "🤖 Kimi - Task Completed"
check_not_contains "identity/derived" "$derived" "Ralph mode"

explicit=$(AGENT_IDENTITY="Ralph" AGENT_TYPE="kimi-ralph" foundry_completion_header)
check_contains "identity/explicit" "$explicit" "🤖 Ralph - Task Completed"

echo "== checklist style is honoured, negatives stay unchecked =="
checklist=$(FOUNDRY_OBJECTIVE_STYLE=checklist foundry_build_task_prompt "$(_ctx issue "implement a retry helper")")
check_contains "checklist" "$checklist" "- [ ] Work in /root/repos/widgets."
check_contains "checklist" "$checklist" "- Do not push to an existing pull request branch"
check_not_contains "checklist" "$checklist" "- [ ] Do not"

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
