#!/usr/bin/env bash
#
# Agent Foundry Forgejo Watcher - Autonomous Forgejo Issue/PR Monitor
#
# Receives Forgejo webhooks, detects trigger mentions, builds agent-specific
# task context, and triggers the configured autonomous agent to work.
#
# Everything lives under the agent's home, which is the project's volume root:
#
#   Configuration: ~/.config/forgejo-watcher/config.conf
#   State:         ~/.config/forgejo-watcher/processed.json
#   Queue:         ~/.config/forgejo-watcher/queue/
#   Logs:          ~/.config/forgejo-watcher/watcher.log
#
# The host writes config.conf from foundry.json; the rest is the watcher's own
# state. Because the home is the mounted volume root, all of it survives the
# sandbox being stopped, recreated or rebuilt - which is what makes "already
# processed" mean anything across restarts.
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG_DIR="${CONFIG_DIR:-${HOME:?HOME is not set}/.config/forgejo-watcher}"
CONFIG_FILE="$CONFIG_DIR/config.conf"
PROCESSED_FILE="$CONFIG_DIR/processed.json"
RETRY_FILE="$CONFIG_DIR/retries.json"
QUEUE_DIR="$CONFIG_DIR/queue"
LOG_FILE="$CONFIG_DIR/watcher.log"
CURRENT_TASK_FILE="$CONFIG_DIR/current_task.json"
CONTEXT_FILE="$CONFIG_DIR/current_context.json"

# Where the prompt library writes the reply for a request that stated no task
# mode. Exported so the adapter writes it somewhere the watcher can find,
# rather than defaulting to a cwd-relative path.
export FOUNDRY_REPLY_FILE="${FOUNDRY_REPLY_FILE:-$CONFIG_DIR/last_reply.md}"
HELPER_DIR="${HELPER_DIR:-/opt/foundry/forgejo}"
# Adapters shared by every forge (the goal adapter) sit one level up.
FOUNDRY_LIB_DIR="${FOUNDRY_LIB_DIR:-/opt/foundry}"

# Defaults (overridden by config file)
WATCHER_ENABLED="${WATCHER_ENABLED:-false}"
WATCHED_REPOS="${WATCHED_REPOS:-}"
FORGEJO_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-}"
FORGEJO_TOKEN_FILE="${FORGEJO_TOKEN_FILE:-$CONFIG_DIR/token}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-120}"
POST_ERROR_COMMENTS="${POST_ERROR_COMMENTS:-true}"
DRY_RUN="${DRY_RUN:-false}"
TRIGGER_KEYWORD="${TRIGGER_KEYWORD:-@agent}"
RATE_LIMIT_RETRY_SECONDS="${RATE_LIMIT_RETRY_SECONDS:-3600}"
RECEIVER_PORT="${RECEIVER_PORT:-8080}"
RECEIVER_INTERFACE="${RECEIVER_INTERFACE:-0.0.0.0}"
AGENT_WORKSPACE="${AGENT_WORKSPACE:-$HOME}"
AGENT_TYPE="${AGENT_TYPE:-}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-Agent}"
# The account the token belongs to. Events it authored are ignored, because
# every reply the watcher writes contains the trigger keyword.
WATCHER_BOT_USER="${WATCHER_BOT_USER:-}"
# Work that predates this run is not acted on. A watcher that comes up to a
# backlog cannot tell a request from five minutes ago from one from last month,
# and answering all of them at once is never what was wanted. Set
# WATCHER_PROCESS_BACKLOG=true to take the queue as it stands instead.
WATCHER_PROCESS_BACKLOG="${WATCHER_PROCESS_BACKLOG:-false}"
WATCHER_CUTOFF_TS="${WATCHER_CUTOFF_TS:-}"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    shift
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# ============================================================================
# HELPER MODULES
# ============================================================================

source_watcher_helpers() {
    local common_helper="$HELPER_DIR/forgejo_watcher_common.sh"

    if [[ ! -f "$common_helper" ]]; then
        log_error "Watcher helper missing: $common_helper"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$common_helper"

    local adapter_file
    adapter_file=$(_agent_adapter_file)
    if [[ -n "$adapter_file" && -f "$adapter_file" ]]; then
        # shellcheck source=/dev/null
        source "$adapter_file"
    else
        log_error "Watcher adapter missing for agent type: $AGENT_TYPE"
        return 1
    fi
}

