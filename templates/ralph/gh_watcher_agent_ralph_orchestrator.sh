#!/usr/bin/env bash
#
# Adapter for mikeyobrien/ralph-orchestrator watcher tasks.
#

set -euo pipefail

ORCHESTRATOR_WATCHER_PROMPT="${ORCHESTRATOR_WATCHER_PROMPT:-$RALPH_WORKSPACE/.ralph/gh_task_prompt.md}"

prepare_ralph_orchestrator_workspace() {
    local context_file="$1"
    local kind linked_issue_section
    kind=$(jq -r '.kind' "$context_file")
    linked_issue_section=""

    if [[ "$(jq -r '.linked_issue_number // empty' "$context_file")" != "" ]]; then
        linked_issue_section=$(cat <<EOF
## Related Issue

Fixes #$(jq -r '.linked_issue_number' "$context_file"): $(jq -r '.linked_issue_title // ""' "$context_file")

$(jq -r '.linked_issue_body // ""' "$context_file")
EOF
)
    fi

    mkdir -p "$RALPH_WORKSPACE/.ralph/agent" "$RALPH_WORKSPACE/logs"

    case "$kind" in
        issue)
            cat > "$ORCHESTRATOR_WATCHER_PROMPT" <<EOF
# Task: GitHub Issue #$(jq -r '.number' "$context_file") - $(jq -r '.title' "$context_file")

Implement the requested issue work for $(jq -r '.repo' "$context_file").

## Project Context

- Primary repository path: /root/repos/$(jq -r '.repo_name' "$context_file")
- Stable runbook: /root/.ralph/AGENT.md
- Persistent memory: /root/.ralph/agent/memories.md
- Issue URL: $(jq -r '.html_url' "$context_file")
- Opened by: @$(jq -r '.user' "$context_file")
- Labels: $(jq -r '.labels | join(", ")' "$context_file")

## Issue Description

$(jq -r '.body' "$context_file")

## Discussion

$(jq -r '.discussion' "$context_file")

## Triggering Request

This is the newest direct request and has priority over older discussion when they conflict.

$(jq -r '.trigger_body // .body' "$context_file")

## Requirements

- Work in /root/repos/$(jq -r '.repo_name' "$context_file"), or additional repos only if the real execution path requires it.
- Analyze the issue and recent discussion before editing code.
- Treat the "Triggering Request" section as the primary objective for this run.
- Implement the minimal correct fix or feature.
- Run relevant tests and validation.
- Create a pull request to $(jq -r '.repo' "$context_file") with "Fixes #$(jq -r '.number' "$context_file")" in the description.
- Comment on the original issue with a summary of the work. Start the comment with "## Ralph - Task Completed".

## Completion

When the work is complete and validated, print:

\`\`\`text
LOOP_COMPLETE
\`\`\`
EOF
            ;;
        pr)
            cat > "$ORCHESTRATOR_WATCHER_PROMPT" <<EOF
# Task: GitHub PR #$(jq -r '.number' "$context_file") - $(jq -r '.title' "$context_file")

Review and address the requested PR feedback for $(jq -r '.repo' "$context_file").

## Project Context

- Primary repository path: /root/repos/$(jq -r '.repo_name' "$context_file")
- Stable runbook: /root/.ralph/AGENT.md
- Persistent memory: /root/.ralph/agent/memories.md
- PR URL: $(jq -r '.html_url' "$context_file")
- Branch to update: $(jq -r '.branch' "$context_file")
- Opened by: @$(jq -r '.user' "$context_file")
- Trigger type: $(jq -r '.trigger_type' "$context_file")
- Trigger comment ID: $(jq -r '.trigger_comment_id // "n/a"' "$context_file")

## PR Description

$(jq -r '.body' "$context_file")

## Conversation Thread

$(jq -r '.conversation' "$context_file")

${linked_issue_section}

## Triggering Request

This is the newest direct request and has priority over older discussion when they conflict.

$(jq -r '.trigger_body // "No trigger comment body available."' "$context_file")

## Requirements

- Work in /root/repos/$(jq -r '.repo_name' "$context_file").
- Fetch and checkout branch \`$(jq -r '.branch' "$context_file")\`.
- Treat the "Triggering Request" section as the primary objective for this run.
- Address all relevant PR feedback.
- Run relevant tests and validation.
- Push fixes back to branch \`$(jq -r '.branch' "$context_file")\`.
- Comment on the PR with a summary of the work. Start the comment with "## Ralph - Task Completed".

## Completion

When the work is complete and validated, print:

\`\`\`text
LOOP_COMPLETE
\`\`\`
EOF
            ;;
        *)
            log_error "Unsupported context kind for ralph-orchestrator: $kind"
            return 1
            ;;
    esac

    log_info "Prepared ralph-orchestrator watcher prompt at $ORCHESTRATOR_WATCHER_PROMPT"
}

start_ralph_orchestrator_loop() {
    log_info "Starting ralph-orchestrator..."

    cd "$RALPH_WORKSPACE" || {
        log_error "Failed to change directory to $RALPH_WORKSPACE"
        return 1
    }

    if [[ ! -f "$RALPH_WORKSPACE/ralph.yml" ]]; then
        log_error "Ralph Orchestrator config missing: $RALPH_WORKSPACE/ralph.yml"
        return 1
    fi

    start_tmux_runner "ralph run -c ralph.yml -P .ralph/gh_task_prompt.md --autonomous"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started ralph-orchestrator in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start ralph-orchestrator tmux session"
    return 1
}

evaluate_ralph_orchestrator_outcome() {
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:backend_limit"
    else
        echo "failure:exit_code_${exit_code:-missing}"
    fi
}
