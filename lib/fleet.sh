#!/usr/bin/env bash
#
# Agent Foundry - Fleet configuration, host side
#
# Materialises the shipped fleet defaults into a project, validates what the
# project ended up with, and reports it. The in-sandbox half of this lives in
# templates/fleet/fleet-lib.sh and does the same materialisation at run time;
# both exist because a fleet must start whether or not anyone remembered to run
# a setup command, and because a user who does run one wants to see what it
# did.
#
# What is configuration and what is machinery:
#
#   configuration   .fleet in foundry.json, and the role briefs and skills
#                   under <root>/.claude/. Copied once, then the project's.
#                   Never overwritten without --force.
#   machinery       the hooks and fleet-land. Refreshed from the shipped copy
#                   every time, so an upgraded Foundry cannot leave a project
#                   enforcing the previous version's rules.
#
# Requires: lib/utils.sh, lib/project.sh
#

_FLEET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SOURCE_DIR="${FLEET_SOURCE_DIR:-$(cd "${_FLEET_LIB_DIR}/.." && pwd)/templates/fleet}"

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# Read one field from a project's .fleet block.
# Usage: fleet_cfg <root> <jq-path-after-.fleet> [default]
fleet_cfg() {
    local root="$1" path="$2" fallback="${3:-}"
    local cfg value
    cfg="${root}/foundry.json"

    [[ -f "$cfg" ]] || { printf '%s' "$fallback"; return 0; }

    value=$(jq -r ".fleet${path} // empty" "$cfg" 2>/dev/null) || value=""
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

# ---------------------------------------------------------------------------
# Gate suggestion
# ---------------------------------------------------------------------------

# Guess a gate command from what the project's repositories look like.
#
# Per the project's config-driven doctrine: derive what can be derived, and ask
# only for what cannot. A guess is offered, never installed silently - the gate
# is the one setting where being wrong is worse than being absent, because a
# gate that measures the wrong thing still passes.
#
# Usage: fleet_suggest_gate <root>
fleet_suggest_gate() {
    local root="$1" repo

    for repo in "${root}/repos"/*; do
        [[ -d "$repo" ]] || continue

        if [[ -f "${repo}/package.json" ]]; then
            if jq -e '.scripts.gate' "${repo}/package.json" >/dev/null 2>&1; then
                printf 'npm run gate'; return 0
            fi
            if jq -e '.scripts.test' "${repo}/package.json" >/dev/null 2>&1; then
                printf 'npm test'; return 0
            fi
        fi
        if [[ -f "${repo}/Makefile" ]] && grep -qE '^(check|test):' "${repo}/Makefile" 2>/dev/null; then
            grep -qE '^check:' "${repo}/Makefile" && { printf 'make check'; return 0; }
            printf 'make test'; return 0
        fi
        if [[ -f "${repo}/pyproject.toml" || -f "${repo}/setup.cfg" ]]; then
            printf 'pytest'; return 0
        fi
        if [[ -f "${repo}/Cargo.toml" ]]; then
            printf 'cargo test'; return 0
        fi
        if [[ -f "${repo}/go.mod" ]]; then
            printf 'go test ./...'; return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Materialisation
# ---------------------------------------------------------------------------

# Seed .fleet into foundry.json without disturbing anything already there.
# Usage: _fleet_seed_config <root> <force>
_fleet_seed_config() {
    local root="$1" force="$2"
    local cfg="${root}/foundry.json"
    local defaults="${FLEET_SOURCE_DIR}/defaults/fleet.json"
    local existing tmp gate

    [[ -f "$cfg" ]] || { log_error "No foundry.json in $root"; return 1; }
    [[ -f "$defaults" ]] || { log_error "Missing fleet defaults: $defaults"; return 1; }

    existing=$(jq -r '.fleet.gate.command // ""' "$cfg" 2>/dev/null) || existing=""

    if jq -e '.fleet.roles | length > 0' "$cfg" >/dev/null 2>&1 && [[ "$force" != "true" ]]; then
        log_info "Fleet config already present in foundry.json; leaving it alone"
        log_info "Re-seed the defaults with: foundry fleet init --force"
        return 0
    fi

    tmp=$(mktemp)
    # The shipped defaults go underneath what the project already says, so a
    # gate command someone set is never replaced by an empty one.
    if ! jq -s '.[0] as $cfg | .[1] as $def
        | $cfg + { fleet: ($def + ($cfg.fleet // {})) }' \
        "$cfg" "$defaults" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_error "Could not merge fleet defaults into foundry.json"
        return 1
    fi

    if [[ -z "$existing" ]]; then
        if gate=$(fleet_suggest_gate "$root"); then
            jq --arg g "$gate" '.fleet.gate.command = $g' "$tmp" > "${tmp}.2" \
                && mv "${tmp}.2" "$tmp"
            log_info "Suggested gate command from the repositories: $gate"
            log_warn "Verify it: the gate decides when work is done, and a gate"
            log_warn "that measures the wrong thing still passes."
        fi
    fi

    mv "$tmp" "$cfg" || return 1
    chmod 0644 "$cfg" 2>/dev/null || true
    return 0
}

# Copy briefs, skills, hooks and fleet-land into the project.
# Usage: _fleet_copy_files <root> <force>
_fleet_copy_files() {
    local root="$1" force="$2"
    local claude_dir="${root}/.claude"
    local hooks_dir="${claude_dir}/hooks/fleet"
    local src dest rel

    mkdir -p "${claude_dir}/agents" "${claude_dir}/skills" "$hooks_dir" \
             "${root}/bin" "${root}/.foundry" "${root}/logs" || return 1

    while IFS= read -r src; do
        rel="${src#"${FLEET_SOURCE_DIR}/defaults/"}"
        case "$rel" in
            agents/*|skills/*) ;;
            *) continue ;;
        esac
        dest="${claude_dir}/${rel}"
        if [[ -e "$dest" && "$force" != "true" ]]; then
            log_debug "Keeping existing $dest"
            continue
        fi
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest" || return 1
        log_debug "Wrote $dest"
    done < <(find "${FLEET_SOURCE_DIR}/defaults" -type f -name '*.md' 2>/dev/null)

    cp "${FLEET_SOURCE_DIR}/hooks"/*.sh "$hooks_dir/" || return 1
    chmod +x "$hooks_dir"/*.sh 2>/dev/null || true

    cp "${FLEET_SOURCE_DIR}/bin/fleet-land" "${root}/bin/fleet-land" || return 1
    chmod +x "${root}/bin/fleet-land" 2>/dev/null || true

    return 0
}

# Render the hook wiring into the project's Claude settings.
_fleet_write_settings() {
    local root="$1"
    local settings="${root}/.claude/settings.json"
    local template="${FLEET_SOURCE_DIR}/defaults/settings.json"
    local hooks_dir="${root}/.claude/hooks/fleet"
    local rendered timeout merged tmp

    [[ -f "$template" ]] || return 0

    timeout=$(fleet_cfg "$root" '.gate.timeout_seconds' '900')
    timeout=$(( timeout + 60 ))

    rendered=$(sed -e "s#__FLEET_HOOKS__#${hooks_dir}#g" \
                   -e "s#__GATE_HOOK_TIMEOUT__#${timeout}#g" "$template")

    tmp=$(mktemp)
    if [[ -f "$settings" ]]; then
        # Foundry owns the fleet hooks in this file and nothing else in it.
        if ! jq -s '.[0] * .[1]' "$settings" <(printf '%s' "$rendered") > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            log_error "Could not merge fleet hooks into $settings"
            return 1
        fi
    else
        printf '%s\n' "$rendered" > "$tmp"
    fi

    mv "$tmp" "$settings" || return 1
    return 0
}

# Set up the fleet in a project.
# Usage: fleet_init <root> [force]
fleet_init() {
    local root="$1" force="${2:-false}"

    [[ -d "$root" ]] || { log_error "No such volume root: $root"; return 1; }

    _fleet_seed_config "$root" "$force" || return 1
    _fleet_copy_files "$root" "$force" || return 1
    _fleet_write_settings "$root" || return 1

    return 0
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Check that a project's fleet configuration would actually run.
#
# Prints findings and returns non-zero if anything would stop a run. Follows
# the project's sanity-check doctrine: name the file, the value, and what to do
# about it, rather than letting the run discover it at the worst moment.
#
# Usage: fleet_check <root> <project>
fleet_check() {
    local root="$1" project="$2"
    local problems=0 warnings=0
    local cfg="${root}/foundry.json"
    local agent gate enabled role brief

    if [[ ! -f "$cfg" ]]; then
        log_error "No foundry.json in $root"
        return 1
    fi

    if ! jq -e 'has("fleet")' "$cfg" >/dev/null 2>&1; then
        log_error "No .fleet block in $cfg"
        log_error "Create one with: foundry fleet init $project"
        return 1
    fi

    enabled=$(fleet_cfg "$root" '.enabled' 'false')
    if [[ "$enabled" != "true" ]]; then
        log_warn "Fleet is disabled (.fleet.enabled is $enabled)"
        log_warn "  Requests asking for a fleet will be refused with an explanation."
        warnings=$(( warnings + 1 ))
    fi

    agent=$(jq -r '.agent // "claude"' "$cfg" 2>/dev/null)
    case "$agent" in
        claude|claude-goal|claude-fleet) ;;
        *)
            log_error "Agent is '$agent'; the fleet only runs on Claude Code"
            log_error "  Set .agent to claude-goal or claude-fleet in $cfg"
            problems=$(( problems + 1 ))
            ;;
    esac

    gate=$(fleet_cfg "$root" '.gate.command' '')
    if [[ -z "$gate" ]]; then
        log_error "No gate command (.fleet.gate.command is empty)"
        log_error "  A fleet without a gate cannot decide when work is done, and"
        log_error "  every claim it makes is unverifiable. Set it in $cfg."
        if gate=$(fleet_suggest_gate "$root"); then
            log_error "  From the repositories here, this looks plausible: $gate"
        fi
        problems=$(( problems + 1 ))
    else
        log_info "Gate command: $gate"
    fi

    while IFS= read -r role; do
        [[ -n "$role" ]] || continue
        brief="${root}/.claude/agents/${role}.md"
        if [[ ! -f "$brief" ]]; then
            log_error "Role '$role' has no brief at $brief"
            log_error "  Create it, or run: foundry fleet init $project"
            problems=$(( problems + 1 ))
        elif ! head -n 5 "$brief" | grep -q "^name: ${role}$"; then
            log_error "Brief $brief does not declare 'name: $role' in its frontmatter"
            log_error "  Claude Code resolves subagents by that name, not by filename."
            problems=$(( problems + 1 ))
        else
            log_info "Role '$role': $brief"
        fi
    done < <(jq -r '(.fleet.roles // {}) | keys[]' "$cfg" 2>/dev/null)

    if [[ ! -f "${root}/.claude/skills/fleet-orchestrate/SKILL.md" ]]; then
        log_error "The orchestrator skill is missing from ${root}/.claude/skills/"
        log_error "  Run: foundry fleet init $project"
        problems=$(( problems + 1 ))
    fi

    if [[ ! -x "${root}/bin/fleet-land" ]]; then
        log_error "fleet-land is missing or not executable at ${root}/bin/fleet-land"
        log_error "  Run: foundry fleet init $project"
        problems=$(( problems + 1 ))
    fi

    if [[ "$problems" -gt 0 ]]; then
        log_error "$problems problem(s) would stop a fleet run"
        return 1
    fi

    if [[ "$warnings" -gt 0 ]]; then
        log_warn "$warnings warning(s); a fleet run would start"
        return 0
    fi

    log_info "Fleet configuration is complete"
    return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# Usage: fleet_show <root> <project>
fleet_show() {
    local root="$1" project="$2"
    local cfg="${root}/foundry.json"

    [[ -f "$cfg" ]] || { log_error "No foundry.json in $root"; return 1; }

    echo "Fleet configuration: $project"
    echo
    printf '  Enabled:          %s\n' "$(fleet_cfg "$root" '.enabled' 'false')"
    printf '  Default strategy: %s\n' "$(fleet_cfg "$root" '.strategy' 'solo')"
    printf '  Agent:            %s\n' "$(jq -r '.agent // "claude"' "$cfg")"
    echo
    printf '  Gate command:     %s\n' "$(fleet_cfg "$root" '.gate.command' '(none — a fleet cannot run)')"
    printf '  Gate format:      %s\n' "$(fleet_cfg "$root" '.gate.format' 'auto')"
    printf '  Gate timeout:     %ss\n' "$(fleet_cfg "$root" '.gate.timeout_seconds' '900')"
    printf '  Iteration budget: %s\n' "$(fleet_cfg "$root" '.gate.max_iterations' '12')"
    echo
    echo "  Roles:"
    jq -r '(.fleet.roles // {}) | to_entries[]
        | "    " + .key + "  x" + ((.value.count // 1) | tostring)
          + "  model=" + (.value.model // "default")' "$cfg" 2>/dev/null \
        || echo "    (none)"
    if ! jq -e '(.fleet.roles // {}) | length > 0' "$cfg" >/dev/null 2>&1; then
        echo "    (none configured)"
    fi
    echo
    echo "  Lanes:"
    if jq -e '(.fleet.lanes // {}) | length > 0' "$cfg" >/dev/null 2>&1; then
        jq -r '(.fleet.lanes // {}) | to_entries[]
            | "    " + .key + ": " + (if (.value|type)=="array" then join(", ") else (.value|tostring) end)' \
            "$cfg" 2>/dev/null
    else
        echo "    (none — the orchestrator partitions the work per round)"
    fi
    echo
    echo "  Editable files:"
    printf '    %s\n' "${root}/foundry.json  (.fleet)"
    printf '    %s\n' "${root}/.claude/agents/*.md"
    printf '    %s\n' "${root}/.claude/skills/fleet-*/SKILL.md"
    echo
}