# Everything the event path calls that the helpers or the adapter must supply.
#
# Checked once, at startup, because the alternative is finding out mid-event:
# the watcher runs under `set -e`, so an undefined function exits it with 127
# in the middle of handling a request. That happened with
# evaluate_agent_outcome, which no file defined - every completed run killed
# the watcher, and the restart discarded whatever had queued up behind it. The
# run itself had already succeeded, so nothing anywhere reported a problem.
#
# Bash cannot check this for us: an undefined function looks like an external
# command until the moment it runs. scripts/check-prompts.sh enforces the same
# rule statically; this is the backstop for an image built before it did.
WATCHER_REQUIRED_FUNCTIONS=(
    prepare_agent_workspace
    start_agent_loop
    evaluate_agent_outcome
    ensure_processed_file_valid
    ensure_retry_file_valid
    mark_processed
    is_processed
    clear_retry
    schedule_retry
    post_reply_file
    post_error_comment
    add_reaction
    start_tmux_runner
)

require_watcher_contract() {
    local missing=() fn
    for fn in "${WATCHER_REQUIRED_FUNCTIONS[@]}"; do
        declare -F "$fn" >/dev/null 2>&1 || missing+=("$fn")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    log_error "The watcher is missing ${#missing[@]} function(s) it depends on:"
    for fn in "${missing[@]}"; do
        log_error "    ${fn}()"
    done
    log_error "  Refusing to start: each of these is called while handling an"
    log_error "  event, and the watcher would exit 127 in the middle of one."
    log_error "  The image and the adapter disagree - rebuild and re-create:"
    log_error "    foundry image build"
    log_error "    foundry rm <project> && foundry init <project>"
    return 1
}

_agent_adapter_file() {
    if [[ -z "$AGENT_TYPE" ]]; then
        echo ""
        return
    fi
    # The goal agents share one adapter: it writes the task prompt and the
    # completion condition, and neither varies by agent or by forge. The loop
    # belongs to the CLI, so there is nothing per-agent left to adapt.
    case "$AGENT_TYPE" in
        *-goal|claude-fleet)
            echo "$FOUNDRY_LIB_DIR/watcher_agent_goal.sh"
            return
            ;;
    esac

    # Otherwise: one adapter per autonomous agent type.
    echo "$HELPER_DIR/forgejo_watcher_agent_${AGENT_TYPE}.sh"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

