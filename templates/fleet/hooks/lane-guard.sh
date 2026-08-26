#!/usr/bin/env bash
#
# Agent Foundry - fleet path guard (PreToolUse)
#
# Answers one question: may this call write this path?
#
# Two ways the answer is no:
#
#   1. Protected paths. The gate's ledger is written by the gate and by nothing
#      else. A score an agent can edit is not a score.
#   2. Lane ownership. A builder owns a set of globs; everything else in the
#      tree belongs to someone who may be editing it right now.
#
# Lane enforcement here is best-effort by design. This hook only knows the lane
# when the launcher pinned one, and a PreToolUse denial is one layer of three -
# stop-audit.sh re-checks the same rule at the end of the turn, where a Stop
# hook's exit 2 does not depend on the permission mode, and the orchestrator
# checks `git status` before it lands anything. Treat a denial here as the
# cheap early catch, not as the thing standing between the fleet and a
# cross-lane edit.
#

set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleet-runtime.sh
source "${_dir}/fleet-runtime.sh"

payload=$(cat)

tool=$(fleet_field "$payload" '.tool_name')
path=$(fleet_field "$payload" '.tool_input.file_path')

# Only the writing tools carry a file_path worth checking.
case "$tool" in
    Write | Edit | NotebookEdit) ;;
    *) fleet_allow ;;
esac

[[ -n "$path" ]] || fleet_allow

# --------------------------------------------------------------------------
# 1. Protected paths
# --------------------------------------------------------------------------
if [[ -n "${FLEET_PROTECTED_PATHS:-}" ]]; then
    while IFS= read -r protected; do
        [[ -n "$protected" ]] || continue
        # shellcheck disable=SC2053  # the glob on the right is the point
        if [[ "$path" == $protected ]]; then
            fleet_log WARN "lane-guard: denied write to protected path $path"
            fleet_deny "PROTECTED PATH: $path is written by the gate, not by an agent. A score an agent can edit is not a score. If the value in it is wrong, say so in your report - do not change it."
        fi
    done <<< "${FLEET_PROTECTED_PATHS}"
fi

# --------------------------------------------------------------------------
# 2. Lane ownership
# --------------------------------------------------------------------------
[[ -n "${FLEET_LANE_GLOBS:-}" ]] || fleet_allow

rel="$path"
if [[ -n "${FLEET_REPO:-}" && "$path" == "${FLEET_REPO}/"* ]]; then
    rel="${path#"${FLEET_REPO}/"}"
fi

while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    # shellcheck disable=SC2053
    if [[ "$rel" == $glob || "$path" == $glob ]]; then
        fleet_allow
    fi
done <<< "${FLEET_LANE_GLOBS}"

fleet_log WARN "lane-guard: denied out-of-lane write to $rel (lane: ${FLEET_LANE_NAME:-unnamed})"
fleet_deny "OUT OF LANE: $rel is not in your lane (${FLEET_LANE_NAME:-unnamed}).

Your lane is:
${FLEET_LANE_GLOBS}

Another agent may be editing that file right now. Do not edit it, and do not work around this by writing it some other way. Report it to the orchestrator as a cross-lane dependency and continue with what you own."
