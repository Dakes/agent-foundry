#!/usr/bin/env bash
#
# Agent Foundry - fleet configuration, inside the sandbox
#
# Sourced by the goal adapter and by the fleet launcher. Reads the project's
# .fleet block out of foundry.json, materialises the role briefs and hooks the
# first time they are needed, and renders the parts the prompt library asks for
# as pre-formatted data.
#
# The split matters: this file knows the project's configuration, and knows
# nothing about what a builder or a critic should be told. That text lives in
# the briefs under .claude/, where a project can edit it. Nothing here writes
# instructions for an agent.
#
# Requires: jq. Plain bash 4+ otherwise, because it runs inside the image.
#

FLEET_DEFAULTS_DIR="${FLEET_DEFAULTS_DIR:-/opt/foundry/fleet/defaults}"
FLEET_HOOKS_SRC_DIR="${FLEET_HOOKS_SRC_DIR:-/opt/foundry/fleet/hooks}"
FLEET_BIN_SRC_DIR="${FLEET_BIN_SRC_DIR:-/opt/foundry/fleet/bin}"

# ---------------------------------------------------------------------------
# Config access
# ---------------------------------------------------------------------------

fleet_config_file() {
    printf '%s/foundry.json' "${1:-${AGENT_WORKSPACE:-$HOME}}"
}

