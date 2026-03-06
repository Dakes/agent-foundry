#!/usr/bin/env bash
#
# Ralph GitHub Watcher - Autonomous GitHub Issue/PR Monitor
#
# Polls GitHub repositories for !ralph mentions, populates fix_plan.md,
# and triggers Ralph to work autonomously on tasks.
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

# Default values (overridden by config file)
WATCHER_ENABLED="${WATCHER_ENABLED:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
WATCHED_REPOS="${WATCHED_REPOS:-}"
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-/root/.config/gh/token}"
RALPH_TIMEOUT="${RALPH_TIMEOUT:-120}"
POST_ERROR_COMMENTS="${POST_ERROR_COMMENTS:-true}"
POLL_LOOKBACK_SECONDS="${POLL_LOOKBACK_SECONDS:-900}"
DRY_RUN="${DRY_RUN:-false}"
RATE_LIMIT_RETRY_SECONDS="${RATE_LIMIT_RETRY_SECONDS:-3600}"

RALPH_WORKSPACE="/root"

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
# INITIALIZATION
# ============================================================================

init_watcher() {
    # Create config directory
    mkdir -p "$CONFIG_DIR"

    # Create empty processed.json if it doesn't exist
    if [[ ! -f "$PROCESSED_FILE" ]]; then
        cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
        log_info "Initialized processed tasks file: $PROCESSED_FILE"
    fi

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

    # Load configuration
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

    log_info "GitHub watcher initialized"
    log_info "  Watching repos: $WATCHED_REPOS"
    log_info "  Poll interval: ${POLL_INTERVAL}s"
    log_info "  Ralph workspace: $RALPH_WORKSPACE"

    return 0
}

# ============================================================================
# RALPH STATUS CHECKING
# ============================================================================

is_ralph_running() {
    tmux has-session -t ralph-loop 2>/dev/null
}

wait_for_ralph() {
    log_info "Waiting for Ralph to finish..."
    while is_ralph_running; do
        sleep 30
    done
    log_info "Ralph has finished"
}

get_ralph_failure_reason() {
    local status_file="$RALPH_WORKSPACE/.ralph/status.json"
    if [[ ! -f "$status_file" ]]; then
        return 1
    fi

    local status last_action exit_reason
    status=$(jq -r '.status // ""' "$status_file" 2>/dev/null || echo "")
    last_action=$(jq -r '.last_action // ""' "$status_file" 2>/dev/null || echo "")
    exit_reason=$(jq -r '.exit_reason // ""' "$status_file" 2>/dev/null || echo "")

    if [[ "$status" == "halted" ]]; then
        if [[ -n "$exit_reason" ]]; then
            echo "$exit_reason"
        elif [[ -n "$last_action" ]]; then
            echo "$last_action"
        else
            echo "ralph_halted"
        fi
        return 0
    fi

    return 1
}

get_latest_claude_result_file_after() {
    local start_epoch="$1"
    local logs_dir="$RALPH_WORKSPACE/.ralph/logs"
    local latest_file
    latest_file=$(
        find "$logs_dir" -maxdepth 1 -type f -name 'claude_output_*.log' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | head -1 \
            | cut -d' ' -f2-
    )

    if [[ -z "$latest_file" ]]; then
        return 1
    fi

    local mtime
    mtime=$(stat -c %Y "$latest_file" 2>/dev/null || echo "0")
    if [[ ! "$mtime" =~ ^[0-9]+$ ]] || (( mtime < start_epoch )); then
        return 1
    fi

    echo "$latest_file"
}

