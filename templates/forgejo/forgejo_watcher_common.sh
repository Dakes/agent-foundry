#!/usr/bin/env bash
#
# Shared helpers for the Forgejo watcher.
#

set -euo pipefail

# Paths and defaults (overridden by config file or environment)
CONFIG_DIR="${CONFIG_DIR:-/root/.config/forgejo-watcher}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.conf}"
PROCESSED_FILE="${PROCESSED_FILE:-$CONFIG_DIR/processed.json}"
RETRY_FILE="${RETRY_FILE:-$CONFIG_DIR/retries.json}"
QUEUE_DIR="${QUEUE_DIR:-$CONFIG_DIR/queue}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/watcher.log}"
RUN_STATUS_FILE="${RUN_STATUS_FILE:-$CONFIG_DIR/run-status.json}"

FORGEJO_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-}"
FORGEJO_TOKEN_FILE="${FORGEJO_TOKEN_FILE:-$CONFIG_DIR/token}"
FORGEJO_TOKEN="${FORGEJO_TOKEN:-}"
WEBHOOK_SECRET_FILE="${WEBHOOK_SECRET_FILE:-$CONFIG_DIR/webhook-secret}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
TRIGGER_KEYWORD="${TRIGGER_KEYWORD:-!ralph}"
WATCHED_REPOS="${WATCHED_REPOS:-}"
AGENT_TYPE="${AGENT_TYPE:-}"
AGENT_WORKSPACE="${AGENT_WORKSPACE:-/root}"
POST_ERROR_COMMENTS="${POST_ERROR_COMMENTS:-true}"
DRY_RUN="${DRY_RUN:-false}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# Legacy / shared variables used by adapters
RALPH_WORKSPACE="$AGENT_WORKSPACE"
KIMI_WORKSPACE="$AGENT_WORKSPACE"

# ============================================================================
# AGENT RUNNER HELPERS
# ============================================================================

rate_limit_detected_in_text() {
    local text="$1"
    echo "$text" | grep -qiE 'hit your limit|usage limit|rate[_ -]?limit|resets .*utc|5[^a-zA-Z0-9]*hour.*limit|limit.*reached'
}

watcher_log_contains_rate_limit() {
    local log_path="$AGENT_WORKSPACE/logs/agent-watcher.log"
    if [[ ! -f "$log_path" ]]; then
        return 1
    fi
    rate_limit_detected_in_text "$(tail -200 "$log_path" 2>/dev/null || true)"
}