init_watcher() {
    mkdir -p "$CONFIG_DIR" "$QUEUE_DIR"
    touch "$LOG_FILE"

    if [[ -f "$CONFIG_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        set +a
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "The host writes it from foundry.json: run 'foundry up <project>'"
        return 1
    fi

    if ! source_watcher_helpers; then
        return 1
    fi

    if ! require_watcher_contract; then
        return 1
    fi

    # After the helpers, which is where these two are defined. Calling them
    # first left the state files uncreated: init_watcher runs inside an `if !`,
    # which suspends set -e for the whole function, so "command not found" was
    # reported on stderr - discarded under tmux - and the watcher carried on.
    ensure_processed_file_valid
    ensure_retry_file_valid

    if [[ "$WATCHER_ENABLED" != "true" ]]; then
        log_warn "Watcher is disabled in config (WATCHER_ENABLED=false)"
        return 1
    fi

    if [[ -z "$WATCHED_REPOS" ]]; then
        log_error "No repositories configured (WATCHED_REPOS is empty)"
        return 1
    fi

    if [[ -z "$FORGEJO_INSTANCE_URL" ]]; then
        log_error "FORGEJO_INSTANCE_URL is not configured"
        return 1
    fi

    if [[ -z "${FORGEJO_TOKEN:-}" && -f "$FORGEJO_TOKEN_FILE" ]]; then
        FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
    fi

    if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
        log_error "Forgejo token not found"
        return 1
    fi

    if [[ -z "$AGENT_TYPE" ]]; then
        log_error "AGENT_TYPE is not set in $CONFIG_FILE"
        log_error "It comes from .agent in foundry.json; re-run 'foundry up'."
        return 1
    fi

    case "$AGENT_TYPE" in
        claude-goal|codex-goal|agy-goal|claude-fleet)
            ;;
        *)
            log_error "Unsupported watcher agent type: $AGENT_TYPE"
            return 1
            ;;
    esac

    AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-$AGENT_TYPE}"

    # Without this the watcher answers its own replies forever. The host
    # normally writes it into config.conf; ask the forge if it did not, and
    # refuse to run rather than loop if the answer never comes.
    if [[ -z "$WATCHER_BOT_USER" ]]; then
        WATCHER_BOT_USER="$(curl -fsS --max-time 10 \
            -H "Authorization: token ${FORGEJO_TOKEN}" \
            "${FORGEJO_INSTANCE_URL%/}/api/v1/user" 2>/dev/null \
            | jq -r '.login // empty')"
    fi

    if [[ -z "$WATCHER_BOT_USER" ]]; then
        log_error "Could not determine which account the token belongs to"
        log_error "Refusing to start: the watcher would answer its own replies."
        log_error "Set WATCHER_BOT_USER, or check the token and instance URL."
        return 1
    fi
    log_info "  Acting as: $WATCHER_BOT_USER (its own events are ignored)"

    # Work that predates this watcher is not acted on - but "this watcher"
    # means the first time it ever ran here, not this process.
    #
    # The supervisor restarts the watcher whenever it exits, so a cutoff taken
    # per process would move forward on every crash and silently swallow
    # everything that arrived in between. The forge does not redeliver, so
    # those events are simply lost. The cutoff is therefore written once and
    # kept, and the queue is left alone: process_event compares each event's
    # own timestamp against it, which distinguishes a month-old backlog from
    # something queued three seconds ago. A blanket wipe cannot.
    if [[ "$WATCHER_PROCESS_BACKLOG" == "true" ]]; then
        log_warn "WATCHER_PROCESS_BACKLOG=true: acting on work of any age"
        WATCHER_CUTOFF_TS=""
    else
        local cutoff_file="$CONFIG_DIR/cutoff"
        if [[ -s "$cutoff_file" ]]; then
            WATCHER_CUTOFF_TS="$(tr -d '[:space:]' < "$cutoff_file")"
        fi
        if [[ ! "$WATCHER_CUTOFF_TS" =~ ^[0-9]+$ ]]; then
            WATCHER_CUTOFF_TS="$(date +%s)"
            printf '%s\n' "$WATCHER_CUTOFF_TS" > "$cutoff_file"
            log_info "  First run here: ignoring anything created before now"
        fi
        log_info "  Cutoff: work created after $(date -d "@${WATCHER_CUTOFF_TS}" -Iseconds)"
        local queued_count=0 queued
        for queued in "$QUEUE_DIR"/*.json; do
            [[ -e "$queued" ]] || continue
            queued_count=$((queued_count + 1))
        done
        [[ "$queued_count" -gt 0 ]] && \
            log_info "  ${queued_count} event(s) waiting in the queue"
    fi

    log_info "Forgejo watcher initialized"
    log_info "  Instance: $FORGEJO_INSTANCE_URL"
    log_info "  Watching repos: $WATCHED_REPOS"
    log_info "  Agent type: $AGENT_TYPE"

    return 0
}

# ============================================================================
# RECEIVER MANAGEMENT
# ============================================================================

receiver_is_running() {
    tmux has-session -t forgejo-receiver 2>/dev/null
}

start_receiver() {
    if receiver_is_running; then
        log_info "Forgejo receiver already running"
        return 0
    fi

    log_info "Starting Forgejo receiver on $RECEIVER_INTERFACE:$RECEIVER_PORT"

    tmux kill-session -t forgejo-receiver 2>/dev/null || true
    tmux new-session -d -s forgejo-receiver "$HELPER_DIR/forgejo_receiver.sh start"

    sleep 1
    if receiver_is_running; then
        log_info "Forgejo receiver started"
        return 0
    fi

    log_error "Failed to start Forgejo receiver"

    # The receiver logs its own reason - a missing socat, a port already
    # taken - and dies. Without this the watcher only ever reported that it
    # failed, which says nothing about what to fix.
    local receiver_log="$CONFIG_DIR/receiver.log"
    if [[ -f "$receiver_log" ]]; then
        local line
        while IFS= read -r line; do
            log_error "  ${line#*] }"
        done < <(grep -i 'error' "$receiver_log" 2>/dev/null | tail -n 3)
    else
        log_error "  It wrote no log, so it died before it could start:"
        log_error "  check that socat is installed in the image."
    fi

    return 1
}

stop_receiver() {
    if receiver_is_running; then
        tmux kill-session -t forgejo-receiver
        log_info "Forgejo receiver stopped"
    fi
}

# ============================================================================
# AGENT STATUS
# ============================================================================

is_agent_running() {
    tmux has-session -t foundry-work 2>/dev/null
}

wait_for_agent() {
    log_info "Waiting for $AGENT_DISPLAY_NAME to finish (timeout: ${AGENT_TIMEOUT}m)..."
    local deadline now
    deadline=$(($(date +%s) + AGENT_TIMEOUT * 60))

    while is_agent_running; do
        now=$(date +%s)
        if [[ "$now" -ge "$deadline" ]]; then
            log_warn "$AGENT_DISPLAY_NAME did not finish within ${AGENT_TIMEOUT}m; killing tmux session"
            tmux kill-session -t foundry-work 2>/dev/null || true
            break
        fi
        sleep 30
    done
    log_info "$AGENT_DISPLAY_NAME has finished"
}

# ============================================================================
# EVENT PROCESSING
# ============================================================================

task_id_from_event() {
    local event_type="$1"
    local payload="$2"

    case "$event_type" in
        issues)
            local number
            number=$(echo "$payload" | jq -r '.issue.number')
            echo "issue_${number}"
            ;;
        issue_comment)
            local number comment_id
            number=$(echo "$payload" | jq -r '.issue.number')
            comment_id=$(echo "$payload" | jq -r '.comment.id')
            echo "issue_${number}_comment_${comment_id}"
            ;;
        pull_request)
            local number
            number=$(echo "$payload" | jq -r '.pull_request.number')
            echo "pr_${number}"
            ;;
        pull_request_review_comment)
            local number comment_id
            number=$(echo "$payload" | jq -r '.pull_request.number')
            comment_id=$(echo "$payload" | jq -r '.comment.id')
            echo "pr_${number}_review_${comment_id}"
            ;;
        workflow_run)
            local run_id
            run_id=$(echo "$payload" | jq -r '.workflow_run.id')
            echo "workflow_run_${run_id}"
            ;;
        *)
            return 1
            ;;
    esac
}

trigger_from_event() {
    local event_type="$1"
    local payload="$2"

    local body=""
    case "$event_type" in
        issues)
            body=$(echo "$payload" | jq -r '.issue.body // ""')
            ;;
        issue_comment)
            body=$(echo "$payload" | jq -r '.comment.body // ""')
            ;;
        pull_request)
            body=$(echo "$payload" | jq -r '.pull_request.body // ""')
            ;;
        pull_request_review_comment)
            body=$(echo "$payload" | jq -r '.comment.body // ""')
            ;;
        workflow_run)
            local action conclusion branch
            action=$(echo "$payload" | jq -r '.action // ""')
            conclusion=$(echo "$payload" | jq -r '.workflow_run.conclusion // ""')
            branch=$(echo "$payload" | jq -r '.workflow_run.head_branch // ""')

            if [[ "$action" == "completed" && "$conclusion" == "failure" && "$branch" == "$DEFAULT_BRANCH" ]]; then
                echo "pipeline_failure: $branch"
                return 0
            fi
            return 1
            ;;
    esac

    if echo "$body" | grep -qiF "$TRIGGER_KEYWORD"; then
        echo "$body"
        return 0
    fi
    return 1
}

event_to_task_json() {
    local event_type="$1"
    local payload="$2"

    case "$event_type" in
        issues)
            jq -n \
                --arg repo "$(echo "$payload" | jq -r '.repository.full_name')" \
                --argjson number "$(echo "$payload" | jq -r '.issue.number')" \
                --arg title "$(echo "$payload" | jq -r '.issue.title')" \
                --arg body "$(echo "$payload" | jq -r '.issue.body // ""')" \
                --arg created_at "$(echo "$payload" | jq -r '
                    if (.action // "opened") == "opened"
                    then .issue.created_at
                    else (.issue.updated_at // .issue.created_at) end')" \
                --arg html_url "$(echo "$payload" | jq -r '.issue.html_url')" \
                '{type:"issue", repo:$repo, number:$number, title:$title, body:$body, created_at:$created_at, html_url:$html_url}'
            ;;
        issue_comment)
            jq -n \
                --arg repo "$(echo "$payload" | jq -r '.repository.full_name')" \
                --argjson number "$(echo "$payload" | jq -r '.issue.number')" \
                --argjson id "$(echo "$payload" | jq -r '.comment.id')" \
                --arg body "$(echo "$payload" | jq -r '.comment.body // ""')" \
                --arg created_at "$(echo "$payload" | jq -r '.comment.created_at')" \
                --arg html_url "$(echo "$payload" | jq -r '.comment.html_url')" \
                '{type:"issue_comment", repo:$repo, number:$number, id:$id, body:$body, created_at:$created_at, html_url:$html_url}'
            ;;
        pull_request)
            jq -n \
                --arg repo "$(echo "$payload" | jq -r '.repository.full_name')" \
                --argjson number "$(echo "$payload" | jq -r '.pull_request.number')" \
                --arg title "$(echo "$payload" | jq -r '.pull_request.title')" \
                --arg body "$(echo "$payload" | jq -r '.pull_request.body // ""')" \
                --arg created_at "$(echo "$payload" | jq -r '
                    if (.action // "opened") == "opened"
                    then .pull_request.created_at
                    else (.pull_request.updated_at // .pull_request.created_at) end')" \
                --arg html_url "$(echo "$payload" | jq -r '.pull_request.html_url')" \
                '{type:"pr", repo:$repo, number:$number, title:$title, body:$body, created_at:$created_at, html_url:$html_url}'
            ;;
        pull_request_review_comment)
            jq -n \
                --arg repo "$(echo "$payload" | jq -r '.repository.full_name')" \
                --argjson number "$(echo "$payload" | jq -r '.pull_request.number')" \
                --argjson id "$(echo "$payload" | jq -r '.comment.id')" \
                --arg body "$(echo "$payload" | jq -r '.comment.body // ""')" \
                --arg created_at "$(echo "$payload" | jq -r '.comment.created_at')" \
                --arg html_url "$(echo "$payload" | jq -r '.comment.html_url')" \
                '{type:"pr_review_comment", repo:$repo, number:$number, id:$id, body:$body, created_at:$created_at, html_url:$html_url}'
            ;;
        workflow_run)
            jq -n \
                --arg repo "$(echo "$payload" | jq -r '.repository.full_name')" \
                --argjson run_id "$(echo "$payload" | jq -r '.workflow_run.id')" \
                --arg name "$(echo "$payload" | jq -r '.workflow_run.name')" \
                --arg conclusion "$(echo "$payload" | jq -r '.workflow_run.conclusion')" \
                --arg branch "$(echo "$payload" | jq -r '.workflow_run.head_branch')" \
                --arg sha "$(echo "$payload" | jq -r '.workflow_run.head_sha')" \
                --arg created_at "$(echo "$payload" | jq -r '.workflow_run.created_at')" \
                --arg html_url "$(echo "$payload" | jq -r '.workflow_run.html_url')" \
                '{type:"pipeline_failure", repo:$repo, run_id:$run_id, name:$name, conclusion:$conclusion, branch:$branch, sha:$sha, created_at:$created_at, html_url:$html_url}'
            ;;
    esac
}


# Cap replies per thread.
#
# Ignoring our own account stops the loop we caused; this stops the next one.
# Anything that echoes the trigger keyword - another bot, a quoted comment, a
# mirrored issue - produces the same flood, and the forge accepts comments far
# faster than a human can notice.
#
# Returns 0 when replying is allowed.
reply_budget_ok() {
    local thread="$1"
    local window="${REPLY_WINDOW_SECONDS:-300}"
    local cap="${REPLY_CAP_PER_WINDOW:-5}"
    local state="$CONFIG_DIR/reply-budget.json"
    local now
    now="$(date +%s)"

    [[ -s "$state" ]] || printf '{}\n' > "$state"

    local recent
    recent="$(jq -r --arg t "$thread" --argjson now "$now" --argjson w "$window" \
        '[(.[$t] // [])[] | select(. > ($now - $w))] | length' "$state" 2>/dev/null)"
    [[ "$recent" =~ ^[0-9]+$ ]] || recent=0

    if [[ "$recent" -ge "$cap" ]]; then
        log_error "Reply cap reached for ${thread}: ${recent} in ${window}s"
        log_error "  Refusing to reply again - this is what a comment loop looks like."
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    if jq --arg t "$thread" --argjson now "$now" --argjson w "$window" \
        '.[$t] = ([((.[$t] // [])[] | select(. > ($now - $w))), $now])' \
        "$state" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$state"
    else
        rm -f "$tmp"
    fi
    return 0
}

process_event() {
    local event_file="$1"
    local event_type payload

    event_type=$(jq -r '.event_type' "$event_file")
    payload=$(jq '.payload' "$event_file")

    log_debug "Processing event: $event_type from $event_file"

    # Never act on our own comments.
    #
    # The help reply lists the usage, which necessarily contains the trigger
    # keyword - so posting it produces an event that triggers another reply,
    # for as fast as the forge will accept comments. Any reply the watcher
    # writes has this property; the account is the only reliable way out.
    local author
    author="$(printf '%s' "$payload" | jq -r '
        .comment.user.login // .issue.user.login // .sender.login // empty')"
    if [[ -n "$WATCHER_BOT_USER" && "$author" == "$WATCHER_BOT_USER" ]]; then
        log_debug "Ignoring event authored by ${author} (that is us)"
        rm -f "$event_file"
        return 0
    fi

    if ! trigger_from_event "$event_type" "$payload" >/dev/null; then
        log_debug "No trigger keyword in $event_type event, skipping"
        rm -f "$event_file"
        return 0
    fi

    local task_id
    task_id=$(task_id_from_event "$event_type" "$payload") || {
        log_warn "Could not derive task ID for event $event_type"
        rm -f "$event_file"
        return 0
    }

    if is_processed "$task_id"; then
        log_debug "Task $task_id already processed, skipping"
        rm -f "$event_file"
        return 0
    fi

    local task_json
    task_json=$(event_to_task_json "$event_type" "$payload")

    local task_type repo created_at number
    task_type=$(echo "$task_json" | jq -r '.type')
    repo=$(echo "$task_json" | jq -r '.repo')
    created_at=$(echo "$task_json" | jq -r '.created_at')
    number=$(echo "$task_json" | jq -r '.number')

    # Older than this run: record it as seen and move on, so a later restart
    # does not reconsider it either.
    if [[ -n "$WATCHER_CUTOFF_TS" && -n "$created_at" && "$created_at" != "null" ]]; then
        local created_ts
        created_ts="$(date -d "$created_at" +%s 2>/dev/null || echo 0)"
        if [[ "$created_ts" -gt 0 && "$created_ts" -lt "$WATCHER_CUTOFF_TS" ]]; then
            log_info "Ignoring $task_type #${number} from ${created_at}: predates this run"
            mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"skipped_backlog\"}"
            rm -f "$event_file"
            return 0
        fi
    fi

    log_info "Found trigger in $task_type event for $repo"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would process task $task_id"
        echo "$task_json" > "$CURRENT_TASK_FILE"
        rm -f "$event_file"
        return 0
    fi

    # Pipeline failures skip issue/PR state checks and reactions
    if [[ "$task_type" != "pipeline_failure" ]]; then
        # Check if issue/PR is open
        local state_field state
        state_field=$([[ "$task_type" == "issue" || "$task_type" == "issue_comment" ]] && echo "issue" || echo "pull_request")
        state=$(echo "$payload" | jq -r ".${state_field}.state // \"unknown\"")
        if [[ "$state" != "open" ]]; then
            log_debug "Skipping $task_type #$number in $repo as it is $state"
            mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"skipped_closed\"}"
            rm -f "$event_file"
            return 0
        fi

        # Add reaction
        case "$task_type" in
            issue)
                add_reaction "$repo" "issue" "$number" "eyes"
                ;;
            issue_comment)
                local comment_id
                comment_id=$(echo "$task_json" | jq -r '.id')
                add_reaction "$repo" "issue_comment" "$comment_id" "eyes"
                ;;
            pr)
                add_reaction "$repo" "issue" "$number" "eyes"
                ;;
            pr_review_comment)
                local comment_id
                comment_id=$(echo "$task_json" | jq -r '.id')
                add_reaction "$repo" "pr_review_comment" "$comment_id" "eyes"
                ;;
        esac
    fi

    # Build context
    local context_success=false
    case "$task_type" in
        issue|issue_comment)
            local trigger_comment_id=""
            [[ "$task_type" == "issue_comment" ]] && trigger_comment_id=$(echo "$task_json" | jq -r '.id')
            if build_issue_context_json "$repo" "$number" "$task_type" "$trigger_comment_id" "$created_at" "$CONTEXT_FILE"; then
                context_success=true
            fi
            ;;
        pr|pr_review_comment)
            local trigger_comment_id=""
            [[ "$task_type" == "pr_review_comment" ]] && trigger_comment_id=$(echo "$task_json" | jq -r '.id')
            if build_pr_context_json "$repo" "$number" "$task_type" "$trigger_comment_id" "$created_at" "$CONTEXT_FILE"; then
                context_success=true
            fi
            ;;
        pipeline_failure)
            if build_pipeline_failure_context_json "$task_json" "$CONTEXT_FILE"; then
                context_success=true
            fi
            ;;
    esac

    if [[ "$context_success" != "true" ]]; then
        log_error "Failed to build context for $task_type"
        mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_context_failed\"}"
        rm -f "$event_file"
        return 0
    fi

    echo "$task_json" > "$CURRENT_TASK_FILE"
    local run_start_epoch
    run_start_epoch=$(date +%s)

    local prepare_rc=0
    # A reply from a previous event must not be posted as if it were this
    # one's; 78 is also sysexits' EX_CONFIG, so require the file to exist too.
    rm -f "$FOUNDRY_REPLY_FILE"
    prepare_agent_workspace "$CONTEXT_FILE" || prepare_rc=$?

    # 78 means the request stated no task mode. The prompt library has written
    # the syntax reply to FOUNDRY_REPLY_FILE and no agent should run; posting
    # the generic workspace error here would discard it.
    if [[ ( "$prepare_rc" -eq "${FOUNDRY_EXIT_HELP:-78}" ||
            "$prepare_rc" -eq "${FOUNDRY_EXIT_REFUSED:-79}" ) && -s "$FOUNDRY_REPLY_FILE" ]]; then
        local reply_result="replied_no_mode"
        # 79 means the request named something this project cannot run - a
        # fleet with no gate, or a fleet on an agent that has no subagents.
        # Same handling as 78: the reply is already written, and no agent runs.
        if [[ "$prepare_rc" -eq "${FOUNDRY_EXIT_REFUSED:-79}" ]]; then
            reply_result="replied_refused"
            log_info "Request cannot be run as asked for $task_id; replying"
        else
            log_info "No task mode stated for $task_id; replying with usage"
        fi
        if [[ "$task_type" != "pipeline_failure" ]] && ! reply_budget_ok "${repo}#${number}"; then
            reply_result="skipped_reply_cap"
        elif [[ "$task_type" != "pipeline_failure" ]]; then
            # Record what actually happened. Filing an unposted reply as
            # answered would strand the request: nobody was told anything, and
            # the event is never looked at again.
            if ! post_reply_file "$repo" "$number" "$FOUNDRY_REPLY_FILE"; then
                log_error "Usage reply could not be posted for $task_id"
                reply_result="error_reply_failed"
            fi
        fi
        mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"$reply_result\"}"
        rm -f "$event_file"
        return 0
    fi

    if [[ "$prepare_rc" -ne 0 ]]; then
        log_error "Failed to prepare agent workspace for $task_id"
        if [[ "$task_type" != "pipeline_failure" ]]; then
            post_error_comment "$repo" "$number" "Failed to prepare agent workspace"
        fi
        mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_workspace_failed\"}"
        rm -f "$event_file"
        return 0
    fi

    if start_agent_loop; then
        wait_for_agent

        local outcome outcome_type outcome_detail
        outcome=$(evaluate_agent_outcome "$run_start_epoch")
        outcome_type="${outcome%%:*}"
        outcome_detail="${outcome#*:}"

        case "$outcome_type" in
            success)
                clear_retry "$task_id"
                mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"trigger_created_at\":\"$created_at\",\"result\":\"completed\"}"
                log_info "Task $task_id completed"
                if [[ "$task_type" != "pipeline_failure" ]]; then
                    case "$task_type" in
                        issue|pr)
                            add_reaction "$repo" "issue" "$number" "rocket"
                            ;;
                        issue_comment)
                            add_reaction "$repo" "issue_comment" "$(echo "$task_json" | jq -r '.id')" "rocket"
                            ;;
                        pr_review_comment)
                            add_reaction "$repo" "pr_review_comment" "$(echo "$task_json" | jq -r '.id')" "rocket"
                            ;;
                    esac
                fi
                ;;
            rate_limited)
                log_warn "$AGENT_DISPLAY_NAME hit usage limit for $task_id, scheduling retry"
                if [[ "$task_type" != "pipeline_failure" ]]; then
                    post_error_comment "$repo" "$number" "Agent backend usage limit reached. I will retry this task automatically in about one hour."
                fi
                schedule_retry "$task_id" "$RATE_LIMIT_RETRY_SECONDS" "$outcome_detail"
                ;;
            failure|unknown)
                clear_retry "$task_id"
                log_error "$AGENT_DISPLAY_NAME failed for $task_id: $outcome_detail"
                if [[ "$task_type" != "pipeline_failure" ]]; then
                    post_error_comment "$repo" "$number" "$AGENT_DISPLAY_NAME exited early: $outcome_detail"
                fi
                mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_runtime_failed\"}"
                ;;
        esac
    else
        log_error "Failed to start $AGENT_DISPLAY_NAME for $task_id"
        if [[ "$task_type" != "pipeline_failure" ]]; then
            post_error_comment "$repo" "$number" "Failed to start $AGENT_DISPLAY_NAME"
        fi
        clear_retry "$task_id"
        mark_processed "$task_id" "{\"type\":\"$task_type\",\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_start_failed\"}"
    fi

    rm -f "$event_file"
    sleep 120
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main_loop() {
    log_info "Forgejo Watcher started"
    log_info "  Instance: $FORGEJO_INSTANCE_URL"
    log_info "  Repos: $WATCHED_REPOS"
    log_info "  Receiver: $RECEIVER_INTERFACE:$RECEIVER_PORT"

    start_receiver || {
        log_error "Failed to start receiver, aborting"
        return 1
    }

    while true; do
        if is_agent_running; then
            log_debug "$AGENT_DISPLAY_NAME is working, waiting..."
            sleep 30
            continue
        fi

        # Process queued events
        local event_file found_event=false
        for event_file in "$QUEUE_DIR"/event-*.json; do
            [[ -f "$event_file" ]] || continue
            found_event=true
            process_event "$event_file"
            break
        done

        if [[ "$found_event" == "false" ]]; then
            sleep 5
        fi
    done
}

# ============================================================================
# COMMAND HANDLERS
# ============================================================================

cmd_start() {
    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi

    main_loop
}

cmd_dry_run() {
    DRY_RUN=true
    log_info "Starting Forgejo watcher in DRY RUN mode"
    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi
    main_loop
}

cmd_stop() {
    log_info "Stopping Forgejo watcher..."

    if tmux has-session -t forgejo-watcher 2>/dev/null; then
        tmux kill-session -t forgejo-watcher
    fi

    stop_receiver

    log_info "Forgejo watcher stopped"
}

cmd_status() {
    echo "Forgejo Watcher Status"
    echo "======================"

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        echo "Configuration: $CONFIG_FILE"
        echo "  Enabled: ${WATCHER_ENABLED:-unknown}"
        echo "  Instance: ${FORGEJO_INSTANCE_URL:-unknown}"
        echo "  Repos: ${WATCHED_REPOS:-unknown}"
        echo "  Receiver port: ${RECEIVER_PORT:-unknown}"
        echo "  Agent type: ${AGENT_TYPE:-unknown}"
        echo "  Agent display name: ${AGENT_DISPLAY_NAME:-$AGENT_TYPE}"
        echo ""
    else
        echo "Configuration: Not found"
        echo ""
    fi

    if tmux has-session -t forgejo-watcher 2>/dev/null; then
        echo "Watcher session: RUNNING (tmux: forgejo-watcher)"
    else
        echo "Watcher session: NOT RUNNING"
    fi

    if tmux has-session -t forgejo-receiver 2>/dev/null; then
        echo "Receiver session: RUNNING (tmux: forgejo-receiver)"
    else
        echo "Receiver session: NOT RUNNING"
    fi

    if is_agent_running 2>/dev/null; then
        echo "Agent status: WORKING (${AGENT_DISPLAY_NAME:-$AGENT_TYPE})"
    else
        echo "Agent status: IDLE"
    fi

    echo ""

    ensure_processed_file_valid
    local task_count last_poll
    task_count=$(jq '.processed | length' "$PROCESSED_FILE")
    last_poll=$(jq -r '.last_poll' "$PROCESSED_FILE")
    echo "Processed tasks: $task_count"
    echo "Last poll: $last_poll"

    if [[ -f "$CURRENT_TASK_FILE" ]]; then
        echo ""
        echo "Current task:"
        jq '.' "$CURRENT_TASK_FILE" 2>/dev/null || echo "  (unable to parse)"
    fi
}

cmd_reset() {
    log_warn "This will clear all processed task history and queued events"
    read -r -p "Are you sure? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF

    rm -f "$CURRENT_TASK_FILE" "$CONTEXT_FILE" "$RETRY_FILE" "$CONFIG_DIR"/run-status.json
    rm -f "$QUEUE_DIR"/event-*.json

    log_info "Forgejo watcher state reset"
}

cmd_mark_all() {
    log_info "Marking all existing trigger mentions as processed..."

    if [[ -f "$CONFIG_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        set +a
    else
        log_error "Configuration file not found"
        exit 1
    fi

    if ! source_watcher_helpers; then
        log_error "Failed to load watcher helpers"
        exit 1
    fi

    ensure_processed_file_valid

    # Drop whatever is queued. The cutoff at startup means anything older than
    # the next run is ignored anyway; this makes that explicit, and is what to
    # reach for after a flood or a long outage.
    local dropped=0 queued
    for queued in "$QUEUE_DIR"/*.json; do
        [[ -e "$queued" ]] || continue
        rm -f "$queued"
        dropped=$((dropped + 1))
    done

    local now
    now="$(date +%s)"
    printf '%s\n' "$now" > "$CONFIG_DIR/cutoff"

    log_info "Discarded ${dropped} queued event(s); cutoff moved to $(date -Iseconds)"
    echo "Discarded ${dropped} queued event(s) and moved the cutoff to now."
    echo "Nothing created before this moment will be picked up again."
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local action="${1:-start}"

    case "$action" in
        start)
            cmd_start "$@"
            ;;
        dry-run)
            cmd_dry_run "$@"
            ;;
        stop)
            cmd_stop
            ;;
        status)
            cmd_status
            ;;
        reset)
            cmd_reset
            ;;
        mark-all)
            cmd_mark_all
            ;;
        *)
            echo "Usage: $0 {start|dry-run|stop|status|reset|mark-all}"
            exit 1
            ;;
    esac
}

main "$@"
