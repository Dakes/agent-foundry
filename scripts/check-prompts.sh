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

ADAPTERS=(templates/ralph/*.sh templates/kimi/*_watcher_agent_*.sh templates/goal/watcher_agent_goal.sh)

# ---------------------------------------------------------------------------
# 1. Identity strings must come from the prompt library, not be hardcoded.
# ---------------------------------------------------------------------------
# Both headers count. Checking only "Task Completed" let a second copy of the
# identity chain live in the error path, where it skipped the registry fallback
# and printed a different name than the completion header on the same run.
#
# A guarded fallback, reached only when the library was not sourced, is exempt
# when the line above it is marked "identity-fallback".
hits=$(find templates projects -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null \
    | grep -v '^templates/prompt-lib.sh$' \
    | while IFS= read -r f; do
        awk -v file="$f" '
            # No comment exemption here: the header itself starts with "##",
            # so skipping lines that begin with "#" would skip every hit.
            /Task Completed|Task Update \(Error\)/ &&
            prev !~ /identity-fallback/ {
                printf "%s:%d:%s\n", file, NR, $0
            }
            { prev = $0 }
        ' "$f"
    done)
if [[ -n "$hits" ]]; then
    fail "hardcoded identity header outside prompt-lib.sh:"
    printf '%s\n' "$hits" | sed 's/^/      /'
else
    ok "no hardcoded identity headers"
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

# ---------------------------------------------------------------------------
# 7. Untrusted text must be fenced. Everything the tracker supplies is written
#    by whoever can comment on the repository; spliced in raw, a comment can
#    forge its own "## Execution Contract" and claim authority the prompt is
#    built to deny it.
# ---------------------------------------------------------------------------
# foundry_build_pipeline_prompt splices jobs_md, which comes from workflow
# files - narrower than a comment, but a job named "## Execution Contract"
# forges a heading just the same.
for fn in foundry_triggering_request foundry_background_block foundry_build_pipeline_prompt; do
    block=$(awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f {found=1} found {print} found && /^\}/ {exit}' \
        templates/prompt-lib.sh)
    if [[ -z "$block" ]]; then
        fail "$fn not found in prompt-lib.sh"
        continue
    fi
    # Any tracker field printed directly, rather than passed through the
    # quoting helper, is an unfenced splice.
    raw=$(grep -nE "printf '[^']*%s[^']*' \"\\\$(trigger|body|conversation|discussion|linked_body)" <<< "$block" || true)
    if [[ -n "$raw" ]]; then
        fail "$fn prints untrusted text without _foundry_quote:"
        printf '%s\n' "$raw" | sed 's/^/      /'
    fi
    if ! grep -q '_foundry_quote' <<< "$block"; then
        fail "$fn does not fence untrusted text with _foundry_quote"
    fi
done
ok "untrusted tracker text is fenced"

# ---------------------------------------------------------------------------
# 8. No hardcoded repository paths anywhere in the prompt layer. The volume
#    root differs per project, so /root/repos - correct under the Firecracker
#    backend - now points at a directory that does not exist.
# ---------------------------------------------------------------------------
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Comments may name the old path when explaining why it went away.
    hits=$(grep -nE '/root/(repos|\.ralph|\.kimi)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [[ -n "$hits" ]]; then
        fail "$f hardcodes a pre-sandbox path:"
        printf '%s\n' "$hits" | sed 's/^/      /'
    fi
done < <(printf '%s\n' templates/prompt-lib.sh templates/AGENT.md.template)
ok "no pre-sandbox paths in the prompt layer"

# ---------------------------------------------------------------------------
# 9. Every autonomous agent must be reachable: a start template and a watcher
#    adapter that exist on disk, and an adapter whose in-container filename the
#    watchers actually resolve.
#
#    The goal agents shipped registered but unreachable - the registry returned
#    no adapter, and the watchers looked for <forge>_watcher_agent_<type>.sh,
#    which did not exist for them. Nothing failed until a real forge event
#    arrived, which is the one moment nobody is watching.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/agent-registry.sh
source lib/agent-registry.sh

for agent in $AGENT_TYPES; do
    agent_is_autonomous "$agent" || continue

    tmpl=$(agent_start_template "$agent")
    if [[ -z "$tmpl" || ! -f "$tmpl" ]]; then
        fail "agent '$agent' has no start template on disk (${tmpl:-<none>})"
    fi

    for forge in gh forgejo; do
        adapter=$(agent_watcher_adapter_for "$agent" "$forge")
        if [[ -z "$adapter" || ! -f "$adapter" ]]; then
            fail "agent '$agent' has no $forge watcher adapter (${adapter:-<none>})"
            continue
        fi

        # The watchers resolve the adapter by filename inside the image. A
        # registry entry pointing at a file the watcher will never look for is
        # the same outage as no entry at all.
        base=$(basename "$adapter")
        if ! grep -q "$base" "templates/${forge}-watcher/${forge}_watcher.sh" \
            2>/dev/null && \
           ! grep -q "$base" "templates/${forge}/${forge}_watcher.sh" 2>/dev/null
        then
            expected="${forge}_watcher_agent_${agent}.sh"
            [[ "$base" == "$expected" ]] || \
                fail "agent '$agent': $forge watcher will not resolve $base"
        fi

        # And it has to be in the image, or the watcher finds nothing.
        if ! grep -q "$base" docker/foundry-agent.Dockerfile 2>/dev/null; then
            case "$base" in
                *_watcher_agent_*) ;;   # per-agent adapters ship another way
                *) fail "agent '$agent': $base is not copied into the image" ;;
            esac
        fi
    done
done
ok "every autonomous agent has a reachable template and adapter"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "All prompt checks passed."
else
    printf '%d prompt check(s) failed.\n' "$FAIL"
fi
[[ "$FAIL" -eq 0 ]]
