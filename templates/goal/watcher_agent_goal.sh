#!/usr/bin/env bash
#
# Adapter for the autonomous agents: claude-goal, codex-goal, agy-goal, and
# claude-fleet.
#
# One adapter serves all of them. Their CLIs each ship a /goal command that
# keeps working across turns until a completion condition holds, so the only
# thing this has to do is write the task prompt and hand over the condition -
# the loop, the retry and the completion check all belong to the CLI.
#
# The fleet is not a different kind of run from the adapter's point of view. It
# resolves the same mode from the same request and writes the same prompt; what
# changes is one extra section in that prompt and which launcher starts. That
# is deliberate: making the fleet a separate adapter would have duplicated mode
# resolution, which is the one piece of this system that must never have two
# implementations.
#
# Prompt content is built by the shared library at /opt/foundry/prompt-lib.sh
# so that the execution contract, task modes, and identity string stay
# identical across every agent and forge. See docs/PROMPT-ARCHITECTURE.md.
#

set -euo pipefail

FOUNDRY_PROMPT_LIB="${FOUNDRY_PROMPT_LIB:-/opt/foundry/prompt-lib.sh}"
if [[ -f "$FOUNDRY_PROMPT_LIB" ]]; then
    # shellcheck source=../prompt-lib.sh
    source "$FOUNDRY_PROMPT_LIB"
fi

# Objectives render as a plain list here, which is already the library default.
# A goal agent reads its objective as prose, not as a checklist to tick off, so
# nothing should set "checklist" for these - but an operator override still wins.
FOUNDRY_OBJECTIVE_STYLE="${FOUNDRY_OBJECTIVE_STYLE:-bullet}"

FOUNDRY_FLEET_LIB="${FOUNDRY_FLEET_LIB:-/opt/foundry/fleet/fleet-lib.sh}"
if [[ -f "$FOUNDRY_FLEET_LIB" ]]; then
    # shellcheck source=../fleet/fleet-lib.sh
    source "$FOUNDRY_FLEET_LIB"
fi

# Where the agent's CLI looks for its own state, per lib/agent-registry.sh.
_goal_dotfolder() {
    case "${AGENT_TYPE:-}" in
        claude-goal|claude-fleet) printf '.claude' ;;
        codex-goal)  printf '.codex' ;;
        agy-goal)    printf '.gemini' ;;
        *)           printf '.foundry' ;;
    esac
}

# Resolve the execution strategy for this request and export everything the
# prompt library and the launcher need for it.
#
# Refuses, rather than downgrades, when a fleet is asked for and cannot be run.
# Silently running solo would give the requester a single agent's work while
# they believe an orchestrator verified it and a critic reviewed it, which is
# the most expensive way to be wrong about a change.
#
# Sets FOUNDRY_TASK_STRATEGY. Returns FOUNDRY_EXIT_REFUSED after writing the
# reply when the request cannot be honoured.
_resolve_strategy() {
    local context_file="$1"
    local root="${AGENT_WORKSPACE:-$HOME}"
    local reason

    # The project default, which the request can override either way.
    if declare -F fleet_default_strategy >/dev/null; then
        FOUNDRY_DEFAULT_STRATEGY="$(fleet_default_strategy "$root")"
        export FOUNDRY_DEFAULT_STRATEGY
    fi

    FOUNDRY_TASK_STRATEGY="$(foundry_task_strategy "$context_file")"
    export FOUNDRY_TASK_STRATEGY

    if [[ "$FOUNDRY_TASK_STRATEGY" != "fleet" ]]; then
        log_info "Resolved strategy: $FOUNDRY_TASK_STRATEGY"
        _export_packet_path "$context_file"
        return 0
    fi

    # The fleet is built on Claude Code's subagents, skills and hooks. No other
    # CLI in the image has that combination.
    case "${AGENT_TYPE:-}" in
        claude|claude-goal|claude-fleet) ;;
        *)
            log_warn "Fleet requested but this project runs $AGENT_TYPE"
            foundry_write_refusal_reply "This project is configured to run \`${AGENT_TYPE}\`, and the fleet only runs on Claude Code — it is built on subagents, skills and hooks that the other CLIs do not have.

