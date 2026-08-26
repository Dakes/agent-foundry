#!/usr/bin/env bash
#
# Agent Foundry - fleet gate runner
#
# Runs the project's gate command and turns whatever it produced into a verdict
# plus a work order. Every other part of the fleet asks this script rather than
# running the gate itself, so that "what the gate said" has exactly one
# meaning.
#
# Exit codes:
#   0  the gate passed
#   1  the gate failed; the work order is on stdout
#   2  the gate could not be run at all (missing, timed out, crashed)
#
# The distinction between 1 and 2 matters. A failing gate is information and
# the run continues. A gate that cannot run makes every later claim
# unfalsifiable, and the run must stop rather than proceed unmeasured.
#
# Two output shapes are supported, because a real project has one of two kinds
# of gate:
#
#   json   the command prints {"pass": bool, "worst": [{...}], ...}. Rich work
#          orders with coordinates, which is what makes a failure actionable
#          without judgement.
#   exit   the command is an ordinary check - `npm test && npm run lint`. The
#          exit status is the verdict and the tail of its output is the work
#          order. Coarser, but it is what most repositories already have.
#
# "auto" tries json and falls back to exit, which is what a project gets before
# anyone has written a gate that speaks json.
#

set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleet-runtime.sh
source "${_dir}/fleet-runtime.sh"

FLEET_GATE_COMMAND="${FLEET_GATE_COMMAND:-}"
FLEET_GATE_FORMAT="${FLEET_GATE_FORMAT:-auto}"
FLEET_GATE_TIMEOUT="${FLEET_GATE_TIMEOUT:-900}"
FLEET_GATE_WORK_ORDER_LINES="${FLEET_GATE_WORK_ORDER_LINES:-40}"

if [[ -z "$FLEET_GATE_COMMAND" ]]; then
    echo "GATE ERROR: no gate command is configured for this project." >&2
    echo "Set .fleet.gate.command in foundry.json, then re-run." >&2
    exit 2
fi

cd "${FLEET_REPO:-$FLEET_ROOT}" 2>/dev/null || {
    echo "GATE ERROR: cannot enter ${FLEET_REPO:-$FLEET_ROOT}" >&2
    exit 2
}

out_file=$(mktemp)
err_file=$(mktemp)
trap 'rm -f "$out_file" "$err_file"' EXIT

timeout "${FLEET_GATE_TIMEOUT}" bash -c "$FLEET_GATE_COMMAND" \
    > "$out_file" 2> "$err_file"
rc=$?

if [[ "$rc" -eq 124 ]]; then
    echo "GATE ERROR: the gate command exceeded ${FLEET_GATE_TIMEOUT}s and was killed." >&2
    echo "  command: $FLEET_GATE_COMMAND" >&2
    tail -n 20 "$err_file" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# json shape
# --------------------------------------------------------------------------
_try_json() {
    jq -e 'has("pass")' < "$out_file" >/dev/null 2>&1
}

_render_json() {
    local passed
    passed=$(jq -r '.pass' < "$out_file")

    if [[ "$passed" == "true" ]]; then
        jq -r '"GATE PASS" + (if has("score") then " (score \(.score))" else "" end)' \
            < "$out_file"
        return 0
    fi

    {
        jq -r '"GATE FAIL" + (if has("score") then " (score \(.score))" else "" end)' \
            < "$out_file"
        echo
        echo "Worst items, in order. These are your work orders:"
        echo
        jq -r '
            (.worst // [])[]
            | "  - " + (.id // .name // "item") + ": " + (.detail // .message // "")
              + (if .actual  != null then "\n      actual:   \(.actual)"   else "" end)
              + (if .required != null then "\n      required: \(.required)" else "" end)
              + (if .at       != null then "\n      at:       \(.at)"       else "" end)
        ' < "$out_file"
    }
    return 1
}

# --------------------------------------------------------------------------
# exit shape
# --------------------------------------------------------------------------
_render_exit() {
    if [[ "$rc" -eq 0 ]]; then
        echo "GATE PASS ($FLEET_GATE_COMMAND exited 0)"
        return 0
    fi

    {
        echo "GATE FAIL ($FLEET_GATE_COMMAND exited $rc)"
        echo
        echo "Last ${FLEET_GATE_WORK_ORDER_LINES} lines of its output. This is your work order:"
        echo
        cat "$out_file" "$err_file" 2>/dev/null \
            | tail -n "$FLEET_GATE_WORK_ORDER_LINES" \
            | sed 's/^/  /'
    }
    return 1
}

case "$FLEET_GATE_FORMAT" in
    json)
        if ! _try_json; then
            echo "GATE ERROR: format is 'json' but the command printed no JSON object with a 'pass' field." >&2
            tail -n 20 "$out_file" "$err_file" >&2
            exit 2
        fi
        _render_json
        exit $?
        ;;
    exit)
        _render_exit
        exit $?
        ;;
    auto | *)
        if _try_json; then
            _render_json
        else
            _render_exit
        fi
        exit $?
        ;;
esac
