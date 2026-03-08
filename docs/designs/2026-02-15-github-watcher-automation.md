# GitHub Watcher - Automated Ralph Workflow

**Date:** 2026-02-15
**Status:** Approved for Implementation

## Overview

Automated system where Ralph monitors GitHub repositories for `!ralph` mentions, autonomously executes tasks, and creates pull requests without manual intervention.

## High-Level Flow

```
GitHub API ──poll──> Watcher ──populate──> fix_plan.md ──trigger──> Ralph ──creates──> Pull Request
     ↑                 │                                                                    │
     └─────────────────┴────────────────────────────────────────────────────────────────────┘
                                    (returns to polling mode)
```

## Architecture

### 1. GitHub Watcher Daemon

**Location:** `/opt/ralph/ralph_gh_watcher.sh` (installed system-wide in VM)

**Polling Strategy:**
- Check GitHub API every 60 seconds (60 requests/hour, well within 5,000/hour limit)
- Use `since` parameter for efficiency (only fetch new activity)
- Block while Ralph is working (check tmux session existence)

**State Machine:**
```
POLLING → TASK_FOUND → WAITING_FOR_RALPH → TASK_COMPLETE → POLLING
```

**Trigger:** Universal `!ralph` mention anywhere in:
- Issue body or comments
- Pull request body or comments
- Any position in text

**Priority Queue:**
1. **Priority 1:** !ralph in PR comments (fixes to existing PRs)
2. **Priority 2:** !ralph in issues (new features/bugs)

### 2. Context Builder

**For Issues:**
```markdown
# Task from Issue #123: [title]

**Issue URL:** [url]
**Created by:** @username
**Labels:** [labels]

## Description
[Full issue body]

## Discussion
[All comments with authors and timestamps]

## Tasks
- [ ] Analyze requirements
- [ ] Implement solution
- [ ] Run tests
- [ ] Create PR with "Fixes #123"
```

**For PR Comments:**
```markdown
# Task from PR #456: [title]

**PR URL:** [url]
**Branch:** fix-auth-bug
**!ralph mentioned by:** @reviewer

## PR Description
[Original PR body]

## Conversation Thread
[All comments chronologically]

## Related Issue
Fixes #789: [issue title and body if linked]

## Tasks
- [ ] Checkout branch `fix-auth-bug`
- [ ] Address feedback
- [ ] Run tests
- [ ] Push to same branch
```

### 3. Ralph Execution

**Triggering:**
```bash
cd /root/repos/my-project
ralph --monitor --timeout 720  # 12-hour timeout (covers 2x 5-hour API cycles)
```

**Workflow:**
1. Read `.ralph/fix_plan.md` (populated by watcher)
2. Read `.ralph/PROMPT.md` (project instructions)
3. Execute autonomous development loop
4. For PR tasks: checkout existing branch
5. For issue tasks: create new branch with intelligent naming:
   - `feat/feature-name` for new features
   - `fix/bug-description` for bug fixes
   - `chore/task-name` for maintenance
   - `refactor/component-name` for refactoring
   - `docs/documentation-type` for documentation
6. Make changes, run tests, commit
7. Create PR with auto-generated title/body including "Fixes #123"
8. Exit → watcher resumes polling

**Exit Conditions:**
- All tasks in fix_plan.md completed
- `EXIT_SIGNAL: true` from Ralph
- 12-hour timeout reached
- Error encountered → post error comment

### 4. Error Handling

When Ralph encounters errors:

1. Post comment to original issue/PR:
```markdown
## 🤖 Ralph - Task Update

I encountered an issue while working on this task.

**Error Type:** [Build failure/Test failures/etc]

**What I tried:**
- Created branch `fix/oauth-token-refresh`
- Modified files...
- Tests failed: [details]

**Error Details:**
[Stack traces, error messages]

**Next Steps:**
- Review the test failures
- Branch: `fix/oauth-token-refresh` (pushed with partial work)

---
*Automated message from Ralph. Returned to monitoring mode.*
```