Set \`.agent\` to \`claude-goal\` or \`claude-fleet\` in \`foundry.json\` if you want fleet runs on this project, or drop the \`fleet\` keyword to run this request as a single agent."
            return $?
            ;;
    esac

    if ! declare -F fleet_preflight >/dev/null; then
        log_error "Fleet requested but the fleet library is missing at $FOUNDRY_FLEET_LIB"
        foundry_write_refusal_reply "The fleet library is missing from this sandbox image. Rebuild it with \`foundry image build\` and re-create the sandbox, or drop the \`fleet\` keyword to run this request as a single agent."
        return $?
    fi

    if ! reason=$(fleet_preflight "$root"); then
        log_warn "Fleet requested but preflight refused it"
        foundry_write_refusal_reply "$reason"
        return $?
    fi

    log_info "Resolved strategy: fleet"

    # Rendering is best-effort on purpose. These three are presentation for
    # the prompt, and a config oddity in one of them must not drop a request
    # that is otherwise fine - the adapter runs under set -e, so an unguarded
    # command substitution here would end the run instead of the section.
    # `fleet check` is where a malformed lanes block gets reported.
    FOUNDRY_FLEET_GATE="$(fleet_gate_command "$root" || true)"
    FOUNDRY_FLEET_ROLES="$(fleet_render_roles "$root" || true)"
    FOUNDRY_FLEET_LANES="$(fleet_render_lanes "$root" || true)"
    export FOUNDRY_FLEET_GATE FOUNDRY_FLEET_ROLES FOUNDRY_FLEET_LANES

    _export_packet_path "$context_file"
    return 0
}

# Where this task keeps its durable notes.
#
# Every agent type gets one, not only the fleet: an agent that dies with its
# reasoning only in a transcript has to start over, and the volume root is a
# host directory that outlives any sandbox.
_export_packet_path() {
    local context_file="$1"
    local root="${AGENT_WORKSPACE:-$HOME}"
    local cfg enabled dir repo_name number kind slug

    cfg="${root}/foundry.json"
    enabled="true"
    dir="packets"
    if [[ -f "$cfg" ]]; then
        enabled=$(jq -r '.packets.enabled // true' "$cfg" 2>/dev/null) || enabled="true"
        dir=$(jq -r '.packets.dir // "packets"' "$cfg" 2>/dev/null) || dir="packets"
    fi

    [[ "$enabled" == "true" ]] || return 0

    repo_name=$(jq -r '.repo_name // "repo"' "$context_file" 2>/dev/null)
    kind=$(jq -r '.kind // "task"' "$context_file" 2>/dev/null)
    number=$(jq -r '.number // ""' "$context_file" 2>/dev/null)

    slug="${repo_name}-${kind}${number:+-$number}"
    slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '-')

    mkdir -p "${root}/${dir}" 2>/dev/null || return 0
    FOUNDRY_PACKET_FILE="${root}/${dir}/${slug}.md"
    export FOUNDRY_PACKET_FILE
}

prepare_goal_workspace() {
    local context_file="$1"
    local kind mode dotfolder prompt_file condition repo_name

    if ! declare -F foundry_build_task_prompt >/dev/null; then
        log_error "Prompt library missing at $FOUNDRY_PROMPT_LIB"
        return 1
    fi

    kind=$(jq -r '.kind' "$context_file")
    dotfolder="$(_goal_dotfolder)"
    prompt_file="${AGENT_WORKSPACE}/${dotfolder}/task_prompt.md"

    mkdir -p "${AGENT_WORKSPACE}/${dotfolder}" "${AGENT_WORKSPACE}/logs"

    case "$kind" in
        issue | pr)
            mode=$(foundry_task_mode "$context_file")
            # No mode stated: reply with the syntax and run no agent. The
            # watcher posts FOUNDRY_REPLY_FILE on this exit code.
            if [[ "$mode" == "help" ]]; then
                log_info "No task mode stated; replying with usage"
                foundry_write_help_reply
                return $?
            fi
            log_info "Resolved task mode: $mode (kind: $kind)"
            _resolve_strategy "$context_file" || return $?
            foundry_build_task_prompt "$context_file" "$mode" > "$prompt_file" || return 1
            ;;
        pipeline_failure)
            mode="fix"
            log_info "Resolved task mode: fix (kind: pipeline_failure)"
            # A pipeline failure carries no human request, so there is no
            # keyword to read a strategy out of. It takes the project default,
            # which for most projects is solo - a red pipeline is usually one
            # fix, and a fleet would be slower at it.
            _resolve_strategy "$context_file" || return $?
            foundry_build_pipeline_prompt "$context_file" > "$prompt_file" || return 1
            ;;
        *)
            log_error "Unsupported context kind for a goal agent: $kind"
            return 1
            ;;
    esac

    # The condition names the end state; the prompt file carries everything
    # else. Referencing the file by its path keeps the condition short - claude
    # caps it at 4000 characters, and a condition competing with the prompt is
    # the source-conflict problem this architecture exists to prevent.
    FOUNDRY_TASK_PROMPT_REF="$prompt_file"
    export FOUNDRY_TASK_PROMPT_REF

    condition=$(foundry_goal_condition "$mode" "$context_file") || return 1
    FOUNDRY_GOAL_CONDITION="$condition"
    export FOUNDRY_GOAL_CONDITION

    # Goal agents anchor on a git repository. Without one, agy silently works
    # in an internal scratch workspace and reports success for it.
    repo_name=$(jq -r '.repo_name // ""' "$context_file")
    if [[ -n "$repo_name" ]]; then
        FOUNDRY_REPO_PATH="$(foundry_repo_path "$repo_name")"
        export FOUNDRY_REPO_PATH
    fi

    log_info "Prepared ${AGENT_TYPE:-goal} workspace: $prompt_file"
    log_info "Goal: $condition"
}

# The launchers shipped in the image. One copy of each CLI's invocation, so the
# adapter never restates a command line.
FOUNDRY_GOAL_LAUNCHER="${FOUNDRY_GOAL_LAUNCHER:-/opt/foundry/start-goal.sh}"
FOUNDRY_FLEET_LAUNCHER="${FOUNDRY_FLEET_LAUNCHER:-/opt/foundry/fleet/start-fleet.sh}"

# Start the agent.
#
# The watcher's contract is prepare_agent_workspace followed by
# start_agent_loop; an adapter that defines only the first prepares a workspace
# nothing ever runs in.
#
# The goal condition and the paths are written into a runner script rather than
# inherited, so quoting survives the trip through tmux - a condition is a
# sentence, and sentences contain quotes.
start_agent_loop() {
    local runner log_file launcher run_as

    if [[ -z "${FOUNDRY_GOAL_CONDITION:-}" ]]; then
        log_error "No goal condition; prepare_agent_workspace must run first"
        return 1
    fi

    # The strategy decides the launcher, and with it the agent type the run
    # reports as. A project set to claude-goal runs claude-fleet for a request
    # that asked for one, and a project set to claude-fleet runs a plain goal
    # loop for a request that asked for solo: the configured type is the
    # default, and the request moves it.
    if [[ "${FOUNDRY_TASK_STRATEGY:-solo}" == "fleet" ]]; then
        launcher="$FOUNDRY_FLEET_LAUNCHER"
        run_as="claude-fleet"
    else
        launcher="$FOUNDRY_GOAL_LAUNCHER"
        run_as="$AGENT_TYPE"
        # A project configured for the fleet still has to run something real
        # when a request asks for solo, and "claude-fleet" is not a goal
        # launcher case.
        [[ "$run_as" == "claude-fleet" ]] && run_as="claude-goal"
    fi

    if [[ ! -x "$launcher" ]]; then
        log_error "Launcher missing: $launcher"
        return 1
    fi

    log_file="${AGENT_LOG_FILE:-${AGENT_WORKSPACE}/logs/${AGENT_TYPE}.log}"
    # A fixed path, not mktemp: the watcher runs one task at a time, so there
    # is nothing to collide with, and a new temp file per task accumulated
    # forever in a sandbox that can live for weeks. It is also somewhere to
    # look while a run is in flight.
    runner="/tmp/foundry-goal-runner.sh"
    rm -f "$runner"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'export AGENT_TYPE=%q\n'              "$run_as"
        printf 'export AGENT_WORKSPACE=%q\n'         "$AGENT_WORKSPACE"
        printf 'export AGENT_LOG_FILE=%q\n'          "$log_file"
        printf 'export AGENT_TASK_PROMPT_FILE=%q\n'  "$FOUNDRY_TASK_PROMPT_REF"
        printf 'export AGENT_GOAL_CONDITION=%q\n'    "$FOUNDRY_GOAL_CONDITION"
        printf 'export AGENT_REPO_PATH=%q\n'         "${FOUNDRY_REPO_PATH:-}"
        printf 'export AGENT_GOAL_TIMEOUT=%q\n'      "${FOUNDRY_GOAL_TIMEOUT:-4h}"
        printf 'exec %q\n'                           "$launcher"
    } > "$runner"
    chmod +x "$runner"

    log_info "Starting $(agent_display_name "$run_as" 2>/dev/null || echo "$run_as")"
    start_tmux_runner "$runner"

    if tmux has-session -t foundry-work 2>/dev/null; then
        log_info "Started $AGENT_TYPE in tmux session 'foundry-work'"
        return 0
    fi

    log_error "Failed to start $AGENT_TYPE tmux session"
    return 1
}

# The watcher calls prepare_agent_workspace; keep the shared name.
prepare_agent_workspace() {
    prepare_goal_workspace "$@"
}
