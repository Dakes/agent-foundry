#!/usr/bin/env bash
#
# Agent Foundry GitHub Watcher - Autonomous GitHub Issue/PR Monitor
#
# Polls GitHub repositories for trigger mentions, builds agent-specific task
# context, and triggers the configured autonomous agent to work.
#
# Configuration: /root/.config/gh-watcher/config.conf
# State tracking: /root/.config/gh-watcher/processed.json
# Logs: /root/.config/gh-watcher/watcher.log
#

set -euo pipefail

# Error trap for debugging
trap 'echo "[$(date)] ERROR: Script exited with error at line $LINENO (exit code: $?)" >> /root/.config/gh-watcher/watcher.log 2>&1' ERR

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG_DIR="/root/.config/gh-watcher"
CONFIG_FILE="$CONFIG_DIR/config.conf"
PROCESSED_FILE="$CONFIG_DIR/processed.json"
RETRY_FILE="$CONFIG_DIR/retries.json"
LOG_FILE="$CONFIG_DIR/watcher.log"
CURRENT_TASK_FILE="$CONFIG_DIR/current_task.json"
CONTEXT_FILE="$CONFIG_DIR/current_context.json"

# Where the prompt library writes the reply for a request that stated no task
# mode. Exported so the adapter writes it somewhere the watcher can find,
# rather than defaulting to a cwd-relative path.
# Set when the last context build answered with the usage reply rather than
# failing, so the task is recorded as answered instead of errored.
HELP_REPLY_POSTED=false

export FOUNDRY_REPLY_FILE="${FOUNDRY_REPLY_FILE:-$CONFIG_DIR/last_reply.md}"
HELPER_DIR="/opt/foundry/gh-watcher"

# Default values (overridden by config file)
WATCHER_ENABLED="${WATCHER_ENABLED:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
WATCHED_REPOS="${WATCHED_REPOS:-}"
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-/root/.config/gh/token}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-120}"
POST_ERROR_COMMENTS="${POST_ERROR_COMMENTS:-true}"
POLL_LOOKBACK_SECONDS="${POLL_LOOKBACK_SECONDS:-900}"
DRY_RUN="${DRY_RUN:-false}"
RATE_LIMIT_RETRY_SECONDS="${RATE_LIMIT_RETRY_SECONDS:-3600}"

AGENT_WORKSPACE="/root"
AGENT_TYPE="${AGENT_TYPE:-}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-Agent}"

# Legacy compatibility: Ralph variant detection marker.
RALPH_VARIANT_MARKER="${RALPH_VARIANT_MARKER:-/opt/foundry/ralph-agent-type}"
RALPH_VARIANT_CLAUDE_CODE="${RALPH_VARIANT_CLAUDE_CODE:-ralph-claude-code}"
RALPH_VARIANT_ORCHESTRATOR="${RALPH_VARIANT_ORCHESTRATOR:-ralph-orchestrator}"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_debug() {
    log "DEBUG" "$@"
}

# ============================================================================
# HELPER MODULES
# ============================================================================