evaluate_ralph_outcome() {
    local run_start_epoch="$1"

    local failure_reason
    failure_reason=$(get_ralph_failure_reason || true)
    if [[ -n "$failure_reason" ]]; then
        echo "failure:$failure_reason"
        return 0
    fi

    local result_file
    result_file=$(get_latest_claude_result_file_after "$run_start_epoch" || true)
    if [[ -z "$result_file" ]]; then
        echo "unknown:no_recent_result_file"
        return 0
    fi

    if ! jq -e . "$result_file" >/dev/null 2>&1; then
        echo "unknown:invalid_result_json"
        return 0
    fi

    local is_error result_text
    is_error=$(jq -r '.is_error // false' "$result_file" 2>/dev/null || echo "false")
    result_text=$(jq -r '.result // ""' "$result_file" 2>/dev/null || echo "")

    if [[ "$is_error" == "true" ]]; then
        if echo "$result_text" | grep -qiE 'hit your limit|usage limit|rate[_ -]?limit|resets .*utc|5[^a-zA-Z0-9]*hour.*limit|limit.*reached'; then
            echo "rate_limited:claude_usage_limit"
            return 0
        fi

        echo "failure:claude_error"
        return 0
    fi

    echo "success:ok"
}

# ============================================================================
# PROCESSED TASKS TRACKING
# ============================================================================

is_processed() {
    local task_id="$1"
    jq -e ".processed.\"$task_id\"" "$PROCESSED_FILE" >/dev/null 2>&1
}