# Read one field out of the project's .fleet block.
# Usage: fleet_get <root> <jq-path-after-.fleet> [default]
fleet_get() {
    local root="$1" path="$2" fallback="${3:-}"
    local cfg value
    cfg="$(fleet_config_file "$root")"

    [[ -f "$cfg" ]] || { printf '%s' "$fallback"; return 0; }

    value=$(jq -r ".fleet${path} // empty" "$cfg" 2>/dev/null) || value=""
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

# Is the fleet switched on for this project?
fleet_enabled() {
    [[ "$(fleet_get "$1" '.enabled' 'false')" == "true" ]]
}

# The project's default strategy, for a request that names none.
fleet_default_strategy() {
    fleet_get "$1" '.strategy' 'solo'
}

fleet_gate_command() {
    fleet_get "$1" '.gate.command' ''
}

# ---------------------------------------------------------------------------
# Materialisation
# ---------------------------------------------------------------------------

# Copy the shipped defaults into the project, without ever clobbering an edit.
#
# Config-driven, per the project's own doctrine: a fleet run materialises what
# it needs rather than failing because someone did not run a setup command
# first. `foundry fleet init` on the host does exactly the same thing, so the
# two paths cannot drift.
#
# Usage: fleet_materialize <root> [force]
fleet_materialize() {
    local root="$1" force="${2:-false}"
    local claude_dir="${root}/.claude"
    local hooks_dir="${claude_dir}/hooks/fleet"
    local bin_dir="${root}/bin"
    local src dest rel

    mkdir -p "${claude_dir}/agents" "${claude_dir}/skills" "$hooks_dir" "$bin_dir" \
             "${root}/.foundry" "${root}/logs" || return 1

    # Role briefs and skills: the project's to edit, so an existing file wins.
    if [[ -d "$FLEET_DEFAULTS_DIR" ]]; then
        while IFS= read -r src; do
            rel="${src#"$FLEET_DEFAULTS_DIR"/}"
            case "$rel" in
                agents/*|skills/*) ;;
                *) continue ;;
            esac
            dest="${claude_dir}/${rel}"
            if [[ -e "$dest" && "$force" != "true" ]]; then
                continue
            fi
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest" || return 1
        done < <(find "$FLEET_DEFAULTS_DIR" -type f -name '*.md' 2>/dev/null)
    fi

    # Hooks and the landing script are machinery, not configuration: they are
    # refreshed from the image every run so that an upgraded image cannot leave
    # a project enforcing last version's rules.
    if [[ -d "$FLEET_HOOKS_SRC_DIR" ]]; then
        cp "$FLEET_HOOKS_SRC_DIR"/*.sh "$hooks_dir/" 2>/dev/null || return 1
        chmod +x "$hooks_dir"/*.sh 2>/dev/null || true
    fi
    if [[ -d "$FLEET_BIN_SRC_DIR" ]]; then
        cp "$FLEET_BIN_SRC_DIR"/fleet-land "$bin_dir/" 2>/dev/null || return 1
        chmod +x "$bin_dir/fleet-land" 2>/dev/null || true
    fi

    fleet_write_settings "$root" || return 1
}

# Merge the fleet's hook wiring into the project's Claude settings.
#
# A merge rather than a write: the volume root is the agent's home, and the
# settings file there may already carry a project's own preferences. Foundry
# owns the fleet hooks and nothing else in that file.
fleet_write_settings() {
    local root="$1"
    local settings="${root}/.claude/settings.json"
    local template="${FLEET_DEFAULTS_DIR}/settings.json"
    local hooks_dir="${root}/.claude/hooks/fleet"
    local rendered timeout merged

    [[ -f "$template" ]] || return 0

    # The gate is the slowest thing any hook does, and a hook that outlives its
    # timeout is killed - which would read to the agent as a passing gate.
    timeout=$(fleet_get "$root" '.gate.timeout_seconds' '900')
    timeout=$(( timeout + 60 ))

    rendered=$(sed -e "s#__FLEET_HOOKS__#${hooks_dir}#g" \
                   -e "s#__GATE_HOOK_TIMEOUT__#${timeout}#g" "$template")

    if [[ -f "$settings" ]]; then
        merged=$(jq -s '.[0] * .[1]' "$settings" <(printf '%s' "$rendered") 2>/dev/null) || return 1
    else
        merged="$rendered"
    fi

    printf '%s\n' "$merged" > "$settings" || return 1
}

# ---------------------------------------------------------------------------
# Runtime file
# ---------------------------------------------------------------------------

# Write the settings every hook reads.
#
# A file, not exported variables: hooks are spawned by the agent CLI, and
# anything in that chain may reset the environment. A hook that silently saw no
# gate would report PASS on an unmeasured tree.
#
# Usage: fleet_write_runtime <root> <repo_path>
fleet_write_runtime() {
    local root="$1" repo="${2:-}"
    local out="${root}/.foundry/fleet-runtime.env"
    local ledger protected

    mkdir -p "$(dirname "$out")" || return 1

    ledger=$(fleet_get "$root" '.gate.ledger' '')
    protected=$(fleet_get "$root" '.protected_paths | join("\n")' '')
    if [[ -n "$ledger" ]]; then
        protected="${protected:+${protected}$'\n'}${ledger}"
    fi

    {
        printf '# Written by the fleet launcher. Regenerated on every run.\n'
        printf 'FLEET_ROOT=%q\n'                 "$root"
        printf 'FLEET_REPO=%q\n'                 "$repo"
        printf 'FLEET_STATE_DIR=%q\n'            "${root}/.foundry/fleet-state"
        printf 'FLEET_HOOK_LOG=%q\n'             "${root}/logs/fleet-hooks.log"
        printf 'FLEET_GATE_COMMAND=%q\n'         "$(fleet_gate_command "$root")"
        printf 'FLEET_GATE_FORMAT=%q\n'          "$(fleet_get "$root" '.gate.format' 'auto')"
        printf 'FLEET_GATE_TIMEOUT=%q\n'         "$(fleet_get "$root" '.gate.timeout_seconds' '900')"
        printf 'FLEET_GATE_MAX_ITERATIONS=%q\n'  "$(fleet_get "$root" '.gate.max_iterations' '12')"
        printf 'FLEET_GATE_WORK_ORDER_LINES=%q\n' "$(fleet_get "$root" '.gate.work_order_lines' '40')"
        printf 'FLEET_GATE_ON_CLEAN_TREE=%q\n'   "$(fleet_get "$root" '.gate.on_clean_tree' 'skip')"
        printf 'FLEET_PROTECTED_PATHS=%q\n'      "$protected"
    } > "$out" || return 1

    # Each round starts with a fresh iteration budget; a stale counter from a
    # previous run would cut this one short for no reason.
    rm -f "${root}/.foundry/fleet-state/gate-iterations" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rendering for the prompt
# ---------------------------------------------------------------------------

# The configured roles, as a markdown list the prompt library splices in.
#
# Data, not instruction: name, how many, and the one-line summary the project
# wrote. What each role actually does is in its brief.
fleet_render_roles() {
    local root="$1" cfg
    cfg="$(fleet_config_file "$root")"

    [[ -f "$cfg" ]] || return 0

    jq -r '
        (.fleet.roles // {}) | to_entries[]
        | "- `" + .key + "`"
          + (if (.value.count // 1) > 1 then " (up to \(.value.count) at once)" else "" end)
          + ": " + (.value.summary // "no summary configured")
    ' "$cfg" 2>/dev/null
}

# The configured lanes, as a markdown list.
fleet_render_lanes() {
    local root="$1" cfg
    cfg="$(fleet_config_file "$root")"

    [[ -f "$cfg" ]] || return 0

    # The value is piped into join explicitly. Written as a bare `join(", ")`
    # inside the `then`, jq applies it to the entry object rather than to
    # .value, and the filter dies with "string and array cannot be added" -
    # which, under the adapter's set -e, takes the whole run with it.
    jq -r '
        (.fleet.lanes // {}) | to_entries[]
        | "- **" + .key + "**: "
          + (if (.value | type) == "array"
             then (.value | join(", "))
             else (.value | tostring)
             end)
    ' "$cfg" 2>/dev/null
}

# Total concurrent subagents the project allows.
fleet_max_concurrent() {
    local root="$1" cfg total
    cfg="$(fleet_config_file "$root")"

    [[ -f "$cfg" ]] || { printf '4'; return 0; }

    total=$(jq -r '[(.fleet.roles // {}) | to_entries[] | (.value.count // 1)] | add // 4' \
        "$cfg" 2>/dev/null) || total=4
    [[ "$total" =~ ^[0-9]+$ ]] || total=4
    printf '%s' "$total"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Decide whether this project can run a fleet at all.
#
# Prints the reason for refusal on stdout and returns 1. The caller posts that
# reason and starts nothing: a fleet that runs without a gate is a fleet whose
# claims cannot be checked, which is worse than a solo agent, not better,
# because it looks so much more thorough.
#
# Usage: reason=$(fleet_preflight <root>) || refuse "$reason"
# shellcheck disable=SC2016  # backticks throughout are Markdown code spans
fleet_preflight() {
    local root="$1"
    local cfg gate

    cfg="$(fleet_config_file "$root")"
    if [[ ! -f "$cfg" ]]; then
        printf 'This project has no foundry.json, so there is no fleet configuration to run.'
        return 1
    fi

    if ! fleet_enabled "$root"; then
        printf 'The fleet is disabled for this project. Set `.fleet.enabled` to true in `foundry.json` to turn it on.'
        return 1
    fi

    gate="$(fleet_gate_command "$root")"
    if [[ -z "$gate" ]]; then
        printf 'The fleet needs a gate command and this project has none.

A fleet is an orchestrator, several builders and a critic, all arranged around one question: has the work passed a check that no agent can talk its way through. Without that check the whole arrangement is expensive theatre — several agents agreeing with each other, and a report nobody can verify.

Set `.fleet.gate.command` in `foundry.json` to whatever proves this project is healthy — its test suite, its linters, a coverage threshold, a benchmark — and try again. Run `foundry fleet check <project>` to have it validated.

You can run this same request without the fleet by dropping the `fleet` keyword.'
        return 1
    fi

    return 0
}