source_watcher_helpers() {
    local common_helper="$HELPER_DIR/gh_watcher_common.sh"

    if [[ ! -f "$common_helper" ]]; then
        log_error "Watcher helper missing: $common_helper"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$common_helper"

    # Backwards-compatible workspace variables used by legacy Ralph adapters.
    RALPH_WORKSPACE="$AGENT_WORKSPACE"
    KIMI_WORKSPACE="$AGENT_WORKSPACE"

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

_agent_adapter_file() {
    if [[ -z "$AGENT_TYPE" ]]; then
        echo ""
        return
    fi
    # The goal agents share one adapter: it writes the task prompt and the
    # completion condition, and neither varies by agent or by forge. The loop
    # belongs to the CLI, so there is nothing per-agent left to adapt.
    case "$AGENT_TYPE" in
        *-goal)
            echo "$HELPER_DIR/watcher_agent_goal.sh"
            return
            ;;
    esac

    # Otherwise: one adapter per autonomous agent type.
    echo "$HELPER_DIR/gh_watcher_agent_${AGENT_TYPE}.sh"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

init_watcher() {
    # Create config directory
    mkdir -p "$CONFIG_DIR"

    ensure_processed_file_valid

    # Create retry state file if it doesn't exist
    if [[ ! -f "$RETRY_FILE" ]]; then
        cat > "$RETRY_FILE" <<'EOF'
{
  "version": "1.0",
  "retries": {}
}
EOF
        log_info "Initialized retry state file: $RETRY_FILE"
    fi

    # Create log file
    touch "$LOG_FILE"

    # Load configuration before sourcing helpers so that AGENT_TYPE (and any
    # other watcher settings) are available when we select the agent adapter.
    if [[ -f "$CONFIG_FILE" ]]; then
        # Source config file
        set -a
        source "$CONFIG_FILE"
        set +a
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Run 'foundry agent gh-watcher init <vm-name>' first"
        return 1
    fi

    if ! source_watcher_helpers; then
        return 1
    fi

    # Validate configuration
    if [[ "$WATCHER_ENABLED" != "true" ]]; then
        log_warn "Watcher is disabled in config (WATCHER_ENABLED=false)"
        return 1
    fi

    if [[ -z "$WATCHED_REPOS" ]]; then
        log_error "No repositories configured (WATCHED_REPOS is empty)"
        return 1
    fi

    if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
        log_error "GitHub token file not found: $GITHUB_TOKEN_FILE"
        log_error "Create token with: echo 'ghp_token' > $GITHUB_TOKEN_FILE && chmod 600 $GITHUB_TOKEN_FILE"
        return 1
    fi

    # Load GitHub token
    export GH_TOKEN
    GH_TOKEN=$(cat "$GITHUB_TOKEN_FILE")

    if [[ -z "$GH_TOKEN" ]]; then
        log_error "GitHub token is empty in $GITHUB_TOKEN_FILE"
        return 1
    fi

    # Resolve agent type (legacy fallback to Ralph variant detection)
    if [[ -z "$AGENT_TYPE" ]]; then
        AGENT_TYPE=$(detect_legacy_agent_type)
        log_warn "AGENT_TYPE not configured; falling back to legacy detection: $AGENT_TYPE"
    fi

    case "$AGENT_TYPE" in
        ralph|ralph-orchestrator|kimi-ralph|claude-goal|codex-goal|agy-goal)
            ;;
        *)
            log_error "Unsupported watcher agent type: $AGENT_TYPE"
            return 1
            ;;
    esac

    AGENT_DISPLAY_NAME=${AGENT_DISPLAY_NAME:-$AGENT_TYPE}

    log_info "GitHub watcher initialized"
    log_info "  Watching repos: $WATCHED_REPOS"
    log_info "  Poll interval: ${POLL_INTERVAL}s"
    log_info "  Agent workspace: $AGENT_WORKSPACE"
    log_info "  Agent type: $AGENT_TYPE"

    return 0
}

detect_legacy_agent_type() {
    if [[ -f "$RALPH_VARIANT_MARKER" ]]; then
        local variant
        variant=$(tr -d '[:space:]' < "$RALPH_VARIANT_MARKER")
        case "$variant" in
            "$RALPH_VARIANT_ORCHESTRATOR")
                echo "ralph-orchestrator"
                ;;
            *)
                echo "ralph"
                ;;
        esac
        return 0
    fi

    if [[ -d /opt/ralph ]]; then
        echo "ralph"
        return 0
    fi

    if command -v ralph >/dev/null 2>&1; then
        local version
        version=$(ralph --version 2>/dev/null | head -n 1 || true)
        if echo "$version" | grep -qi "orchestrator"; then
            echo "ralph-orchestrator"
            return 0
        fi
        echo "ralph"
        return 0
    fi

    echo "ralph"
}

ensure_processed_file_valid() {
    local reset_needed=false

    if [[ ! -f "$PROCESSED_FILE" ]] || [[ ! -s "$PROCESSED_FILE" ]]; then
        reset_needed=true
    elif ! jq -e '.processed and .last_poll' "$PROCESSED_FILE" >/dev/null 2>&1; then
        reset_needed=true
    fi

    if [[ "$reset_needed" == "true" ]]; then
        cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
        log_warn "Rebuilt processed tasks file: $PROCESSED_FILE"
    fi
}

set_last_poll() {
    local timestamp="$1"
    local temp_file

    ensure_processed_file_valid
    temp_file=$(mktemp)
    if jq ".last_poll = \"$timestamp\"" "$PROCESSED_FILE" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$PROCESSED_FILE"
        return 0
    fi

    rm -f "$temp_file"
    return 1
}

task_id_for_task_json() {
    local task_json="$1"
    local task_type number id

    task_type=$(echo "$task_json" | jq -r '.type')
    number=$(echo "$task_json" | jq -r '.number')
    id=$(echo "$task_json" | jq -r '.id // empty')

    case "$task_type" in
        issue_comment)
            echo "issue_${number}_comment_${id}"
            ;;
        pr_review_comment)
            echo "pr_${number}_review_${id}"
            ;;
        issue)
            echo "issue_${number}"
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# AGENT STATUS CHECKING
# ============================================================================

