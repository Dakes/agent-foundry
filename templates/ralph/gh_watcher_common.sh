#!/usr/bin/env bash
#
# Shared helpers for the GitHub watcher.
#

set -euo pipefail

RALPH_VARIANT_MARKER="${RALPH_VARIANT_MARKER:-/opt/foundry/ralph-agent-type}"
RALPH_VARIANT_CLAUDE_CODE="${RALPH_VARIANT_CLAUDE_CODE:-ralph-claude-code}"
RALPH_VARIANT_ORCHESTRATOR="${RALPH_VARIANT_ORCHESTRATOR:-ralph-orchestrator}"
RUN_STATUS_FILE="${RUN_STATUS_FILE:-/root/.config/gh-watcher/run-status.json}"

detect_ralph_agent_variant() {
    if [[ -f "$RALPH_VARIANT_MARKER" ]]; then
        tr -d '[:space:]' < "$RALPH_VARIANT_MARKER"
        return 0
    fi

    if [[ -d /opt/ralph ]]; then
        echo "$RALPH_VARIANT_CLAUDE_CODE"
        return 0
    fi

    if command -v ralph >/dev/null 2>&1; then
        local version
        version=$(ralph --version 2>/dev/null | head -n 1 || true)
        if echo "$version" | grep -qi "orchestrator"; then
            echo "$RALPH_VARIANT_ORCHESTRATOR"
            return 0
        fi
    fi

    echo "unknown"
}

repo_name_from_repo() {
    local repo="$1"
    echo "$repo" | cut -d'/' -f2
}

rate_limit_detected_in_text() {
    local text="$1"
    echo "$text" | grep -qiE 'hit your limit|usage limit|rate[_ -]?limit|resets .*utc|5[^a-zA-Z0-9]*hour.*limit|limit.*reached'
}

watcher_log_contains_rate_limit() {
    local log_path="$RALPH_WORKSPACE/logs/ralph-watcher.log"
    if [[ ! -f "$log_path" ]]; then
        return 1
    fi
    rate_limit_detected_in_text "$(tail -200 "$log_path" 2>/dev/null || true)"
}

write_tmux_runner_script() {
    local command="$1"

    mkdir -p "$(dirname "$RUN_STATUS_FILE")" "$RALPH_WORKSPACE/logs"

    cat > /tmp/start-ralph-watcher.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail
cd "$RALPH_WORKSPACE"
rm -f "$RUN_STATUS_FILE"
{
    ${command}
}
rc=\$?
printf '{"exit_code":%s,"finished_at":"%s"}\n' "\$rc" "\$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$RUN_STATUS_FILE"
exit "\$rc"
EOF

    chmod +x /tmp/start-ralph-watcher.sh
}

start_tmux_runner() {
    local command="$1"

    tmux kill-session -t ralph-loop 2>/dev/null || true
    write_tmux_runner_script "$command"
    tmux new-session -d -s ralph-loop "/tmp/start-ralph-watcher.sh 2>&1 | tee -a $RALPH_WORKSPACE/logs/ralph-watcher.log"
}

get_run_exit_code() {
    if [[ ! -f "$RUN_STATUS_FILE" ]]; then
        return 1
    fi

    jq -r '.exit_code // empty' "$RUN_STATUS_FILE" 2>/dev/null
}

get_latest_processed_ts() {
    local repo="$1"
    local number="$2"
    jq -r "[.processed | to_entries[] | select(.value.repo == \"$repo\" and (.value.pr_number == $number or .value.number == $number)) | .value.trigger_created_at] | sort | last // \"\"" "$PROCESSED_FILE"
}

render_issue_comments_markdown() {
    local repo="$1"
    local issue_number="$2"
    local since_ts="$3"
    local since_query=""

    if [[ -n "$since_ts" ]]; then
        since_query="?since=$since_ts"
    fi

    gh api "repos/$repo/issues/$issue_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n"' 2>/dev/null || true
}

