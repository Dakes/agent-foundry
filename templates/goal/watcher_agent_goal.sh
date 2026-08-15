#!/usr/bin/env bash
#
# Adapter for the goal-mode agents: claude-goal, codex-goal, agy-goal.
#
# One adapter serves all three. Their CLIs each ship a /goal command that keeps
# working across turns until a completion condition holds, so the only thing
# this has to do is write the task prompt and hand over the condition - the
# loop, the retry and the completion check all belong to the CLI.
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

# Where the agent's CLI looks for its own state, per lib/agent-registry.sh.
_goal_dotfolder() {
    case "${AGENT_TYPE:-}" in
        claude-goal) printf '.claude' ;;
        codex-goal)  printf '.codex' ;;
        agy-goal)    printf '.gemini' ;;
        *)           printf '.foundry' ;;
    esac
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
            foundry_build_task_prompt "$context_file" "$mode" > "$prompt_file" || return 1
            ;;
        pipeline_failure)
            mode="fix"
            log_info "Resolved task mode: fix (kind: pipeline_failure)"
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

# The launcher shipped in the image. One copy of each CLI's invocation, so the
# adapter never restates a command line.
FOUNDRY_GOAL_LAUNCHER="${FOUNDRY_GOAL_LAUNCHER:-/opt/foundry/start-goal.sh}"

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
    local runner log_file

    if [[ -z "${FOUNDRY_GOAL_CONDITION:-}" ]]; then
        log_error "No goal condition; prepare_agent_workspace must run first"
        return 1
    fi

    if [[ ! -x "$FOUNDRY_GOAL_LAUNCHER" ]]; then
        log_error "Goal launcher missing: $FOUNDRY_GOAL_LAUNCHER"
        return 1
    fi

    log_file="${AGENT_LOG_FILE:-${AGENT_WORKSPACE}/logs/${AGENT_TYPE}.log}"
    runner="$(mktemp "/tmp/foundry-goal-XXXXXX.sh")"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'export AGENT_TYPE=%q\n'              "$AGENT_TYPE"
        printf 'export AGENT_WORKSPACE=%q\n'         "$AGENT_WORKSPACE"
        printf 'export AGENT_LOG_FILE=%q\n'          "$log_file"
        printf 'export AGENT_TASK_PROMPT_FILE=%q\n'  "$FOUNDRY_TASK_PROMPT_REF"
        printf 'export AGENT_GOAL_CONDITION=%q\n'    "$FOUNDRY_GOAL_CONDITION"
        printf 'export AGENT_REPO_PATH=%q\n'         "${FOUNDRY_REPO_PATH:-}"
        printf 'export AGENT_GOAL_TIMEOUT=%q\n'      "${FOUNDRY_GOAL_TIMEOUT:-4h}"
        printf 'exec %q\n'                           "$FOUNDRY_GOAL_LAUNCHER"
    } > "$runner"
    chmod +x "$runner"

    log_info "Starting $(agent_display_name "$AGENT_TYPE" 2>/dev/null || echo "$AGENT_TYPE")"
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