write_tmux_runner_script() {
    local command="$1"

    mkdir -p "$(dirname "$RUN_STATUS_FILE")" "$AGENT_WORKSPACE/logs"

    cat > /tmp/start-agent-watcher.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

# Ensure the Kimi Code CLI binary is on PATH.
export PATH="/root/.kimi-code/bin:/root/.local/bin:/usr/local/bin:\$PATH"

# Initialize NVM if it exists
export NVM_DIR="/root/.nvm"
if [[ -s "\$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "\$NVM_DIR/nvm.sh"
    # Use default node version
    nvm use default >/dev/null 2>&1 || true
fi

cd "$AGENT_WORKSPACE"
rm -f "$RUN_STATUS_FILE"
set +e
{
$command
}
rc=\$?
set -e
printf '{"exit_code":%s,"finished_at":"%s"}\n' "\$rc" "\$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$RUN_STATUS_FILE"
exit "\$rc"
EOF

    chmod +x /tmp/start-agent-watcher.sh
}

start_tmux_runner() {
    local command="$1"

    tmux kill-session -t ralph-loop 2>/dev/null || true
    write_tmux_runner_script "$command"
    tmux new-session -d -s ralph-loop "/tmp/start-agent-watcher.sh 2>&1 | tee -a $AGENT_WORKSPACE/logs/agent-watcher.log"
}

get_run_exit_code() {
    if [[ ! -f "$RUN_STATUS_FILE" ]]; then
        return 1
    fi

    jq -r '.exit_code // empty' "$RUN_STATUS_FILE" 2>/dev/null
}

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
# CONFIG LOADING
# ============================================================================

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        set +a
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    if [[ -z "${FORGEJO_TOKEN:-}" && -f "$FORGEJO_TOKEN_FILE" ]]; then
        FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
    fi

    if [[ -z "${WEBHOOK_SECRET:-}" && -f "$WEBHOOK_SECRET_FILE" ]]; then
        WEBHOOK_SECRET=$(cat "$WEBHOOK_SECRET_FILE")
    fi

    return 0
}

# ============================================================================
# FORGEJO API CLIENT
# ============================================================================

forgejo_api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    if [[ -z "$FORGEJO_INSTANCE_URL" ]]; then
        log_error "FORGEJO_INSTANCE_URL is not configured"
        return 1
    fi

    local url="${FORGEJO_INSTANCE_URL%/}/api/v1/${endpoint#/}"
    local curl_opts=( -s -S -L -w "\n%{http_code}" )

    curl_opts+=( -H "Accept: application/json" )
    curl_opts+=( -H "Content-Type: application/json" )

    if [[ -n "$FORGEJO_TOKEN" ]]; then
        curl_opts+=( -H "Authorization: token $FORGEJO_TOKEN" )
    fi

    if [[ "$method" != "GET" ]]; then
        curl_opts+=( -X "$method" )
    fi

    local response status body
    response=$(curl "${curl_opts[@]}" "$url" "$@" 2>&1) || {
        log_error "Forgejo API request failed: $url"
        return 1
    }

    status=$(printf '%s\n' "$response" | tail -n 1)
    body=$(printf '%s\n' "$response" | sed '$d')

    if [[ -z "$status" || ! "$status" =~ ^[0-9]+$ ]]; then
        log_error "Forgejo API returned invalid status for $url"
        printf '%s\n' "$body"
        return 1
    fi

    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
        log_error "Forgejo API error $status for $url: $body"
        printf '%s\n' "$body"
        return 1
    fi

    printf '%s\n' "$body"
}

forgejo_get() {
    forgejo_api_call GET "$@"
}

forgejo_post() {
    forgejo_api_call POST "$@" -d "@-"
}

forgejo_patch() {
    forgejo_api_call PATCH "$@" -d "@-"
}

forgejo_delete() {
    forgejo_api_call DELETE "$@"
}

# ============================================================================
# REPO HELPERS
# ============================================================================

split_repo() {
    local repo="$1"
    local owner part
    owner=$(printf '%s' "$repo" | cut -d'/' -f1)
    part=$(printf '%s' "$repo" | cut -d'/' -f2-)
    printf '%s %s' "$owner" "$part"
}

repo_name_from_repo() {
    local repo="$1"
    printf '%s' "$repo" | cut -d'/' -f2
}

# ============================================================================
# STATE FILES
# ============================================================================

ensure_processed_file_valid() {
    if [[ ! -f "$PROCESSED_FILE" ]] || [[ ! -s "$PROCESSED_FILE" ]]; then
        mkdir -p "$(dirname "$PROCESSED_FILE")"
        cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
    elif ! jq -e '.processed' "$PROCESSED_FILE" >/dev/null 2>&1; then
        cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
    fi
}

ensure_retry_file_valid() {
    if [[ ! -f "$RETRY_FILE" ]] || [[ ! -s "$RETRY_FILE" ]]; then
        mkdir -p "$(dirname "$RETRY_FILE")"
        cat > "$RETRY_FILE" <<'EOF'
{
  "version": "1.0",
  "retries": {}
}
EOF
    fi
}

parent_task_id() {
    local task_id="$1"
    case "$task_id" in
        issue_*_comment_*)
            echo "${task_id%%_comment_*}"
            ;;
        pr_*_review_*)
            echo "${task_id%%_review_*}"
            ;;
        *)
            echo "$task_id"
            ;;
    esac
}

is_processed() {
    local task_id="$1"
    ensure_processed_file_valid
    jq -e ".processed.\"$task_id\"" "$PROCESSED_FILE" >/dev/null 2>&1
}

