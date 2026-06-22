#!/usr/bin/env bash
#
# Forgejo watcher adapter for Kimi Code CLI running in Ralph mode.
# This file is sourced by forgejo_watcher.sh and must implement the standard
# adapter interface:
#   prepare_agent_workspace <context_file>
#   start_agent_loop()
#   evaluate_agent_outcome [run_start_epoch]
#

set -euo pipefail

KIMI_WORKSPACE="${KIMI_WORKSPACE:-/root}"
KIMI_DOTFOLDER="$KIMI_WORKSPACE/.kimi"
KIMI_TASK_PROMPT_FILE="$KIMI_DOTFOLDER/task_prompt.md"
KIMI_LOG_FILE="$KIMI_WORKSPACE/logs/kimi-ralph.log"

# Internal: run a command inside the Kimi workspace.
_kimi_in_workspace() {
    (
        cd "$KIMI_WORKSPACE" || exit 1
        "$@"
    )
}

prepare_agent_workspace() {
    local context_file="$1"
    local kind
    kind=$(jq -r '.kind' "$context_file")

    mkdir -p "$KIMI_DOTFOLDER" "$KIMI_WORKSPACE/logs"

    case "$kind" in
        issue)
            cat > "$KIMI_TASK_PROMPT_FILE" <<EOF
# Task from Issue #$(jq -r '.number' "$context_file"): $(jq -r '.title' "$context_file")

**Repository:** $(jq -r '.repo' "$context_file")
**Issue URL:** $(jq -r '.html_url' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Created by:** @$(jq -r '.user' "$context_file")
**Labels:** $(jq -r '.labels | join(", ")' "$context_file")

## Description

$(jq -r '.body' "$context_file")

## Discussion

$(jq -r '.discussion' "$context_file")

## Requirements

- Navigate to /root/repos/$(jq -r '.repo_name' "$context_file") (or the correct repo if the change spans multiple repos).
- Analyze the issue description and discussion.
- Implement the minimal correct fix or feature.
- Run relevant tests and verify functionality.
- Create a pull request to $(jq -r '.repo' "$context_file") with "Fixes #$(jq -r '.number' "$context_file")" in the description.
- Comment on the original issue with a summary of the work. Start the comment with "## Kimi - Task Completed".

## Notes

- This VM may have multiple repos under /root/repos/.
- If changes span multiple repos, create separate PRs for each.
EOF
            ;;
        pr)
            cat > "$KIMI_TASK_PROMPT_FILE" <<EOF
# Task from PR #$(jq -r '.number' "$context_file"): $(jq -r '.title' "$context_file")

**Repository:** $(jq -r '.repo' "$context_file")
**PR URL:** $(jq -r '.html_url' "$context_file")
**Branch:** $(jq -r '.branch' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Created by:** @$(jq -r '.user' "$context_file")
**Trigger type:** $(jq -r '.trigger_type' "$context_file")

## PR Description

$(jq -r '.body' "$context_file")

## Conversation Thread

$(jq -r '.conversation' "$context_file")

## Requirements

- Navigate to /root/repos/$(jq -r '.repo_name' "$context_file").
- Fetch and checkout branch \`$(jq -r '.branch' "$context_file")\`.
- Determine the user's intent from the trigger comment/body.
- If the user asked for a **review** (e.g. "review this", "please review", "code review", "@touya review"):
  - Review the diff only.
  - Leave review comments on specific lines where helpful.
  - Summarize your review in a PR comment.
  - **Do not push commits or open a new PR.**
- If the user explicitly asked for changes/fixes:
  - Make the minimal necessary code changes.
  - Run relevant tests and verify all pass.
  - Push fixes back to branch \`$(jq -r '.branch' "$context_file")\`.
  - Comment on the PR with a summary of changes. Start the comment with "## Kimi - Task Completed".
- If intent is unclear, default to a review only.
EOF
            ;;
        pipeline_failure)
            cat > "$KIMI_TASK_PROMPT_FILE" <<EOF
# Task: Fix failing pipeline $(jq -r '.name' "$context_file") on $(jq -r '.branch' "$context_file")

**Repository:** $(jq -r '.repo' "$context_file")
**Run URL:** $(jq -r '.html_url' "$context_file")
**Branch:** $(jq -r '.branch' "$context_file")
**Failing SHA:** $(jq -r '.sha' "$context_file")
**Conclusion:** $(jq -r '.conclusion' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Clone URL:** $(jq -r '.clone_url' "$context_file")

## Failed Jobs Summary

$(jq -r '.jobs_md' "$context_file")

## Requirements

- Ensure the repository is available at /root/repos/$(jq -r '.repo_name' "$context_file"). Clone it from $(jq -r '.clone_url' "$context_file") if needed.
- Fetch and checkout the failing SHA \`$(jq -r '.sha' "$context_file")\` (or branch \`$(jq -r '.branch' "$context_file")\`).
- Inspect the failed pipeline details at the run URL above and the failing jobs summary.
- Identify the root cause and implement the minimal correct fix.
- Run the same checks/tests locally that failed in CI and verify they now pass.
- Create a new branch \`auto-fix/pipeline-$(jq -r '.run_id' "$context_file")\`, push it, and open a pull request to \`$(jq -r '.branch' "$context_file")\`.
- If the fix can be verified and the pipeline is green, optionally leave a comment on the run or open a brief issue summarizing the fix.

## Notes

- Do not modify unrelated code.
- If the failure is due to a transient/environmental issue, document the finding and do not open a PR.
- This VM may have limited network access; prefer local reproduction where possible.
EOF
            ;;
        *)
            log_error "Unsupported context kind for kimi-ralph: $kind"
            return 1
            ;;
    esac

    log_info "Prepared kimi-ralph watcher workspace"
}

start_agent_loop() {
    log_info "Starting kimi-ralph (Kimi Code CLI)..."

    if [[ ! -f "$KIMI_TASK_PROMPT_FILE" ]]; then
        log_error "Task prompt missing: $KIMI_TASK_PROMPT_FILE"
        return 1
    fi

    cd "$KIMI_WORKSPACE" || {
        log_error "Failed to change directory to $KIMI_WORKSPACE"
        return 1
    }

    start_tmux_runner "kimi -p \"\$(cat '$KIMI_TASK_PROMPT_FILE')\""

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started kimi-ralph in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start kimi-ralph tmux session"
    return 1
}

evaluate_agent_outcome() {
    local run_start_epoch="${1:-}"
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:backend_limit"
        return 0
    fi

    echo "failure:exit_code_${exit_code:-missing}"
}
