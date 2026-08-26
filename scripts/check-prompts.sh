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

ADAPTERS=(templates/goal/watcher_agent_goal.sh)

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
    hits=$(grep -nE '/root/(repos|\.claude|\.codex|\.gemini)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
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

    # Forgejo is the only forge with a watcher; the loop that used to cover
    # GitHub as well went with it.
    forge=forgejo
    {
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

        # Existence is not enough: the watcher calls prepare_agent_workspace
        # and then start_agent_loop. An adapter defining only the first
        # prepares a workspace that nothing ever runs in, and the failure is a
        # "command not found" at the moment a forge event arrives.
        for fn in prepare_agent_workspace start_agent_loop; do
            grep -q "^${fn}()" "$adapter" || \
                fail "adapter $(basename "$adapter") does not define ${fn}()"
        done

        # The watcher also gates on an agent-type allowlist before it ever
        # resolves an adapter. An agent missing from it is rejected at startup
        # with "Unsupported watcher agent type", which no adapter can fix.
        for wf in "templates/${forge}-watcher/${forge}_watcher.sh" \
                  "templates/${forge}/${forge}_watcher.sh"; do
            [[ -f "$wf" ]] || continue
            if grep -q 'Unsupported watcher agent type' "$wf" && \
               ! grep -qE "^[[:space:]]*[a-z|-]*\\b${agent}\\b[a-z|-]*\\)" "$wf"; then
                fail "agent '$agent' is not in the $forge watcher's allowlist"
            fi
        done

        # And it has to be in the image, or the watcher finds nothing.
        if ! grep -q "$base" docker/foundry-agent.Dockerfile 2>/dev/null; then
            case "$base" in
                *_watcher_agent_*) ;;   # per-agent adapters ship another way
                *) fail "agent '$agent': $base is not copied into the image" ;;
            esac
        fi
    }
done
ok "every autonomous agent has a reachable template and adapter"