mark_processed() {
    local task_id="$1"
    local task_data="$2"
    ensure_processed_file_valid
    local temp_file
    temp_file=$(mktemp)
    jq ".processed.\"$task_id\" = $task_data" "$PROCESSED_FILE" > "$temp_file" 2>/dev/null || {
        rm -f "$temp_file"
        log_warn "Failed to mark task $task_id as processed"
        return 1
    }
    mv "$temp_file" "$PROCESSED_FILE"
    log_debug "Marked task $task_id as processed"
}

clear_retry() {
    local task_id="$1"
    ensure_retry_file_valid
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

    ensure_retry_file_valid
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

# ============================================================================
# REACTIONS & COMMENTS
# ============================================================================

add_reaction() {
    local repo="$1"
    local type="$2" # issue, issue_comment, pr_review_comment
    local id="$3"
    local emoji="${4:-eyes}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would add $emoji reaction to $type $id in $repo"
        return 0
    fi

    log_debug "Adding $emoji reaction to $type $id in $repo"

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    case "$type" in
        issue)
            forgejo_post "repos/$owner/$part/issues/$id/reactions" <<< "{\"content\":\"$emoji\"}" >/dev/null 2>&1 || true
            ;;
        issue_comment)
            forgejo_post "repos/$owner/$part/issues/comments/$id/reactions" <<< "{\"content\":\"$emoji\"}" >/dev/null 2>&1 || true
            ;;
        pr_review_comment)
            forgejo_post "repos/$owner/$part/pulls/comments/$id/reactions" <<< "{\"content\":\"$emoji\"}" >/dev/null 2>&1 || true
            ;;
    esac
}

# Error-comment header.
#
# Delegates to the prompt library so identity resolves the same way it does in
# the completion header - including the agent_identity_name() registry
# fallback, which a hand-rolled ${AGENT_IDENTITY:-${AGENT_DISPLAY_NAME}} chain
# skips. A second copy of identity resolution is how the five spellings of one
# name came back last time.
_watcher_error_header() {
    if declare -F foundry_error_header >/dev/null; then
        foundry_error_header
        return 0
    fi
    # identity-fallback: only reached when prompt-lib.sh was not sourced
    printf '## 🤖 %s - Task Update (Error)' "${AGENT_IDENTITY:-${AGENT_DISPLAY_NAME:-Agent}}"
}