2. Mark task as processed (won't retry automatically)
3. Return to polling mode
4. User can re-trigger with another `!ralph` + clarification

### 5. Configuration

**System Configuration:** `/root/.config/gh-watcher/config.conf`
```bash
WATCHER_ENABLED=true
POLL_INTERVAL=60
WATCHED_REPOS="owner/repo1,owner/repo2"
PROJECT_DIR="/root/repos/my-project"
GITHUB_TOKEN_FILE="/root/.config/gh/token"
RALPH_TIMEOUT=720
POST_ERROR_COMMENTS=true
```

**GitHub Token Security:**
- **Location:** `/root/.config/gh/token`
- **Permissions:** 600 (owner read/write only)
- **Type:** Fine-grained Personal Access Token
- **Required permissions:**
  - Issues: Read and write
  - Pull requests: Read and write
  - Contents: Read only
  - Metadata: Read only (automatic)
- **Expiration:** 90 days (recommended)
- **Never commit:** Add to .gitignore

**Authentication:**
```bash
# Setup token
mkdir -p /root/.config/gh
echo "ghp_your_token" > /root/.config/gh/token
chmod 600 /root/.config/gh/token

# Configure gh CLI
export GH_TOKEN=$(cat /root/.config/gh/token)
```

### 6. File Structure

```
/root/
├── .config/
│   ├── gh/
│   │   └── token                    # GitHub PAT (600 perms)
│   └── gh-watcher/
│       ├── config.conf              # Watcher configuration
│       ├── processed.json           # Completed tasks tracking
│       ├── watcher.log              # Activity log
│       └── current_task.json        # Active task details
└── repos/my-project/
    ├── .ralph/
    │   ├── PROMPT.md                # Ralph instructions
    │   ├── AGENT.md                 # Build/test commands
    │   ├── fix_plan.md              # Current task (watcher populates)
    │   ├── specs/                   # Project specs
    │   └── logs/                    # Ralph logs
    └── src/                         # Source code

/opt/ralph/
├── ralph_loop.sh                    # Existing Ralph loop
├── ralph_monitor.sh                 # Existing Ralph monitor
└── ralph_gh_watcher.sh              # NEW: Watcher daemon
```

### 7. CLI Commands

**Foundry CLI:**
```bash
foundry agent gh-watcher init <vm-name>      # Setup watcher
foundry agent gh-watcher start <vm-name>     # Start daemon
foundry agent gh-watcher stop <vm-name>      # Stop daemon
foundry agent gh-watcher status <vm-name>    # Check status
foundry agent gh-watcher logs <vm-name>      # View logs
foundry agent gh-watcher reset <vm-name>     # Clear processed tasks
```

**Inside VM:**
```bash
ralph-gh-watcher start    # Start manually
ralph-gh-watcher stop     # Stop manually
ralph-gh-watcher status   # Check status
ralph-gh-watcher queue    # View task queue
```

## Implementation Details

### Processed Tasks Tracking

**`/root/.config/gh-watcher/processed.json`:**
```json
{
  "version": "1.0",
  "processed": {
    "issue_123": {
      "type": "issue",
      "number": 123,
      "processed_at": "2026-02-15T10:30:00Z",
      "result": "pr_created",
      "pr_number": 456
    },
    "pr_789_comment_12345": {
      "type": "pr_comment",
      "pr_number": 789,
      "comment_id": 12345,
      "processed_at": "2026-02-15T11:00:00Z",
      "result": "error_posted"
    }
  },
  "last_poll": "2026-02-15T11:30:00Z"
}
```

### GitHub API Calls

**Per polling cycle (60s):**
```bash
# For each configured repo:
gh api "repos/{owner}/{repo}/issues/comments?since={last_poll}"
gh api "repos/{owner}/{repo}/pulls/comments?since={last_poll}"
gh api "repos/{owner}/{repo}/issues?since={last_poll}&state=open"

# Usage: ~3-6 requests per cycle
# Rate limit: 5,000/hour → 60/hour used → Safe margin
```

**With conditional requests (ETag):**
- 304 Not Modified responses don't count against rate limit
- Store ETags for even better efficiency

### VM Lifecycle

- **VM runs 24/7** with watcher daemon
- Watcher runs in tmux session "ralph-gh-watcher"
- Ralph runs in separate tmux session "ralph-loop" when working
- Both sessions survive SSH disconnection

### Multi-Repo Support

Each VM can monitor multiple repositories:

```bash
# Example: VM watches 3 related repos
WATCHED_REPOS="myorg/backend,myorg/api,myorg/shared-lib"

# Watcher polls all configured repos each cycle
# When !ralph found in any repo, watcher:
# 1. Identifies which repo the task is from
# 2. Clones/updates that repo in PROJECT_DIR if needed
# 3. Populates fix_plan.md with repo context
# 4. Starts Ralph to work on that specific repo
```

## Workflow Example

1. **Developer creates issue:**
   ```markdown
   Title: Add dark mode support
   Body: We need dark mode. !ralph please implement this.
   ```

2. **Watcher detects !ralph** (within 60 seconds)

3. **Watcher builds context** → populates `.ralph/fix_plan.md`

4. **Watcher starts Ralph** → enters WAITING state

5. **Ralph works autonomously:**
   - Creates branch `feat/dark-mode-support`
   - Implements dark mode toggle, theme state, CSS updates
   - Runs tests
   - Commits changes
   - Creates PR with "Fixes #123" in description

6. **Ralph exits** → watcher marks task processed

7. **Watcher resumes polling** after 2-minute cooldown

8. **Issue auto-closes** when PR is merged

## Security Considerations

1. **Token isolation:** Stored outside git repo, never logged
2. **Minimal permissions:** Only what's needed (issues, PRs, read contents)
3. **Token rotation:** 90-day expiration recommended
4. **File permissions:** 600 on token file
5. **VM-specific tokens:** Each VM has own token for easy revocation
6. **Fine-grained PATs:** More restrictive than classic tokens