# ---------------------------------------------------------------------------
# 10. Nothing the bot posts back to a thread may contain the trigger keyword.
#
#     A reply lands on the thread that triggered it, so an occurrence of the
#     keyword - even inside a code fence, even as an example - makes the forge
#     deliver an event that triggers another reply. In production this reached
#     hundreds of comments in seconds before it was noticed. The examples in
#     the usage reply use a <mention> placeholder for exactly this reason.
# ---------------------------------------------------------------------------
kw_hits=$(TRIGGER_KEYWORD="@loopcanary" bash -c '
    source templates/prompt-lib.sh 2>/dev/null
    foundry_help_comment 2>/dev/null' | grep -c "@loopcanary" || true)

if [[ "$kw_hits" -eq 0 ]]; then
    ok "the usage reply does not contain the trigger keyword"
else
    fail "the usage reply contains the trigger keyword ${kw_hits} time(s) - it will trigger itself"
fi

# ---------------------------------------------------------------------------
# 11. Every helper the watcher calls must be defined somewhere it can reach.
#
#     The watcher runs under `set -e`, so calling a function nobody defines
#     exits it with 127 mid-event. `evaluate_agent_outcome` was called on the
#     success path and defined nowhere at all: every completed run killed the
#     watcher, the supervisor restarted it, and the restart discarded whatever
#     had been queued in the meantime. Nothing failed visibly - the run had
#     already finished - so the only symptom was that a request made while the
#     agent was working vanished without a trace.
#
#     Bash cannot catch this: an undefined function is indistinguishable from
#     an external command until it runs. So it is checked here instead.
# ---------------------------------------------------------------------------
_defined_helpers() {
    grep -hoE '^[a-z_][a-z0-9_]*\(\)' \
        templates/forgejo/forgejo_watcher.sh \
        templates/forgejo/forgejo_watcher_common.sh \
        templates/prompt-lib.sh \
        templates/fleet/fleet-lib.sh \
        lib/agent-registry.sh \
        "${ADAPTERS[@]}" 2>/dev/null \
        | sed 's/()//' | sort -u
}

# Identifiers in command position that look like this project's helpers:
# snake_case with at least one underscore. Comments, declarations and case
# patterns are stripped first - they hold names that are never called.
_called_helpers() {
    sed -e 's/#.*//' \
        -e '/^[[:space:]]*\(local\|declare\|export\|readonly\)[[:space:]]/d' \
        -e '/^[[:space:]]*[a-z_|*"$ ]*)[[:space:]]*$/d' \
        "$1" \
        | grep -oE '(^[[:space:]]*|\$\(|\bif[[:space:]]+|![[:space:]]+|&&[[:space:]]+|\|\|[[:space:]]+|\bthen[[:space:]]+)[a-z][a-z0-9]*(_[a-z0-9]+)+([[:space:]]|$)' \
        | grep -oE '[a-z][a-z0-9]*(_[a-z0-9]+)+' | sort -u
}

# Helper-shaped names that are real commands, not functions of ours.
_EXTERNAL='^(command_not_found_handle|systemd_.*)$'

_defined_helpers > /tmp/foundry-defined.$$
for f in templates/forgejo/forgejo_watcher.sh "${ADAPTERS[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r fn; do
        [[ -n "$fn" ]] || continue
        [[ "$fn" =~ $_EXTERNAL ]] && continue
        command -v "$fn" >/dev/null 2>&1 && continue
        fail "$(basename "$f") calls ${fn}(), which nothing defines - set -e will exit 127 here"
    done < <(comm -23 <(_called_helpers "$f") /tmp/foundry-defined.$$)
done
rm -f /tmp/foundry-defined.$$
ok "every helper the watcher calls is defined"

# ---------------------------------------------------------------------------
# 12. The fleet strategy must state explicit prohibitions, for the same reason
#     every task mode must: the failure is a plausible adjacent action, and
#     only an explicit "Do not" suppresses it. An orchestrator with no stated
#     prohibitions lands unverified work and calls it done.
# ---------------------------------------------------------------------------
fleet_block=$(awk '/^foundry_fleet_block\(\) \{/{found=1} found{print} found && /^\}/{exit}' \
    templates/prompt-lib.sh)
if [[ -z "$fleet_block" ]]; then
    fail "foundry_fleet_block not found in prompt-lib.sh"
elif ! grep -q '_foundry_never' <<< "$fleet_block"; then
    fail "the fleet block states no explicit prohibitions"
fi
ok "the fleet block states explicit prohibitions"

# ---------------------------------------------------------------------------
# 13. The fleet must be reachable end to end: a launcher, the library the
#     launcher and the adapter both source, the hooks the launcher wires up,
#     and the landing script the guard points agents at. Any one of these
#     missing is an outage that only shows up when a forge event arrives.
# ---------------------------------------------------------------------------
for f in templates/fleet/start-fleet.sh.template \
         templates/fleet/fleet-lib.sh \
         templates/fleet/bin/fleet-land \
         templates/fleet/defaults/fleet.json \
         templates/fleet/defaults/settings.json \
         templates/fleet/hooks/fleet-runtime.sh \
         templates/fleet/hooks/gate-run.sh \
         templates/fleet/hooks/stop-gate.sh \
         templates/fleet/hooks/stop-audit.sh \
         templates/fleet/hooks/lane-guard.sh \
         templates/fleet/hooks/commit-guard.sh; do
    [[ -f "$f" ]] || fail "fleet file missing: $f"
done

# Every role the defaults configure needs a brief whose frontmatter declares
# that exact name: Claude Code resolves subagents by the name in the file, not
# by the filename, so a rename in one place and not the other is a role that
# silently does not exist.
while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    brief="templates/fleet/defaults/agents/${role}.md"
    if [[ ! -f "$brief" ]]; then
        fail "fleet role '$role' has no brief at $brief"
        continue
    fi
    grep -q "^name: ${role}$" "$brief" || \
        fail "$brief does not declare 'name: $role' in its frontmatter"
done < <(jq -r '(.roles // {}) | keys[]' templates/fleet/defaults/fleet.json 2>/dev/null)

# The image has to carry all of it, or the launcher finds nothing.
grep -q 'templates/fleet/' docker/foundry-agent.Dockerfile || \
    fail "the fleet is not copied into the agent image"

ok "the fleet is reachable end to end"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "All prompt checks passed."
else
    printf '%d prompt check(s) failed.\n' "$FAIL"
fi
[[ "$FAIL" -eq 0 ]]
