#!/usr/bin/env bash
#
# Agent Foundry - fleet lane audit (Stop / SubagentStop)
#
# The end-of-turn half of lane enforcement.
#
# lane-guard.sh denies an out-of-lane write as it happens, which is the better
# experience but relies on a PreToolUse denial being honoured. This one runs at
# the end of the turn and blocks with exit 2, which is a Stop-hook control flow
# rather than a permission decision - so it holds under permission modes where
# the earlier denial may not.
#
# Two layers that catch the same mistake, deliberately. The rule is worth more
# than the elegance.
#

set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleet-runtime.sh
source "${_dir}/fleet-runtime.sh"

payload=$(cat)

# Nothing to audit without a pinned lane: the orchestrator has the whole tree.
[[ -n "${FLEET_LANE_GLOBS:-}" ]] || exit 0
[[ -n "${FLEET_REPO:-}" ]] || exit 0

cd "$FLEET_REPO" 2>/dev/null || exit 0

changed=$(git status --porcelain 2>/dev/null | awk '{ $1=""; sub(/^ +/, ""); print }')
[[ -n "$changed" ]] || exit 0

strays=""
while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    # A rename prints "old -> new"; the new path is the one that matters.
    file="${file##* -> }"

    in_lane=0
    while IFS= read -r glob; do
        [[ -n "$glob" ]] || continue
        # shellcheck disable=SC2053  # the glob on the right is the point
        if [[ "$file" == $glob ]]; then
            in_lane=1
            break
        fi
    done <<< "${FLEET_LANE_GLOBS}"

    [[ "$in_lane" -eq 1 ]] || strays+="  $file"$'\n'
done <<< "$changed"

[[ -n "$strays" ]] || exit 0

fleet_log WARN "stop-audit: out-of-lane changes in lane ${FLEET_LANE_NAME:-unnamed}"

{
    echo "You have modified files outside your lane (${FLEET_LANE_NAME:-unnamed}):"
    echo
    printf '%s' "$strays"
    echo
    echo "Your lane is:"
    printf '%s\n' "${FLEET_LANE_GLOBS}"
    echo
    echo "Another agent may own those files and may be editing them right now."
    echo "Revert each one to its original content, then report the change you"
    echo "needed as a cross-lane dependency. Do not commit or stash anything."
} >&2

exit 2