is_agent_running() {
    tmux has-session -t ralph-loop 2>/dev/null
}

wait_for_agent() {
    log_info "Waiting for $AGENT_DISPLAY_NAME to finish..."
    while is_agent_running; do
        sleep 30
    done
    log_info "$AGENT_DISPLAY_NAME has finished"
}

# ============================================================================
# PROCESSED TASKS TRACKING
# ============================================================================

is_processed() {
    local task_id="$1"
    ensure_processed_file_valid
    jq -e ".processed.\"$task_id\"" "$PROCESSED_FILE" >/dev/null 2>&1
}

mark_processed() {
    local task_id="$1"
    local task_data="$2"

    ensure_processed_file_valid

    # Update processed.json
    local temp_file
    temp_file=$(mktemp)
    if jq ".processed.\"$task_id\" = $task_data | .last_poll = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" \
        "$PROCESSED_FILE" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$PROCESSED_FILE"
        log_debug "Marked task $task_id as processed"
    else
        log_warn "Failed to mark task $task_id as processed"
        rm -f "$temp_file"
    fi
}

clear_retry() {
    local task_id="$1"
    local temp_file
    temp_file=$(mktemp)
    jq "del(.retries.\"$task_id\")" "$RETRY_FILE" > "$temp_file"
    mv "$temp_file" "$RETRY_FILE"
}

schedule_retry() {
    local task_id="$1"
    local seconds="$2"
    local reason="$3"

    local now next_epoch next_iso temp_file
    now=$(date +%s)
    next_epoch=$((now + seconds))
    next_iso=$(date -u -d "@$next_epoch" +"%Y-%m-%dT%H:%M:%SZ")

    temp_file=$(mktemp)
    jq ".retries.\"$task_id\" = {\"reason\":\"$reason\",\"scheduled_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"next_retry_epoch\":$next_epoch,\"next_retry_at\":\"$next_iso\"}" \
        "$RETRY_FILE" > "$temp_file"
    mv "$temp_file" "$RETRY_FILE"

    log_warn "Scheduled retry for $task_id at $next_iso (reason: $reason)"
}

is_retry_blocked() {
    local task_id="$1"
    local now next_retry_epoch
    now=$(date +%s)
    next_retry_epoch=$(jq -r ".retries.\"$task_id\".next_retry_epoch // 0" "$RETRY_FILE" 2>/dev/null || echo "0")

    if [[ "$next_retry_epoch" =~ ^[0-9]+$ ]] && (( next_retry_epoch > now )); then
        return 0
    fi

    return 1
}

get_last_poll() {
    ensure_processed_file_valid
    jq -r '.last_poll // "1970-01-01T00:00:00Z"' "$PROCESSED_FILE"
}

get_query_since() {
    local last_poll
    last_poll=$(get_last_poll)

    if [[ "${POLL_LOOKBACK_SECONDS:-0}" =~ ^[0-9]+$ ]] && [[ "${POLL_LOOKBACK_SECONDS:-0}" -gt 0 ]]; then
        local adjusted_since
        adjusted_since=$(date -u -d "$last_poll - ${POLL_LOOKBACK_SECONDS} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        if [[ -n "$adjusted_since" ]]; then
            echo "$adjusted_since"
            return 0
        fi
    fi

    echo "$last_poll"
}

# ============================================================================
# GITHUB API QUERIES
# ============================================================================

add_reaction() {
    local repo="$1"
    local type="$2" # issue, issue_comment, pr_review_comment
    local id="$3"   # number or comment_id
    local emoji="${4:-eyes}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would add $emoji reaction to $type $id in $repo"
        return 0
    fi

    log_debug "Adding $emoji reaction to $type $id in $repo"

    case "$type" in
        issue)
            gh api "repos/$repo/issues/$id/reactions" -f content="$emoji" >/dev/null 2>&1 || true
            ;;
        issue_comment)
            gh api "repos/$repo/issues/comments/$id/reactions" -f content="$emoji" >/dev/null 2>&1 || true
            ;;
        pr_review_comment)
            gh api "repos/$repo/pulls/comments/$id/reactions" -f content="$emoji" >/dev/null 2>&1 || true
            ;;
    esac
}