mark_processed() {
    local task_id="$1"
    local task_data="$2"

    # Update processed.json
    local temp_file
    temp_file=$(mktemp)
    jq ".processed.\"$task_id\" = $task_data | .last_poll = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" \
        "$PROCESSED_FILE" > "$temp_file"
    mv "$temp_file" "$PROCESSED_FILE"

    log_debug "Marked task $task_id as processed"
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

find_ralph_mentions() {
    local query_since
    query_since=$(get_query_since)

    log_debug "Searching for !ralph mentions (all open issues/PRs, since $query_since)"

    # Priority 1: Check recent PR/Issue comments for !ralph (use 'since' to reduce API calls)
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

    # Priority 2: Check ALL open issues for !ralph (not just updated ones)
    for repo in ${WATCHED_REPOS//,/ }; do
        log_debug "Checking all open issues in $repo"

        # Get ALL open issues and filter for !ralph
        if ! gh api "repos/$repo/issues?state=open&per_page=100" \
            --jq '.[] | select(.pull_request == null) | select(.body | test("!ralph"; "i")) | {type: "issue", repo: "'"$repo"'", number: .number, title: .title, body: .body, html_url: .html_url, user: .user.login, created_at: .created_at}' \
            2>&1; then
            log_error "Failed to check issues in $repo"
        fi
    done
}

get_latest_processed_ts() {
    local repo="$1"
    local number="$2"
    # Find the latest trigger_created_at for this repo and issue/PR number
    # We filter by both number and repo to be precise
    jq -r "[.processed | to_entries[] | select(.value.repo == \"$repo\" and (.value.pr_number == $number or .value.number == $number)) | .value.trigger_created_at] | sort | last // \"\"" "$PROCESSED_FILE"
}

# ============================================================================
# CONTEXT BUILDING
# ============================================================================

build_context_for_issue() {
    local repo="$1"
    local issue_number="$2"

    log_info "Building context for issue #$issue_number in $repo"

    # Fetch issue details
    local issue
    issue=$(gh api "repos/$repo/issues/$issue_number" 2>/dev/null)

    if [[ -z "$issue" ]]; then
        log_error "Failed to fetch issue #$issue_number from $repo"
        return 1
    fi

    local issue_title issue_body issue_url issue_user issue_labels
    issue_title=$(echo "$issue" | jq -r '.title')
    issue_body=$(echo "$issue" | jq -r '.body // "No description provided"')
    issue_url=$(echo "$issue" | jq -r '.html_url')
    issue_user=$(echo "$issue" | jq -r '.user.login')
    issue_labels=$(echo "$issue" | jq -r '.labels | map(.name) | join(", ")')

    # Extract repo name (e.g., "Dakes/core" -> "core")
    local repo_name
    repo_name=$(echo "$repo" | cut -d'/' -f2)

    # Fetch all comments (or only new ones if already processed)
    local since_ts since_query=""
    since_ts=$(get_latest_processed_ts "$repo" "$issue_number")
    if [[ -n "$since_ts" ]]; then
        since_query="?since=$since_ts"
        log_info "Only fetching comments since $since_ts"
    fi

    local comments
    comments=$(gh api "repos/$repo/issues/$issue_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n"' 2>/dev/null || echo "")

    # Build fix_plan.md
    cat > "$RALPH_WORKSPACE/.ralph/fix_plan.md" <<EOF
---
# Task from Issue #${issue_number}: ${issue_title}

## Repository Context

**Repository:** ${repo}
**Issue URL:** ${issue_url}
**Local repo path:** /root/repos/${repo_name}
**Created by:** @${issue_user}
**Labels:** ${issue_labels}

## Description

${issue_body}

## Discussion

${comments}

## Tasks

- [ ] Navigate to /root/repos/${repo_name} (or relevant repo if multi-repo change needed)
- [ ] Analyze requirements from issue description
- [ ] Implement solution in the correct repository
- [ ] Run tests and verify functionality
- [ ] Create pull request to ${repo} with "Fixes #${issue_number}" in description
- [ ] Ensure PR title and body clearly explain the changes
- [ ] **IMPORTANT**: Comment on the original issue (#${issue_number}) with a summary of your work. Start your comment with "## 🤖 Ralph - Task Completed" to identify yourself.

## Notes

- This VM may have multiple repos under /root/repos/
- Ensure changes are made in the correct repository: ${repo_name}
- If changes span multiple repos, create separate PRs for each

---
EOF

    log_info "Created fix_plan.md for issue #$issue_number"
    return 0
}

build_context_for_pr() {
    local repo="$1"
    local pr_number="$2"
    local comment_id="$3"

    log_info "Building context for PR #$pr_number in $repo (comment #$comment_id)"

    # Fetch PR details
    local pr
    pr=$(gh api "repos/$repo/pulls/$pr_number" 2>/dev/null)

    if [[ -z "$pr" ]]; then
        log_error "Failed to fetch PR #$pr_number from $repo"
        return 1
    fi

    local pr_title pr_body pr_url pr_branch pr_user
    pr_title=$(echo "$pr" | jq -r '.title')
    pr_body=$(echo "$pr" | jq -r '.body // "No description provided"')
    pr_url=$(echo "$pr" | jq -r '.html_url')
    pr_branch=$(echo "$pr" | jq -r '.head.ref')
    pr_user=$(echo "$pr" | jq -r '.user.login')

    # Extract repo name (e.g., "Dakes/core" -> "core")
    local repo_name
    repo_name=$(echo "$repo" | cut -d'/' -f2)

    # Fetch comments since last processed (if any)
    local since_ts since_query=""
    since_ts=$(get_latest_processed_ts "$repo" "$pr_number")
    if [[ -n "$since_ts" ]]; then
        since_query="?since=$since_ts"
        log_info "Only fetching comments since $since_ts"
    fi

    # Fetch all comments and review comments
    local issue_comments review_comments
    issue_comments=$(gh api "repos/$repo/issues/$pr_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n"' 2>/dev/null || echo "")
    # shellcheck disable=SC2016
    review_comments=$(gh api "repos/$repo/pulls/$pr_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** on `\(.path):\(.position)` (\(.created_at)):\n\(.body)\n"' 2>/dev/null || echo "")

    # Check for linked issues
    local linked_issue_context=""
    local linked_issue
    linked_issue=$(echo "$pr_body" | grep -oP '(?:Fixes|Closes|Resolves) #\K\d+' | head -1 || echo "")

    if [[ -n "$linked_issue" ]]; then
        local issue
        issue=$(gh api "repos/$repo/issues/$linked_issue" 2>/dev/null || echo "")

        if [[ -n "$issue" ]]; then
            local issue_title issue_body
            issue_title=$(echo "$issue" | jq -r '.title')
            issue_body=$(echo "$issue" | jq -r '.body // "No description"')

            linked_issue_context="
## Related Issue

Fixes #${linked_issue}: ${issue_title}

${issue_body}
"
        fi
    fi

    # Build fix_plan.md
    cat > "$RALPH_WORKSPACE/.ralph/fix_plan.md" <<EOF
---
# Task from PR #${pr_number}: ${pr_title}

## Repository Context

**Repository:** ${repo}
**PR URL:** ${pr_url}
**Branch:** ${pr_branch}
**Local repo path:** /root/repos/${repo_name}
**Created by:** @${pr_user}
**@ralph mentioned in comment:** #${comment_id}

## PR Description

${pr_body}

## Conversation Thread

### Issue Comments
${issue_comments}

### Review Comments (Code-level)
${review_comments}
${linked_issue_context}

## Tasks

- [ ] Navigate to /root/repos/${repo_name}
- [ ] Fetch and checkout branch \`${pr_branch}\`
- [ ] Review PR feedback and address all comments
- [ ] Make necessary code changes in the correct repository
- [ ] Run tests and verify all pass
- [ ] Push fixes to branch \`${pr_branch}\` in ${repo}
- [ ] **IMPORTANT**: Comment on the PR with a summary of changes made. Start your comment with "## 🤖 Ralph - Task Completed" to identify yourself.

## Notes

- This VM may have multiple repos under /root/repos/
- Ensure changes are made in the correct repository: ${repo_name}
- Push changes to the existing branch: ${pr_branch}

---
EOF

    log_info "Created fix_plan.md for PR #$pr_number"
    return 0
}

# ============================================================================
# RALPH EXECUTION
# ============================================================================

start_ralph() {
    log_info "Starting Ralph with ${RALPH_TIMEOUT}-minute timeout..."

    cd "$RALPH_WORKSPACE" || {
        log_error "Failed to change directory to $RALPH_WORKSPACE"
        return 1
    }

    # Ensure stale loop session does not block startup.
    tmux kill-session -t ralph-loop 2>/dev/null || true

    # If the circuit breaker is open from prior runs, reset it before a new task.
    ralph --reset-circuit >/dev/null 2>&1 || true

    # Start Ralph in tmux (will run in background)
    tmux new-session -d -s ralph-loop "ralph --monitor --timeout $RALPH_TIMEOUT 2>&1 | tee -a logs/ralph-watcher.log"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Ralph started successfully in tmux session 'ralph-loop'"
        return 0
    else
        log_error "Failed to start Ralph tmux session"
        return 1
    fi
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
## 🤖 Ralph - Task Update (Error)

I encountered an issue while working on this task and couldn't complete it automatically.

**Error Details:**
\`\`\`
${error_message}
\`\`\`

**Next Steps:**
- Review the error details above
- Check the Ralph logs for more information
- You can re-trigger me by posting another \`!ralph\` comment with additional context

---
*This is an automated message from Ralph, your autonomous development agent.*
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

        # Check if Ralph is already running
        if is_ralph_running; then
            log_debug "Ralph is working, waiting..."
            sleep 30
            continue
        fi

        log_debug "Checking for !ralph mentions..."

        # Poll GitHub for !ralph mentions (with error handling)
        local tasks=""
        tasks=$(find_ralph_mentions 2>/dev/null || true)

        log_debug "Poll complete, processing results..."

        if [[ -n "$tasks" ]]; then
            # Process the first unprocessed task only.
            # Avoid missing new tasks when the first returned comment was already handled.
            local task=""
            local candidate
            while IFS= read -r candidate; do
                [[ -z "$candidate" ]] && continue

                local candidate_type candidate_number candidate_id candidate_task_id
                candidate_type=$(echo "$candidate" | jq -r '.type')
                candidate_number=$(echo "$candidate" | jq -r '.number')
                candidate_id=$(echo "$candidate" | jq -r '.id // empty')

                case "$candidate_type" in
                    issue_comment)
                        candidate_task_id="issue_${candidate_number}_comment_${candidate_id}"
                        ;;
                    pr_review_comment)
                        candidate_task_id="pr_${candidate_number}_review_${candidate_id}"
                        ;;
                    issue)
                        candidate_task_id="issue_${candidate_number}"
                        ;;
                    *)
                        continue
                        ;;
                esac

                if ! is_processed "$candidate_task_id"; then
                    if is_retry_blocked "$candidate_task_id"; then
                        continue
                    fi
                    task="$candidate"
                    break
                fi
            done <<< "$tasks"

            if [[ -z "$task" ]]; then
                log_debug "No new unprocessed !ralph tasks in this poll cycle"
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

                        log_info "Found !ralph in $task_type #$comment_id (Issue/PR #$number) from $repo"

                        if [[ "$DRY_RUN" == "true" ]]; then
                            log_info "[DRY RUN] Would process task $task_id from $repo"
                            echo "$task" > "$CURRENT_TASK_FILE"
                            continue
                        fi

                        # React to the comment to show we've started
                        add_reaction "$repo" "$task_type" "$comment_id" "eyes"

                        local context_success=false
                        if [[ "$task_type" == "issue_comment" ]] && ! gh api "repos/$repo/pulls/$number" >/dev/null 2>&1; then
                            # It's a comment on a regular issue
                            if build_context_for_issue "$repo" "$number"; then
                                context_success=true
                            fi
                        else
                            # It's a comment on a PR (conversation or review)
                            if build_context_for_pr "$repo" "$number" "$comment_id"; then
                                context_success=true
                            fi
                        fi

                        if [[ "$context_success" == "true" ]]; then
                            echo "$task" > "$CURRENT_TASK_FILE"
                            local run_start_epoch
                            run_start_epoch=$(date +%s)

                            if start_ralph; then
                                wait_for_ralph

                                local outcome outcome_type outcome_detail
                                outcome=$(evaluate_ralph_outcome "$run_start_epoch")
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
                                        log_warn "Ralph hit usage limit for $task_id, scheduling retry"
                                        post_error_comment "$repo" "$number" "Claude usage limit reached. I will retry this task automatically in about one hour."
                                        schedule_retry "$task_id" "$RATE_LIMIT_RETRY_SECONDS" "$outcome_detail"
                                        ;;
                                    failure|unknown)
                                        clear_retry "$task_id"
                                        log_error "Ralph failed for $task_id: $outcome_detail"
                                        post_error_comment "$repo" "$number" "Ralph exited early: $outcome_detail"
                                        mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_runtime_failed\"}"
                                        ;;
                                esac
                            else
                                log_error "Failed to start Ralph for $task_id"
                                post_error_comment "$repo" "$number" "Failed to start Ralph"
                                clear_retry "$task_id"
                                mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_start_failed\"}"
                            fi

                            # Cooldown period
                            sleep 120
                        else
                            log_error "Failed to build context for $task_type #$comment_id"
                            mark_processed "$task_id" "{\"type\":\"$task_type\",\"number\":$number,\"comment_id\":$comment_id,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_context_failed\"}"
                        fi
                        ;;

                    issue)
                        local issue_number task_id
                        issue_number=$(echo "$task" | jq -r '.number')
                        task_id="issue_${issue_number}"

                        log_info "Found !ralph in Issue #$issue_number from $repo"

                        if [[ "$DRY_RUN" == "true" ]]; then
                            log_info "[DRY RUN] Would process task $task_id from $repo"
                            echo "$task" > "$CURRENT_TASK_FILE"
                            continue
                        fi

                        # React to the issue to show we've started
                        add_reaction "$repo" "issue" "$issue_number" "eyes"

                        if build_context_for_issue "$repo" "$issue_number"; then
                            echo "$task" > "$CURRENT_TASK_FILE"
                            local run_start_epoch
                            run_start_epoch=$(date +%s)

                            if start_ralph; then
                                wait_for_ralph

                                local outcome outcome_type outcome_detail
                                outcome=$(evaluate_ralph_outcome "$run_start_epoch")
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
                                        log_warn "Ralph hit usage limit for $task_id, scheduling retry"
                                        post_error_comment "$repo" "$issue_number" "Claude usage limit reached. I will retry this task automatically in about one hour."
                                        schedule_retry "$task_id" "$RATE_LIMIT_RETRY_SECONDS" "$outcome_detail"
                                        ;;
                                    failure|unknown)
                                        clear_retry "$task_id"
                                        log_error "Ralph failed for $task_id: $outcome_detail"
                                        post_error_comment "$repo" "$issue_number" "Ralph exited early: $outcome_detail"
                                        mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_runtime_failed\"}"
                                        ;;
                                esac
                            else
                                log_error "Failed to start Ralph for $task_id"
                                post_error_comment "$repo" "$issue_number" "Failed to start Ralph"
                                clear_retry "$task_id"
                                mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_start_failed\"}"
                            fi

                            # Cooldown period
                            sleep 120
                        else
                            log_error "Failed to build context for Issue #$issue_number"
                            mark_processed "$task_id" "{\"type\":\"issue\",\"number\":$issue_number,\"processed_at\":\"$(date -Iseconds)\",\"result\":\"error_context_failed\"}"
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
    log_info "Starting GitHub watcher in DRY RUN mode (no Ralph execution, no processed.json updates)"

    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi

    main_loop
}

cmd_status() {
    echo "GitHub Watcher Status"
    echo "====================="

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        echo "Configuration: $CONFIG_FILE"
        echo "  Enabled: $WATCHER_ENABLED"
        echo "  Repos: $WATCHED_REPOS"
        echo "  Poll interval: ${POLL_INTERVAL}s"
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

    if is_ralph_running; then
        echo "Ralph status: WORKING"
    else
        echo "Ralph status: IDLE"
    fi

    echo ""

    if [[ -f "$PROCESSED_FILE" ]]; then
        local task_count last_poll
        task_count=$(jq '.processed | length' "$PROCESSED_FILE")
        last_poll=$(jq -r '.last_poll' "$PROCESSED_FILE")
        echo "Processed tasks: $task_count"
        echo "Last poll: $last_poll"
    fi

    if [[ -f "$CURRENT_TASK_FILE" ]]; then
        echo ""
        echo "Current task:"
        jq '.' "$CURRENT_TASK_FILE" 2>/dev/null || echo "  (unable to parse)"
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
    if [[ -f "$PROCESSED_FILE" ]]; then
        jq -r '.processed | to_entries | .[] | "\(.key): \(.value.result) at \(.value.processed_at)"' "$PROCESSED_FILE" | tail -10
    else
        echo "  None"
    fi
}

cmd_scan() {
    if ! init_watcher; then
        log_error "Failed to initialize watcher"
        exit 1
    fi

    local tasks
    tasks=$(find_ralph_mentions 2>/dev/null || true)

    if [[ -z "$tasks" ]]; then
        echo "No !ralph mentions found"
        return 0
    fi

    while IFS= read -r task; do
        [[ -z "$task" ]] && continue

        local task_type number id task_id processed
        task_type=$(echo "$task" | jq -r '.type')
        number=$(echo "$task" | jq -r '.number')
        id=$(echo "$task" | jq -r '.id // empty')

        case "$task_type" in
            pr_comment)
                task_id="pr_${number}_comment_${id}"
                ;;
            issue_comment)
                task_id="issue_${number}_comment_${id}"
                ;;
            issue)
                task_id="issue_${number}"
                ;;
            *)
                task_id="unknown"
                ;;
        esac

        if is_processed "$task_id"; then
            processed=true
        else
            processed=false
        fi

        echo "$task" | jq --arg task_id "$task_id" --argjson already_processed "$processed" \
            '. + {task_id: $task_id, already_processed: $already_processed}'
    done <<< "$tasks"
}

cmd_stop() {
    echo "Stopping GitHub watcher..."

    if tmux has-session -t ralph-gh-watcher 2>/dev/null; then
        tmux kill-session -t ralph-gh-watcher
        echo "Watcher stopped"
    else
        echo "Watcher is not running"
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    local command="${1:-start}"

    case "$command" in
        start)
            cmd_start
            ;;
        dry-run)
            cmd_dry_run
            ;;
        status)
            cmd_status
            ;;
        queue)
            cmd_queue
            ;;
        scan)
            cmd_scan
            ;;
        stop)
            cmd_stop
            ;;
        *)
            echo "Usage: $0 {start|dry-run|status|queue|scan|stop}"
            echo ""
            echo "Commands:"
            echo "  start   - Start the GitHub watcher daemon"
            echo "  dry-run - Start watcher loop without executing Ralph or marking tasks processed"
            echo "  status  - Show watcher status"
            echo "  queue   - Show task queue and history"
            echo "  scan    - Print detected !ralph tasks without starting Ralph"
            echo "  stop    - Stop the watcher daemon"
            exit 1
            ;;
    esac
}

# Run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
