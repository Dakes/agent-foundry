#!/usr/bin/env bash
#
# Agent Foundry - fleet gate, as a Stop / SubagentStop hook
#
# This is the mechanism the whole fleet is built around: an agent cannot end
# its turn while the gate is failing, and the thing that refuses to let it stop
# is also the thing that tells it what to fix.
#
# Exit code 2 on a Stop hook prevents the agent from stopping and continues the
# conversation, and the hook's stderr is shown to the agent. So stderr is not a
# log here - it is the work order, and it is the only channel that reaches the
# agent at the moment it matters.
#
# Deliberately blunt about what it refuses to do: it never edits anything, it
# never decides the work is "close enough", and it has no opinion about how
# hard the agent tried.
#

set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleet-runtime.sh
source "${_dir}/fleet-runtime.sh"

payload=$(cat)
FLEET_GATE_MAX_ITERATIONS="${FLEET_GATE_MAX_ITERATIONS:-12}"

# No gate configured: this hook has nothing to enforce and must not pretend it
# does. The launcher refuses to start a fleet without a gate, so reaching here
# means someone wired the hook up by hand.
if [[ -z "${FLEET_GATE_COMMAND:-}" ]]; then
    fleet_log WARN "stop-gate: no gate command configured; allowing stop"
    exit 0
fi

# Nothing changed, nothing to verify.
#
# A read-only round - a review, an answer - ends with a clean tree and no
# commits. Gating that would hold the agent against whatever state the branch
# was already in, which is not this run's work and not this run's problem. It
# is also the difference between a fleet that can review a red branch and one
# that cannot.
if [[ "${FLEET_GATE_ON_CLEAN_TREE:-skip}" == "skip" && -n "${FLEET_REPO:-}" ]]; then
    if [[ -z "$(git -C "$FLEET_REPO" status --porcelain 2>/dev/null)" ]] &&
       [[ -z "$(git -C "$FLEET_REPO" log --oneline "@{upstream}..HEAD" 2>/dev/null)" ]]; then
        fleet_log INFO "stop-gate: clean tree and nothing unpushed; nothing to gate"
        exit 0
    fi
fi

gate_output=$("${_dir}/gate-run.sh" 2>&1)
gate_rc=$?

if [[ "$gate_rc" -eq 0 ]]; then
    fleet_counter_reset
    fleet_log INFO "stop-gate: PASS"
    exit 0
fi

# The gate could not run. That is not a failing gate, it is an unmeasurable
# tree, and continuing would produce a round whose claims cannot be checked.
# Let the agent stop so it can report the breakage, and make sure it knows.
if [[ "$gate_rc" -eq 2 ]]; then
    fleet_log ERROR "stop-gate: gate could not run"
    jq -n --arg ctx "The gate could not be run, so nothing about this work has been verified:

$gate_output

Report this as a blocker. Do not claim the work is complete - it has not been measured." '{
        hookSpecificOutput: {
            hookEventName: "Stop",
            additionalContext: $ctx
        }
    }'
    exit 0
fi

iterations=$(fleet_counter_bump)

# Budget exhausted. Stop blocking and ask for an honest report instead. A loop
# that cannot converge is not made to converge by running it again, and the
# agent stopping with "here is what will not pass and why" is worth more than
# another identical round.
if [[ "$iterations" -gt "$FLEET_GATE_MAX_ITERATIONS" ]]; then
    # The counter is deliberately left above the threshold. Resetting it here
    # would hold the agent again on its very next stop - the one where it is
    # writing the report this branch just asked for - and it could never
    # actually finish. Only a passing gate, or the start of the next run,
    # clears it.
    fleet_log WARN "stop-gate: budget exhausted after $iterations iterations; allowing stop"
    jq -n --arg ctx "The gate is still failing after ${FLEET_GATE_MAX_ITERATIONS} attempts, so the iteration budget for this run is spent and you are no longer being held.

Latest gate output:

$gate_output

Do not report success. Report what is still failing, what you tried, and what you believe is blocking it." '{
        hookSpecificOutput: {
            hookEventName: "Stop",
            additionalContext: $ctx
        }
    }'
    exit 0
fi

fleet_log INFO "stop-gate: FAIL, holding (iteration $iterations/$FLEET_GATE_MAX_ITERATIONS)"

{
    echo "You are not done: the gate is failing."
    echo
    echo "$gate_output"
    echo
    echo "Attempt ${iterations} of ${FLEET_GATE_MAX_ITERATIONS}."
    echo "Fix the top item, re-run the gate, and repeat. Do not report success"
    echo "while this is failing, and do not weaken the check to pass it."
} >&2

exit 2