find_trigger_mentions() {
    local query_since
    query_since=$(get_query_since)

    log_debug "Searching for trigger mentions (all open issues/PRs, since $query_since)"

    # Priority 1: Check recent PR/Issue comments for trigger (use 'since' to reduce API calls)
    for repo in ${WATCHED_REPOS//,/ }; do
        log_debug "Checking recent comments in $repo"

        # Get recent issue comments on PR conversations or Issues
        if ! gh api --paginate "repos/$repo/issues/comments?since=$query_since&per_page=100" \
            --jq '.[] | select(.body | test("!ralph"; "i")) | {type: "issue_comment", repo: "'"$repo"'", id: .id, number: (.issue_url | split("/")[-1] | tonumber), body: .body, html_url: .html_url, user: .user.login, created_at: .created_at}' \
            2>&1; then
            log_error "Failed to check comments in $repo (is gh CLI installed and authenticated?)"
        fi

        log_debug "Checking recent PR review comments in $repo"

        # Get recent line-level PR review comments
        if ! gh api --paginate "repos/$repo/pulls/comments?since=$query_since&per_page=100" \
            --jq '.[] | select(.body | test("!ralph"; "i")) | {type: "pr_review_comment", repo: "'"$repo"'", id: .id, number: (.pull_request_url | split("/")[-1] | tonumber), body: .body, html_url: .html_url, user: .user.login, created_at: .created_at}' \
            2>&1; then
            log_error "Failed to check PR review comments in $repo"
        fi
    done

    # Priority 2: Check ALL open issues for trigger (not just updated ones)
    for repo in ${WATCHED_REPOS//,/ }; do
        log_debug "Checking all open issues in $repo"

        # Get ALL open issues and filter for trigger
        if ! gh api "repos/$repo/issues?state=open&per_page=100" \
            --jq '.[] | select(.pull_request == null) | select(.body | test("!ralph"; "i")) | {type: "issue", repo: "'"$repo"'", number: .number, title: .title, body: .body, html_url: .html_url, user: .user.login, created_at: .created_at}' \
            2>&1; then
            log_error "Failed to check issues in $repo"
        fi
    done
}

# ============================================================================
# CONTEXT BUILDING AND AGENT EXECUTION
# ============================================================================

# Prepare the workspace, or answer a request that stated no task mode.
#
# The adapter returns FOUNDRY_EXIT_HELP (78) when the triggering comment named
# no mode. That is not a failure: the prompt library has written the syntax
# reply to FOUNDRY_REPLY_FILE and no agent should start. Treating it as a
# generic error would post "Failed to prepare agent workspace" and throw the
# reply away, which is the one outcome this whole path exists to avoid.
#
# Returns non-zero either way so the caller starts no agent.
_prepare_or_reply() {
    local repo="$1"
    local number="$2"
    local rc=0

    # A reply left over from a previous event must never be posted as if it
    # belonged to this one. Exit 78 is also sysexits' EX_CONFIG, so a tool
    # inside prepare_agent_workspace could return it for its own reasons.
    HELP_REPLY_POSTED=false
    rm -f "$FOUNDRY_REPLY_FILE"

    prepare_agent_workspace "$CONTEXT_FILE" || rc=$?

    if [[ "$rc" -eq "${FOUNDRY_EXIT_HELP:-78}" && -s "$FOUNDRY_REPLY_FILE" ]]; then
        log_info "No task mode stated; replying with usage and starting no agent"
        if post_reply_file "$repo" "$number" "$FOUNDRY_REPLY_FILE"; then
            HELP_REPLY_POSTED=true
        else
            # Leave the flag false so the caller records a failure rather than
            # filing the task as answered when nobody was answered.
            log_error "Usage reply could not be posted for $repo #$number"
        fi
        return 1
    fi

    return "$rc"
}

build_context_for_issue() {
    local repo="$1"
    local issue_number="$2"
    local trigger_type="${3:-issue}"
    local trigger_comment_id="${4:-}"
    local trigger_created_at="${5:-}"

    log_info "Building $AGENT_TYPE context for issue #$issue_number in $repo"

    if ! build_issue_context_json "$repo" "$issue_number" "$trigger_type" "$trigger_comment_id" "$trigger_created_at" "$CONTEXT_FILE"; then
        return 1
    fi

    _prepare_or_reply "$repo" "$issue_number"
}

build_context_for_pr() {
    local repo="$1"
    local pr_number="$2"
    local trigger_type="${3:-pr_review_comment}"
    local trigger_comment_id="${4:-}"
    local trigger_created_at="${5:-}"

    log_info "Building $AGENT_TYPE context for PR #$pr_number in $repo"

    if ! build_pr_context_json "$repo" "$pr_number" "$trigger_type" "$trigger_comment_id" "$trigger_created_at" "$CONTEXT_FILE"; then
        return 1
    fi

    _prepare_or_reply "$repo" "$pr_number"
}

start_agent() {
    start_agent_loop
}

evaluate_agent_run_outcome() {
    local run_start_epoch="$1"
    evaluate_agent_outcome "$run_start_epoch"
}

# Error-comment header. Delegates to the prompt library so identity resolves
# the same way it does in the completion header, including the registry
# fallback that a hand-rolled ${AGENT_IDENTITY:-${AGENT_DISPLAY_NAME}} skips.
_watcher_error_header() {
    if declare -F foundry_error_header >/dev/null; then
        foundry_error_header
        return 0
    fi
    # identity-fallback: only reached when prompt-lib.sh was not sourced
    printf '## 🤖 %s - Task Update (Error)' "${AGENT_IDENTITY:-${AGENT_DISPLAY_NAME:-Agent}}"
}

# Post a pre-rendered comment body verbatim - the no-mode-stated reply, which
# is hardcoded text rather than the output of an agent run.
post_reply_file() {
    local repo="$1"
    local issue_or_pr_number="$2"
    local reply_file="$3"

    [[ -s "$reply_file" ]] || { log_error "No reply to post: $reply_file"; return 1; }

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would post reply to $repo #$issue_or_pr_number"
        return 0
    fi

    log_info "Posting reply to $repo #$issue_or_pr_number"
    # The status matters: the caller records the task as answered only if the
    # comment actually went out. `|| log_error` alone would swallow it and
    # return 0, so a failed post would be filed as a successful reply.
    if ! gh api "repos/$repo/issues/$issue_or_pr_number/comments" \
        -f body="$(cat "$reply_file")" >/dev/null 2>&1; then
        log_error "Failed to post reply to $repo #$issue_or_pr_number"
        return 1
    fi
    return 0
}

post_error_comment() {
    local repo="$1"
    local issue_or_pr_number="$2"
    local error_message="$3"

    if [[ "$POST_ERROR_COMMENTS" != "true" ]]; then
        log_debug "Skipping error comment (POST_ERROR_COMMENTS=false)"
        return 0
    fi

    log_info "Posting error comment to $repo #$issue_or_pr_number"

    local comment_body
    comment_body=$(cat <<EOF
$(_watcher_error_header)

I encountered an issue while working on this task and couldn't complete it automatically.

**Error Details:**
\`\`\`
${error_message}
\`\`\`

**Next Steps:**
- Review the error details above
- Check the agent logs for more information
- You can re-trigger me by posting another comment that says "exclamation mark ralph" with additional context

---
*This is an automated message from $AGENT_DISPLAY_NAME.*
EOF
)

    # Post comment via gh CLI
    gh api "repos/$repo/issues/$issue_or_pr_number/comments" \
        -f body="$comment_body" \
        >/dev/null 2>&1 || log_error "Failed to post error comment"
}

# ============================================================================
# MAIN POLLING LOOP
# ============================================================================

main_loop() {
    log_info "GitHub Watcher started"
    log_info "  Repositories: $WATCHED_REPOS"
    log_info "  Poll interval: ${POLL_INTERVAL}s"

    while true; do
        log_debug "=== Starting poll cycle ==="

        # Check if agent is already running
        if is_agent_running; then
            log_debug "$AGENT_DISPLAY_NAME is working, waiting..."
            sleep 30
            continue
        fi

        log_debug "Checking for trigger mentions..."

        # Poll GitHub for trigger mentions (with error handling)
        local tasks=""
        tasks=$(find_trigger_mentions 2>/dev/null || true)

        log_debug "Poll complete, processing results..."

        if [[ -n "$tasks" ]]; then
            # Process the first unprocessed task only.
            local task=""
            local candidate
            while IFS= read -r candidate; do
                [[ -z "$candidate" ]] && continue

                local candidate_task_id
                candidate_task_id=$(task_id_for_task_json "$candidate") || continue

                if ! is_processed "$candidate_task_id"; then
                    if is_retry_blocked "$candidate_task_id"; then
                        continue
                    fi
                    task="$candidate"
                    break
                fi
            done <<< "$tasks"

            if [[ -z "$task" ]]; then
                log_debug "No new unprocessed trigger tasks in this poll cycle"
            else
                local task_type repo created_at task_id_for_reaction
                task_type=$(echo "$task" | jq -r '.type')
                repo=$(echo "$task" | jq -r '.repo')
                created_at=$(echo "$task" | jq -r '.created_at')

                case "$task_type" in
                    issue_comment|pr_review_comment)
                        local number comment_id task_id
                        number=$(echo "$task" | jq -r '.number')
                        comment_id=$(echo "$task" | jq -r '.id')
                        
                        if [[ "$task_type" == "issue_comment" ]]; then
                            task_id="issue_${number}_comment_${comment_id}"
                        else
                            task_id="pr_${number}_review_${comment_id}"
                        fi

                        # Check if the issue/PR is open
                        local is_open=false
                        if [[ "$task_type" == "issue_comment" ]] || [[ "$task_type" == "issue" ]]; then
                            if gh api "repos/$repo/issues/$number" --jq '.state' 2>/dev/null | grep -q "open"; then
                                is_open=true
                            fi
                        elif [[ "$task_type" == "pr_review_comment" ]]; then
                            if gh api "repos/$repo/pulls/$number" --jq '.state' 2>/dev/null | grep -q "open"; then
                                is_open=true
                            fi
                        fi

                        if [[ "$is_open" != "true" ]]; then
                            log_debug "Skipping $task_type #$number in $repo as it is CLOSED"
                            mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"skipped_closed\"}"
                            continue
                        fi

                        log_info "Found trigger in $task_type #$comment_id (Issue/PR #$number) from $repo"

                        if [[ "$DRY_RUN" == "true" ]]; then
                            log_info "[DRY RUN] Would process task $task_id from $repo"
                            echo "$task" > "$CURRENT_TASK_FILE"
                            continue
                        fi

                        # React to the comment to show we've started
                        add_reaction "$repo" "$task_type" "$comment_id" "eyes"

                        local context_success=false
                        if [[ "$task_type" == "issue_comment" ]] && ! gh api "repos/$repo/pulls/$number" >/dev/null 2>&1; then
                            if build_context_for_issue "$repo" "$number" "$task_type" "$comment_id" "$created_at"; then
                                context_success=true
                            fi
                        else
                            if build_context_for_pr "$repo" "$number" "$task_type" "$comment_id" "$created_at"; then
                                context_success=true
                            fi
                        fi

                        if [[ "$context_success" == "true" ]]; then
                            echo "$task" > "$CURRENT_TASK_FILE"
                            local run_start_epoch
                            run_start_epoch=$(date +%s)

                            if start_agent; then
                                wait_for_agent

                                local outcome outcome_type outcome_detail
                                outcome=$(evaluate_agent_run_outcome "$run_start_epoch")
                                outcome_type="${outcome%%:*}"
                                outcome_detail="${outcome#*:}"

                                case "$outcome_type" in
                                    success)
                                        clear_retry "$task_id"
                                        mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"trigger_created_at\":\"$created_at\",\"result\":\"completed\"}"
                                        log_info "Task $task_id completed"
                                        add_reaction "$repo" "$task_type" "$comment_id" "rocket"
                                        ;;
                                    rate_limited)
                                        log_warn "$AGENT_DISPLAY_NAME hit usage limit for $task_id, scheduling retry"
                                        post_error_comment "$repo" "$number" "Agent backend usage limit reached. I will retry this task automatically in about one hour."
                                        schedule_retry "$task_id" "$RATE_LIMIT_RETRY_SECONDS" "$outcome_detail"
                                        ;;
                                    failure|unknown)
                                        clear_retry "$task_id"
                                        log_error "$AGENT_DISPLAY_NAME failed for $task_id: $outcome_detail"
                                        post_error_comment "$repo" "$number" "$AGENT_DISPLAY_NAME exited early: $outcome_detail"
                                        mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_runtime_failed\"}"
                                        ;;
                                esac
                            else
                                log_error "Failed to start $AGENT_DISPLAY_NAME for $task_id"
                                post_error_comment "$repo" "$number" "Failed to start $AGENT_DISPLAY_NAME"
                                clear_retry "$task_id"
                                mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_start_failed\"}"
                            fi

                            # Cooldown period
                            sleep 120
                        else
                            if [[ "$HELP_REPLY_POSTED" == "true" ]]; then
                                log_info "Answered $task_type #$comment_id with the usage reply"
                                mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"replied_no_mode\"}"
                            else
                                log_error "Failed to build context for $task_type #$comment_id"
                                mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_context_failed\"}"
                            fi
                        fi
                        ;;

                    issue)
                        local issue_number task_id
                        issue_number=$(echo "$task" | jq -r '.number')
                        task_id="issue_${issue_number}"

                        # Check if the issue is open
                        if ! gh api "repos/$repo/issues/$issue_number" --jq '.state' 2>/dev/null | grep -q "open"; then
                            log_debug "Skipping Issue #$issue_number in $repo as it is CLOSED"
                            mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"skipped_closed\"}"
                            continue
                        fi

                        log_info "Found trigger in Issue #$issue_number from $repo"

                        if [[ "$DRY_RUN" == "true" ]]; then
                            log_info "[DRY RUN] Would process task $task_id from $repo"
                            echo "$task" > "$CURRENT_TASK_FILE"
                            continue
                        fi

                        # React to the issue to show we've started
                        add_reaction "$repo" "issue" "$issue_number" "eyes"

                        if build_context_for_issue "$repo" "$issue_number" "issue" "" "$created_at"; then
                            echo "$task" > "$CURRENT_TASK_FILE"
                            local run_start_epoch
                            run_start_epoch=$(date +%s)

                            if start_agent; then
                                wait_for_agent

                                local outcome outcome_type outcome_detail
                                outcome=$(evaluate_agent_run_outcome "$run_start_epoch")
                                outcome_type="${outcome%%:*}"
                                outcome_detail="${outcome#*:}"

                                case "$outcome_type" in
                                    success)
                                        clear_retry "$task_id"
                                        mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"trigger_created_at\":\"$created_at\",\"result\":\"completed\"}"
                                        log_info "Task $task_id completed"
                                        add_reaction "$repo" "issue" "$issue_number" "rocket"
                                        ;;
                                    rate_limited)
                                        log_warn "$AGENT_DISPLAY_NAME hit usage limit for $task_id, scheduling retry"
                                        post_error_comment "$repo" "$issue_number" "Agent backend usage limit reached. I will retry this task automatically in about one hour."
                                        schedule_retry "$task_id" "$RATE_LIMIT_RETRY_SECONDS" "$outcome_detail"
                                        ;;
                                    failure|unknown)
                                        clear_retry "$task_id"
                                        log_error "$AGENT_DISPLAY_NAME failed for $task_id: $outcome_detail"
                                        post_error_comment "$repo" "$issue_number" "$AGENT_DISPLAY_NAME exited early: $outcome_detail"
                                        mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_runtime_failed\"}"
                                        ;;
                                esac
                            else
                                log_error "Failed to start $AGENT_DISPLAY_NAME for $task_id"
                                post_error_comment "$repo" "$issue_number" "Failed to start $AGENT_DISPLAY_NAME"
                                clear_retry "$task_id"
                                mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_start_failed\"}"
                            fi

                            # Cooldown period
                            sleep 120
                        elif [[ "$HELP_REPLY_POSTED" == "true" ]]; then
                            log_info "Answered Issue #$issue_number with the usage reply"
                            mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"replied_no_mode\"}"
                        else
                            log_error "Failed to build context for Issue #$issue_number"
                            mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"repo\":\"$repo\",\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_context_failed\"}"
                        fi
                        ;;

                    *)
                        log_warn "Unknown task type: $task_type"
                        ;;
                esac
            fi
        fi

        # Update last poll time
        log_debug "Updating last poll time..."
        local temp_file
        temp_file=$(mktemp)

        ensure_processed_file_valid
        if jq ".last_poll = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$PROCESSED_FILE" > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$PROCESSED_FILE"
            log_debug "Last poll time updated successfully"
        else
            log_warn "Failed to update last poll time"
            rm -f "$temp_file"
        fi

        # Sleep before next poll
        log_debug "Poll cycle complete. Sleeping for ${POLL_INTERVAL}s before next poll"
        sleep "$POLL_INTERVAL"
    done
}



# ============================================================================
# COMMAND HANDLERS
# ============================================================================

cmd_start() {
    log_info "Starting GitHub watcher..."

    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi

    main_loop
}

cmd_dry_run() {
    DRY_RUN=true
    log_info "Starting GitHub watcher in DRY RUN mode (no agent execution, no processed.json updates)"

    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi

    main_loop
}

cmd_status() {
    local processed_valid=false
    local current_valid=false

    if [[ -f "$PROCESSED_FILE" ]] && jq -e . "$PROCESSED_FILE" >/dev/null 2>&1; then
        processed_valid=true
    fi

    if [[ -f "$CURRENT_TASK_FILE" ]] && jq -e . "$CURRENT_TASK_FILE" >/dev/null 2>&1; then
        current_valid=true
    fi

    echo "GitHub Watcher Status"
    echo "====================="

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        echo "Configuration: $CONFIG_FILE"
        echo "  Enabled: $WATCHER_ENABLED"
        echo "  Repos: $WATCHED_REPOS"
        echo "  Poll interval: ${POLL_INTERVAL}s"
        echo "  Agent type: ${AGENT_TYPE:-unknown}"
        echo "  Agent display name: ${AGENT_DISPLAY_NAME:-$AGENT_TYPE}"
        echo ""
    else
        echo "Configuration: Not found"
        echo ""
    fi

    if tmux has-session -t ralph-gh-watcher 2>/dev/null; then
        echo "Watcher session: RUNNING (tmux: ralph-gh-watcher)"
    else
        echo "Watcher session: NOT RUNNING"
    fi

    if is_agent_running 2>/dev/null; then
        echo "Agent status: WORKING (${AGENT_DISPLAY_NAME:-$AGENT_TYPE})"
    else
        echo "Agent status: IDLE"
    fi

    echo ""

    if [[ "$processed_valid" == "true" ]]; then
        local task_count last_poll
        task_count=$(jq '.processed | length' "$PROCESSED_FILE")
        last_poll=$(jq -r '.last_poll' "$PROCESSED_FILE")
        echo "Processed tasks: $task_count"
        echo "Last poll: $last_poll"
    elif [[ -f "$PROCESSED_FILE" ]]; then
        echo "Processed tasks: unavailable (invalid JSON in $PROCESSED_FILE)"
    fi

    if [[ "$current_valid" == "true" ]]; then
        echo ""
        echo "Current task:"
        jq '.' "$CURRENT_TASK_FILE" 2>/dev/null || echo "  (unable to parse)"
    elif [[ -f "$CURRENT_TASK_FILE" ]]; then
        echo ""
        echo "Current task: unavailable (invalid JSON in $CURRENT_TASK_FILE)"
    fi
}

cmd_queue() {
    echo "Task Queue"
    echo "=========="
    echo ""

    if [[ -f "$CURRENT_TASK_FILE" ]]; then
        echo "Current task:"
        jq '.' "$CURRENT_TASK_FILE" 2>/dev/null || echo "  None"
    else
        echo "Current task: None"
    fi

    echo ""
    echo "Processed tasks:"
    if [[ -f "$PROCESSED_FILE" ]] && jq -e . "$PROCESSED_FILE" >/dev/null 2>&1; then
        jq '.processed | to_entries[] | "\(.key): \(.value.result) (\(.value.processed_at))"' "$PROCESSED_FILE" 2>/dev/null
    else
        echo "  (none or invalid state)"
    fi
}

cmd_stop() {
    log_info "Stopping GitHub watcher..."

    if tmux has-session -t ralph-gh-watcher 2>/dev/null; then
        tmux kill-session -t ralph-gh-watcher
        log_info "GitHub watcher stopped"
    else
        log_info "GitHub watcher was not running"
    fi
}

cmd_mark_all() {
    log_info "Marking all existing trigger mentions as processed..."

    # Load configuration first so AGENT_TYPE is available when selecting the
    # agent adapter in source_watcher_helpers.
    if [[ -f "$CONFIG_FILE" ]]; then
        set -a
        source "$CONFIG_FILE"
        set +a
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Run 'foundry agent gh-watcher init <vm-name>' first"
        exit 1
    fi

    if ! source_watcher_helpers; then
        log_error "Failed to load watcher helpers"
        exit 1
    fi

    if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
        log_error "GitHub token file not found: $GITHUB_TOKEN_FILE"
        exit 1
    fi
    export GH_TOKEN
    GH_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
    if [[ -z "$GH_TOKEN" ]]; then
        log_error "GitHub token is empty in $GITHUB_TOKEN_FILE"
        exit 1
    fi

    ensure_processed_file_valid

    local tasks=""
    tasks=$(find_trigger_mentions 2>/dev/null || true)

    local count=0
    local candidate
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue

        local task_id
        task_id=$(task_id_for_task_json "$candidate") || continue

        if ! is_processed "$task_id"; then
            mark_processed "$task_id" "{\"result\":\"skipped_mark_all\",\"processed_at\":\"$(date -Iseconds)\"}"
            count=$((count + 1))
        fi
    done <<< "$tasks"

    log_info "Marked $count existing mentions as processed"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local action="${1:-start}"
    shift || true

    case "$action" in
        start)
            cmd_start "$@"
            ;;
        dry-run)
            cmd_dry_run "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        queue)
            cmd_queue "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        mark-all)
            cmd_mark_all "$@"
            ;;
        *)
            log_error "Unknown watcher action: $action"
            exit 1
            ;;
    esac
}

main "$@"