# Post a pre-rendered comment body verbatim.
#
# Used for the no-mode-stated reply, which the prompt library writes in full:
# it is not an error, so it must not be wrapped in the error template, and it
# is hardcoded text that no agent was started to produce.
post_reply_file() {
    local repo="$1"
    local issue_or_pr_number="$2"
    local reply_file="$3"

    [[ -s "$reply_file" ]] || { log_error "No reply to post: $reply_file"; return 1; }

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would post reply to $repo #$issue_or_pr_number"
        return 0
    fi

    log_info "Posting reply to $repo #$issue_or_pr_number"
    forgejo_post "repos/$owner/$part/issues/$issue_or_pr_number/comments" \
        <<< "$(jq -n --arg body "$(cat "$reply_file")" '{body: $body}')" \
        >/dev/null 2>&1 || log_error "Failed to post reply"
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

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    local comment_body
    comment_body=$(cat <<EOF
$(_watcher_error_header)

I encountered an issue while working on this task and couldn't complete it automatically.

**Error Details:**
\`\`\`
$error_message
\`\`\`

**Next Steps:**
- Review the error details above
- Check the agent logs for more information
- Re-trigger me by posting another comment containing the trigger keyword

---
*This is an automated message from ${AGENT_TYPE:-Agent}.*
EOF
)

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would post error comment to $repo #$issue_or_pr_number"
        return 0
    fi

    forgejo_post "repos/$owner/$part/issues/$issue_or_pr_number/comments" <<< "$(jq -n --arg body "$comment_body" '{body: $body}')" >/dev/null 2>&1 || log_error "Failed to post error comment"
}

# ============================================================================
# CONTEXT BUILDING
# ============================================================================

get_latest_processed_ts() {
    local repo="$1"
    local number="$2"
    jq -r "[.processed | to_entries[] | select(.value.repo == \"$repo\" and (.value.pr_number == $number or .value.number == $number)) | .value.trigger_created_at] | sort | last // \"\"" "$PROCESSED_FILE"
}

render_issue_comments_json() {
    local owner="$1"
    local repo="$2"
    local issue_number="$3"

    forgejo_get "repos/$owner/$repo/issues/$issue_number/comments" 2>/dev/null | \
        jq '[.[] | {
            comment_type: "issue_comment",
            id: .id,
            created_at: .created_at,
            body: (.body // ""),
            user: .user.login,
            markdown: ("**@" + .user.login + "** (" + .created_at + "):\n" + (.body // "") + "\n")
        }]' 2>/dev/null || echo '[]'
}

render_pr_review_comments_json() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"

    forgejo_get "repos/$owner/$repo/pulls/$pr_number/comments" 2>/dev/null | \
        jq '[.[] | {
            comment_type: "pr_review_comment",
            id: .id,
            created_at: .created_at,
            body: (.body // ""),
            user: .user.login,
            path: (.path // ""),
            position: (.position // "n/a"),
            markdown: ("**@" + .user.login + "** on `" + (.path // "unknown") + ":" + ((.position // "n/a") | tostring) + "` (" + .created_at + "):\n" + (.body // "") + "\n")
        }]' 2>/dev/null || echo '[]'
}

select_recent_or_new_comments_markdown() {
    local comments_json="$1"
    local since_ts="$2"

    if [[ -z "$comments_json" ]]; then
        echo ""
        return 0
    fi

    jq -r --arg since "$since_ts" '
        (. // []) as $all
        | ($all | sort_by(.created_at)) as $sorted
        | if $since == "" then
            $sorted
          else
            ($sorted | map(select(.created_at > $since))) as $new
            | if ($new | length) > 0 then $new else ($sorted | reverse | .[:4] | reverse) end
          end
        | map(.markdown)
        | join("\n")
    ' <<< "$comments_json"
}

render_issue_comments_markdown() {
    local owner="$1"
    local repo="$2"
    local issue_number="$3"
    local since_ts="$4"
    local comments_json

    comments_json=$(render_issue_comments_json "$owner" "$repo" "$issue_number")
    select_recent_or_new_comments_markdown "$comments_json" "$since_ts"
}

render_pr_conversation_markdown() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local since_ts="$4"
    local issue_comments_json review_comments_json combined_json

    issue_comments_json=$(render_issue_comments_json "$owner" "$repo" "$pr_number")
    review_comments_json=$(render_pr_review_comments_json "$owner" "$repo" "$pr_number")
    combined_json=$(jq -cs '.[0] + .[1]' \
        <(printf '%s\n' "$issue_comments_json") \
        <(printf '%s\n' "$review_comments_json"))

    select_recent_or_new_comments_markdown "$combined_json" "$since_ts"
}

fetch_trigger_comment_body() {
    local owner="$1"
    local repo="$2"
    local trigger_type="$3"
    local trigger_comment_id="$4"

    if [[ -z "$trigger_comment_id" ]]; then
        echo ""
        return 0
    fi

    case "$trigger_type" in
        issue_comment)
            forgejo_get "repos/$owner/$repo/issues/comments/$trigger_comment_id" 2>/dev/null | jq -r '.body // ""' || true
            ;;
        pr_review_comment)
            forgejo_get "repos/$owner/$repo/pulls/comments/$trigger_comment_id" 2>/dev/null | jq -r '.body // ""' || true
            ;;
        *)
            echo ""
            ;;
    esac
}

build_issue_context_json() {
    local repo="$1"
    local issue_number="$2"
    local trigger_type="$3"
    local trigger_comment_id="$4"
    local trigger_created_at="$5"
    local output_file="$6"

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    local issue
    issue=$(forgejo_get "repos/$owner/$part/issues/$issue_number" 2>/dev/null)
    if [[ -z "$issue" ]]; then
        log_error "Failed to fetch issue #$issue_number from $repo"
        return 1
    fi

    local repo_name since_ts comments labels_json trigger_body
    repo_name=$(repo_name_from_repo "$repo")
    ensure_processed_file_valid
    since_ts=$(get_latest_processed_ts "$repo" "$issue_number")
    comments=$(render_issue_comments_markdown "$owner" "$part" "$issue_number" "$since_ts")
    labels_json=$(echo "$issue" | jq -c '.labels | map(.name)')
    trigger_body=$(fetch_trigger_comment_body "$owner" "$part" "$trigger_type" "$trigger_comment_id")
    if [[ -z "$trigger_body" && "$trigger_type" == "issue" ]]; then
        trigger_body=$(echo "$issue" | jq -r '.body // "No description provided"')
    fi

    jq -n \
        --arg kind "issue" \
        --arg repo "$repo" \
        --arg repo_name "$repo_name" \
        --arg title "$(echo "$issue" | jq -r '.title')" \
        --arg body "$(echo "$issue" | jq -r '.body // "No description provided"')" \
        --arg html_url "$(echo "$issue" | jq -r '.html_url')" \
        --arg user "$(echo "$issue" | jq -r '.user.login')" \
        --arg discussion "$comments" \
        --arg trigger_type "$trigger_type" \
        --arg trigger_comment_id "$trigger_comment_id" \
        --arg trigger_created_at "$trigger_created_at" \
        --arg trigger_body "$trigger_body" \
        --argjson number "$issue_number" \
        --argjson labels "$labels_json" \
        '{
            kind: $kind,
            repo: $repo,
            repo_name: $repo_name,
            number: $number,
            title: $title,
            body: $body,
            html_url: $html_url,
            user: $user,
            labels: $labels,
            discussion: $discussion,
            trigger_type: $trigger_type,
            trigger_comment_id: ($trigger_comment_id | if . == "" then null else . end),
            trigger_created_at: $trigger_created_at,
            trigger_body: ($trigger_body | if . == "" then null else . end)
        }' > "$output_file"
}

build_pr_context_json() {
    local repo="$1"
    local pr_number="$2"
    local trigger_type="$3"
    local trigger_comment_id="$4"
    local trigger_created_at="$5"
    local output_file="$6"

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    local pr
    pr=$(forgejo_get "repos/$owner/$part/pulls/$pr_number" 2>/dev/null)
    if [[ -z "$pr" ]]; then
        log_error "Failed to fetch PR #$pr_number from $repo"
        return 1
    fi

    local repo_name since_ts conversation trigger_body
    local linked_issue_number linked_issue_number_json linked_issue_title linked_issue_body
    repo_name=$(repo_name_from_repo "$repo")
    ensure_processed_file_valid
    since_ts=$(get_latest_processed_ts "$repo" "$pr_number")
    conversation=$(render_pr_conversation_markdown "$owner" "$part" "$pr_number" "$since_ts")
    trigger_body=$(fetch_trigger_comment_body "$owner" "$part" "$trigger_type" "$trigger_comment_id")
    linked_issue_number=$(echo "$pr" | jq -r '.body // ""' | grep -oP '(?:Fixes|Closes|Resolves) #\K\d+' | head -1 || true)

    linked_issue_number_json="null"
    linked_issue_title=""
    linked_issue_body=""
    if [[ -n "$linked_issue_number" ]]; then
        linked_issue_number_json="$linked_issue_number"
        local issue
        issue=$(forgejo_get "repos/$owner/$part/issues/$linked_issue_number" 2>/dev/null || true)
        if [[ -n "$issue" ]]; then
            linked_issue_title=$(echo "$issue" | jq -r '.title')
            linked_issue_body=$(echo "$issue" | jq -r '.body // "No description"')
        fi
    fi

    jq -n \
        --arg kind "pr" \
        --arg repo "$repo" \
        --arg repo_name "$repo_name" \
        --arg title "$(echo "$pr" | jq -r '.title')" \
        --arg body "$(echo "$pr" | jq -r '.body // "No description provided"')" \
        --arg html_url "$(echo "$pr" | jq -r '.html_url')" \
        --arg user "$(echo "$pr" | jq -r '.user.login')" \
        --arg branch "$(echo "$pr" | jq -r '.head.ref')" \
        --arg conversation "$conversation" \
        --arg linked_issue_title "$linked_issue_title" \
        --arg linked_issue_body "$linked_issue_body" \
        --arg trigger_type "$trigger_type" \
        --arg trigger_comment_id "$trigger_comment_id" \
        --arg trigger_created_at "$trigger_created_at" \
        --arg trigger_body "$trigger_body" \
        --argjson number "$pr_number" \
        --argjson linked_issue_number "$linked_issue_number_json" \
        '{
            kind: $kind,
            repo: $repo,
            repo_name: $repo_name,
            number: $number,
            title: $title,
            body: $body,
            html_url: $html_url,
            user: $user,
            branch: $branch,
            conversation: $conversation,
            linked_issue_number: $linked_issue_number,
            linked_issue_title: ($linked_issue_title | if . == "" then null else . end),
            linked_issue_body: ($linked_issue_body | if . == "" then null else . end),
            trigger_type: $trigger_type,
            trigger_comment_id: ($trigger_comment_id | if . == "" then null else . end),
            trigger_created_at: $trigger_created_at,
            trigger_body: ($trigger_body | if . == "" then null else . end)
        }' > "$output_file"
}

build_pipeline_failure_context_json() {
    local task_json="$1"
    local output_file="$2"

    local repo run_id name conclusion branch sha html_url created_at
    repo=$(echo "$task_json" | jq -r '.repo')
    run_id=$(echo "$task_json" | jq -r '.run_id')
    name=$(echo "$task_json" | jq -r '.name')
    conclusion=$(echo "$task_json" | jq -r '.conclusion')
    branch=$(echo "$task_json" | jq -r '.branch')
    sha=$(echo "$task_json" | jq -r '.sha')
    html_url=$(echo "$task_json" | jq -r '.html_url')
    created_at=$(echo "$task_json" | jq -r '.created_at')

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    local repo_name jobs_json jobs_md
    repo_name=$(repo_name_from_repo "$repo")
    jobs_md=""

    # Try to fetch the run's job list and failed steps.
    # Forgejo/Gitea Actions expose /actions/runs/{run_id}/jobs.
    jobs_json=$(forgejo_get "repos/$owner/$part/actions/runs/$run_id/jobs" 2>/dev/null || true)
    if [[ -n "$jobs_json" ]] && echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        jobs_md=$(echo "$jobs_json" | jq -r '
            .jobs // [] | map(
                "### Job: " + (.name // "unknown") + " (status: " + (.status // "unknown") + ", conclusion: " + (.conclusion // "unknown") + ")" +
                "\n\n" +
                ((.steps // []) | map(
                    select(.conclusion == "failure") |
                    "- Failed step: " + (.name // "unknown") + " (" + (.conclusion // "unknown") + ")"
                ) | join("\n"))
            ) | join("\n\n")
        ')
    fi

    if [[ -z "$jobs_md" ]]; then
        jobs_md="No detailed job information could be retrieved. Please inspect the run URL directly."
    fi

    local clone_url
    clone_url="${FORGEJO_INSTANCE_URL%/}/$repo.git"

    jq -n \
        --arg kind "pipeline_failure" \
        --arg repo "$repo" \
        --arg repo_name "$repo_name" \
        --arg run_id "$run_id" \
        --arg name "$name" \
        --arg conclusion "$conclusion" \
        --arg branch "$branch" \
        --arg sha "$sha" \
        --arg html_url "$html_url" \
        --arg created_at "$created_at" \
        --arg clone_url "$clone_url" \
        --arg jobs_md "$jobs_md" \
        '{
            kind: $kind,
            repo: $repo,
            repo_name: $repo_name,
            run_id: $run_id,
            name: $name,
            conclusion: $conclusion,
            branch: $branch,
            sha: $sha,
            html_url: $html_url,
            created_at: $created_at,
            clone_url: $clone_url,
            jobs_md: $jobs_md
        }' > "$output_file"
}