render_pr_issue_comments_markdown() {
    local repo="$1"
    local pr_number="$2"
    local since_ts="$3"
    local since_query=""

    if [[ -n "$since_ts" ]]; then
        since_query="?since=$since_ts"
    fi

    gh api "repos/$repo/issues/$pr_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n"' 2>/dev/null || true
}

render_pr_review_comments_markdown() {
    local repo="$1"
    local pr_number="$2"
    local since_ts="$3"
    local since_query=""

    if [[ -n "$since_ts" ]]; then
        since_query="?since=$since_ts"
    fi

    # shellcheck disable=SC2016
    gh api "repos/$repo/pulls/$pr_number/comments${since_query}" \
        --jq '.[] | "**@\(.user.login)** on `\(.path):\(.position)` (\(.created_at)):\n\(.body)\n"' 2>/dev/null || true
}

build_issue_context_json() {
    local repo="$1"
    local issue_number="$2"
    local trigger_type="$3"
    local trigger_comment_id="$4"
    local trigger_created_at="$5"
    local output_file="$6"

    local issue
    issue=$(gh api "repos/$repo/issues/$issue_number" 2>/dev/null)
    if [[ -z "$issue" ]]; then
        log_error "Failed to fetch issue #$issue_number from $repo"
        return 1
    fi

    local repo_name since_ts comments labels_json
    repo_name=$(repo_name_from_repo "$repo")
    since_ts=$(get_latest_processed_ts "$repo" "$issue_number")
    comments=$(render_issue_comments_markdown "$repo" "$issue_number" "$since_ts")
    labels_json=$(echo "$issue" | jq -c '.labels | map(.name)')

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
            trigger_created_at: $trigger_created_at
        }' > "$output_file"
}

build_pr_context_json() {
    local repo="$1"
    local pr_number="$2"
    local trigger_type="$3"
    local trigger_comment_id="$4"
    local trigger_created_at="$5"
    local output_file="$6"

    local pr
    pr=$(gh api "repos/$repo/pulls/$pr_number" 2>/dev/null)
    if [[ -z "$pr" ]]; then
        log_error "Failed to fetch PR #$pr_number from $repo"
        return 1
    fi

    local repo_name since_ts issue_comments review_comments
    local linked_issue_number linked_issue_number_json linked_issue_title linked_issue_body
    repo_name=$(repo_name_from_repo "$repo")
    since_ts=$(get_latest_processed_ts "$repo" "$pr_number")
    issue_comments=$(render_pr_issue_comments_markdown "$repo" "$pr_number" "$since_ts")
    review_comments=$(render_pr_review_comments_markdown "$repo" "$pr_number" "$since_ts")
    linked_issue_number=$(echo "$pr" | jq -r '.body // ""' | grep -oP '(?:Fixes|Closes|Resolves) #\K\d+' | head -1 || true)

    linked_issue_number_json="null"
    linked_issue_title=""
    linked_issue_body=""
    if [[ -n "$linked_issue_number" ]]; then
        linked_issue_number_json="$linked_issue_number"
        local issue
        issue=$(gh api "repos/$repo/issues/$linked_issue_number" 2>/dev/null || true)
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
        --arg issue_comments "$issue_comments" \
        --arg review_comments "$review_comments" \
        --arg linked_issue_title "$linked_issue_title" \
        --arg linked_issue_body "$linked_issue_body" \
        --arg trigger_type "$trigger_type" \
        --arg trigger_comment_id "$trigger_comment_id" \
        --arg trigger_created_at "$trigger_created_at" \
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
            issue_comments: $issue_comments,
            review_comments: $review_comments,
            linked_issue_number: $linked_issue_number,
            linked_issue_title: ($linked_issue_title | if . == "" then null else . end),
            linked_issue_body: ($linked_issue_body | if . == "" then null else . end),
            trigger_type: $trigger_type,
            trigger_comment_id: ($trigger_comment_id | if . == "" then null else . end),
            trigger_created_at: $trigger_created_at
        }' > "$output_file"
}
