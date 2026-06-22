#!/usr/bin/env bash
#
# Forgejo watcher adapter for frankbria/ralph-claude-code.
# Implements the standard adapter interface consumed by forgejo_watcher.sh.
#

set -euo pipefail

prepare_ralph_claude_code_workspace() {
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

    mkdir -p "$RALPH_WORKSPACE/.ralph" "$RALPH_WORKSPACE/logs"

    case "$kind" in
        issue)
            cat > "$RALPH_WORKSPACE/.ralph/fix_plan.md" <<EOF
---
# Task from Issue #$(jq -r '.number' "$context_file"): $(jq -r '.title' "$context_file")

## Repository Context

**Repository:** $(jq -r '.repo' "$context_file")
**Issue URL:** $(jq -r '.html_url' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Created by:** @$(jq -r '.user' "$context_file")
**Labels:** $(jq -r '.labels | join(", ")' "$context_file")

## Description

$(jq -r '.body' "$context_file")

## Discussion

$(jq -r '.discussion' "$context_file")

## Tasks

- [ ] Navigate to /root/repos/$(jq -r '.repo_name' "$context_file") (or relevant repo if multi-repo change needed)
- [ ] Analyze requirements from the issue description and discussion
- [ ] Implement the solution in the correct repository
- [ ] Run tests and verify functionality
- [ ] Create a pull request to $(jq -r '.repo' "$context_file") with "Fixes #$(jq -r '.number' "$context_file")" in the description
- [ ] Ensure the PR title and body clearly explain the changes
- [ ] Comment on the original issue with a summary of the work. Start the comment with "## Ralph - Task Completed"

## Notes

- This VM may have multiple repos under /root/repos/
- If changes span multiple repos, create separate PRs for each

---
EOF
            ;;
        pr)
            cat > "$RALPH_WORKSPACE/.ralph/fix_plan.md" <<EOF
---
# Task from PR #$(jq -r '.number' "$context_file"): $(jq -r '.title' "$context_file")

## Repository Context

**Repository:** $(jq -r '.repo' "$context_file")
**PR URL:** $(jq -r '.html_url' "$context_file")
**Branch:** $(jq -r '.branch' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Created by:** @$(jq -r '.user' "$context_file")
**Trigger type:** $(jq -r '.trigger_type' "$context_file")
**Trigger comment ID:** $(jq -r '.trigger_comment_id // "n/a"' "$context_file")

## PR Description

$(jq -r '.body' "$context_file")

## Conversation Thread

$(jq -r '.conversation' "$context_file")

${linked_issue_section}

## Tasks

- [ ] Navigate to /root/repos/$(jq -r '.repo_name' "$context_file")
- [ ] Fetch and checkout branch \`$(jq -r '.branch' "$context_file")\`
- [ ] Review all PR feedback and address all comments
- [ ] Make the necessary code changes
- [ ] Run tests and verify all pass
- [ ] Push fixes to branch \`$(jq -r '.branch' "$context_file")\`
- [ ] Comment on the PR with a summary of changes. Start the comment with "## Ralph - Task Completed"

---
EOF
            ;;
        pipeline_failure)
            cat > "$RALPH_WORKSPACE/.ralph/fix_plan.md" <<EOF
---
# Task: Fix failing pipeline $(jq -r '.name' "$context_file") on $(jq -r '.branch' "$context_file")

## Repository Context

**Repository:** $(jq -r '.repo' "$context_file")
**Run URL:** $(jq -r '.html_url' "$context_file")
**Branch:** $(jq -r '.branch' "$context_file")
**Failing SHA:** $(jq -r '.sha' "$context_file")
**Conclusion:** $(jq -r '.conclusion' "$context_file")
**Local repo path:** /root/repos/$(jq -r '.repo_name' "$context_file")
**Clone URL:** $(jq -r '.clone_url' "$context_file")

## Failed Jobs Summary

$(jq -r '.jobs_md' "$context_file")

## Tasks

- [ ] Ensure the repository is available at /root/repos/$(jq -r '.repo_name' "$context_file"). Clone it from $(jq -r '.clone_url' "$context_file") if needed.
- [ ] Fetch and checkout the failing SHA \`$(jq -r '.sha' "$context_file")\` (or branch \`$(jq -r '.branch' "$context_file")\`).
- [ ] Inspect the failed pipeline details at the run URL above and the failing jobs summary.
- [ ] Identify the root cause and implement the minimal correct fix.
- [ ] Run the same checks/tests locally that failed in CI and verify they now pass.
- [ ] Create a new branch \`auto-fix/pipeline-$(jq -r '.run_id' "$context_file")\`, push it, and open a pull request to \`$(jq -r '.branch' "$context_file")\`.
- [ ] If the fix is verified, optionally leave a brief comment summarizing the failure and fix.

## Notes

- Do not modify unrelated code.
- If the failure is due to a transient/environmental issue, document the finding and do not open a PR.
- This VM may have limited network access; prefer local reproduction where possible.

---
EOF
            ;;
        *)
            log_error "Unsupported context kind for ralph-claude-code: $kind"
            return 1
            ;;
    esac

    log_info "Prepared ralph-claude-code watcher workspace"
}

start_ralph_claude_code_loop() {
    log_info "Starting ralph-claude-code with ${RALPH_TIMEOUT}-minute timeout..."

    cd "$RALPH_WORKSPACE" || {
        log_error "Failed to change directory to $RALPH_WORKSPACE"
        return 1
    }

    ralph --reset-circuit >/dev/null 2>&1 || true
    start_tmux_runner "timeout ${RALPH_TIMEOUT}m ralph --monitor --timeout ${RALPH_TIMEOUT}"

    if tmux has-session -t ralph-loop 2>/dev/null; then
        log_info "Started ralph-claude-code in tmux session 'ralph-loop'"
        return 0
    fi

    log_error "Failed to start ralph-claude-code tmux session"
    return 1
}

evaluate_ralph_claude_code_outcome() {
    local run_start_epoch="${1:-}"
    local exit_code
    exit_code=$(get_run_exit_code 2>/dev/null || true)

    if [[ "$exit_code" == "0" ]]; then
        echo "success:ok"
        return 0
    fi

    if watcher_log_contains_rate_limit; then
        echo "rate_limited:claude_usage_limit"
        return 0
    fi

    echo "failure:exit_code_${exit_code:-missing}"
}

# Standard generic interface used by the agent-aware GitHub watcher.
prepare_agent_workspace() { prepare_ralph_claude_code_workspace "$@"; }
start_agent_loop() { start_ralph_claude_code_loop; }
evaluate_agent_outcome() { evaluate_ralph_claude_code_outcome "$@"; }
