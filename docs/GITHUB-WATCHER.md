# GitHub Watcher - Automated Agent Workflow

The GitHub Watcher enables fully autonomous development by monitoring GitHub repositories for `!ralph` mentions, automatically triggering the configured autonomous agent to work on tasks, and creating pull requests when complete.

It supports `ralph-claude-code`, `ralph-orchestrator`, and `kimi-ralph`. The watcher reads the configured agent type from `/root/.config/gh-watcher/config.conf` (or falls back to legacy Ralph variant detection) and loads the matching adapter.

## Overview

Once configured, the watcher runs 24/7 inside a VM, polling GitHub every 60 seconds for new work:

1. Developer posts `!ralph` in an issue or PR comment
2. Watcher detects the mention (within 60 seconds)
3. Watcher builds the matching agent-specific task context
4. Watcher starts the autonomous agent to work
5. Agent completes the task and creates a PR (or posts an error comment)
6. Watcher resumes polling for the next task

## Quick Start

### Prerequisites

- VM with an autonomous agent installed and configured (Ralph or kimi-ralph)
- GitHub fine-grained Personal Access Token
- Repositories to monitor

### Setup

**1. Initialize the watcher:**

```bash
foundry agent gh-watcher init <vm-name>
```

If `~/.config/foundry/projects/<project>/gh-watcher.json` exists, `init` loads it automatically. Otherwise it falls back to prompts.

Minimal example:

```json
{
  "watched_repos": ["myorg/backend", "myorg/frontend"],
  "github_token_file": "./secrets/github-token.txt",
  "poll_interval": 60,
  "ralph_timeout": 120,
  "agent_type": "ralph",
  "post_error_comments": true,
  "enabled": true
}
```

Supported token sources in `gh-watcher.json`:
- `github_token_file`
- `github_token_env`
- `github_token`

**2. Start the watcher:**

```bash
foundry agent gh-watcher start <vm-name>
```

**3. Verify it's running:**

```bash
foundry agent gh-watcher status <vm-name>
```

### Usage

Once running, simply mention `!ralph` anywhere in:
- Issue body or comments
- Pull request body or comments

The watcher will detect it and start the configured autonomous agent automatically.

## GitHub Token Setup

### Creating a Fine-Grained Token

1. Go to https://github.com/settings/tokens?type=beta
2. Click "Generate new token"
3. Name it (e.g., "Agent Foundry - VM Name")
4. Set expiration (90 days recommended for security)
5. Select repositories to grant access
6. Set permissions:
   - **Issues**: Read and write
   - **Pull requests**: Read and write
   - **Contents**: Read only
   - **Metadata**: Read only (automatic)
7. Click "Generate token"
8. Copy the token (starts with `ghp_`)

### Security Best Practices

- **Never commit** the token to git
- **Set expiration** - rotate tokens every 90 days
- **Use fine-grained tokens** - more restrictive than classic PATs
- **One token per VM** - easier to revoke if compromised
- **Minimal permissions** - only what the watcher needs
- **Store securely** - token is stored as `/root/.config/gh/token` with 600 permissions

## Configuration

### Config File Locations

Inside the VM: `/root/.config/gh-watcher/config.conf`

Optional host-side project config: `~/.config/foundry/projects/<project>/gh-watcher.json`

### Configuration Options

```bash
# Enable automatic polling
WATCHER_ENABLED=true

# Polling interval in seconds (60 = 1 minute)
POLL_INTERVAL=60

# Repositories to monitor (comma-separated)
WATCHED_REPOS="owner/repo1,owner/repo2"

# GitHub token file location
GITHUB_TOKEN_FILE="/root/.config/gh/token"

# Agent execution timeout in minutes (720 = 12 hours)
AGENT_TIMEOUT=720

# Legacy Ralph timeout (kept for backward compatibility)
RALPH_TIMEOUT=720

# Post error comments when the agent fails
POST_ERROR_COMMENTS=true
```

### Multi-Repository Monitoring

A single watcher can monitor multiple repositories:

```bash
WATCHED_REPOS="myorg/backend,myorg/frontend,myorg/shared-lib"
```

This is useful when a VM works on related projects.

## Commands

### Initialize Watcher

```bash
foundry agent gh-watcher init <vm-name>
```

Loads `gh-watcher.json` when present, otherwise prompts for configuration, then sets up the watcher.

### Start Watcher

```bash
foundry agent gh-watcher start <vm-name>
```

Starts the watcher daemon in a tmux session (`ralph-gh-watcher`).

### Stop Watcher

```bash
foundry agent gh-watcher stop <vm-name>
```

Stops the watcher daemon (the agent continues if already working).

### Check Status

```bash
foundry agent gh-watcher status <vm-name>
```

Shows:
- Watcher state (polling/waiting/working)
- Configuration details
- Current task
- Processed task count
- Last poll time

### View Logs

```bash
foundry agent gh-watcher logs <vm-name>          # Last 100 lines
foundry agent gh-watcher logs <vm-name> --follow # Tail mode
```

### Reset State

```bash
foundry agent gh-watcher reset <vm-name>
```

Clears all processed task history. Useful if you want the agent to retry a previously failed task.

## Task Priority

The watcher processes tasks with this priority:

1. **!ralph in PR comments** - Fixes to existing PRs (highest priority)
2. **!ralph in issues** - New features or bug fixes

Only one task is processed at a time. New tasks queue until the current one completes.

## Workflow Examples

### Example 1: New Feature via Issue

**Developer creates issue:**

```markdown
Title: Add dark mode support

Body:
We need a dark mode toggle. !ralph please implement this feature.

Requirements:
- Toggle button in settings
- Persists user preference
- Applies to all pages
```

**What happens:**

1. Watcher detects `!ralph` within 60 seconds
2. Watcher creates the matching Ralph task file with full issue context
3. Watcher starts Ralph
4. Ralph:
   - Analyzes requirements
   - Creates branch `feat/dark-mode-support`
   - Implements toggle, state management, and styling
   - Runs tests
   - Creates PR with "Fixes #123" in description
5. Issue auto-closes when PR is merged

### Example 2: PR Review Feedback

**Reviewer comments on PR:**

```markdown
!ralph The OAuth token refresh logic is broken. Please fix:

1. Token expires after 1 hour but refresh happens after 2 hours
2. Error handling doesn't catch 401 responses
```

**What happens:**

1. Watcher detects `!ralph` in PR comment
2. Watcher builds context including:
   - Full PR description
   - All review comments
   - Linked issue (if any)
3. Watcher starts Ralph
4. Ralph:
   - Checks out the PR branch
   - Fixes the token refresh timing
   - Adds 401 error handling
   - Runs tests
   - Pushes to the same branch
   - PR auto-updates

### Example 3: Error Handling

**Ralph encounters build failures:**

```
tests/auth.test.ts:45
  ✕ should refresh expired tokens
    Expected token to be refreshed but got null
```

**What happens:**

1. Ralph posts error comment on the issue/PR:

```markdown
## 🤖 Ralph - Task Update

I encountered an issue while working on this task.

**Error Type:** Test failures

**What I tried:**
- Created branch `fix/oauth-token-refresh`
- Modified `src/auth/token.ts`
- Tests failed: 3 failures in `auth.test.ts`

**Error Details:**
[Stack traces]

**Next Steps:**
- Review the test failures
- Branch pushed with partial work: `fix/oauth-token-refresh`

---
*Automated message from Ralph. Returned to monitoring mode.*
```

2. Ralph marks task as processed (won't retry automatically)
3. Watcher resumes polling
4. Developer debugs and posts `!ralph try again` with clarification
5. Watcher picks up new task

## State Management

### Processed Tasks

File: `/root/.config/gh-watcher/processed.json`

Tracks completed work to avoid re-processing:

```json
{
  "version": "1.0",
  "processed": {
    "issue_123": {
      "type": "issue",
      "number": 123,
      "processed_at": "2026-02-15T10:30:00Z",
      "result": "completed",
      "pr_number": 456
    },
    "pr_789_comment_12345": {
      "type": "pr_comment",
      "pr_number": 789,
      "comment_id": 12345,
      "processed_at": "2026-02-15T11:00:00Z",
      "result": "completed"
    }
  },
  "last_poll": "2026-02-15T11:30:00Z"
}
```

### Current Task

File: `/root/.config/gh-watcher/current_task.json`

Stores details of the task Ralph is currently working on.

## Rate Limits

### GitHub API

- **Authenticated rate limit**: 5,000 requests/hour
- **Watcher usage**: ~60 requests/hour (1 poll/minute × repos watched)
- **Safe margin**: Watcher uses only 1.2% of available quota

### Optimization

- Uses `since` parameter to fetch only new activity
- Conditional requests with ETags (304 responses don't count)
- Efficient filtering with `--jq` to reduce data transfer

## Troubleshooting

### Watcher Not Starting

```bash
# Check if VM is running
foundry vm status <vm-name>

# Check if watcher is initialized
foundry vm ssh <vm-name> "ls -la /root/.config/gh-watcher/"

# Check logs for errors
foundry agent gh-watcher logs <vm-name>
```

### Agent Not Triggering

```bash
# Check if watcher sees the mention
foundry agent gh-watcher status <vm-name>

# Verify token permissions
foundry vm ssh <vm-name> "gh auth status"

# Check if the autonomous agent is installed
foundry vm ssh <vm-name> "command -v ralph"   # for Ralph
foundry vm ssh <vm-name> "command -v kimi"    # for kimi-ralph
```

### Token Issues

```bash
# Test token validity
foundry vm ssh <vm-name> "gh api user"

# Re-create token file
foundry vm ssh <vm-name> "echo 'ghp_new_token' > /root/.config/gh/token && chmod 600 /root/.config/gh/token"
```

### Watcher Stuck

```bash
# Check what Ralph is doing
foundry agent attach <vm-name>  # Detach with Ctrl+b d

# Restart watcher
foundry agent gh-watcher stop <vm-name>
foundry agent gh-watcher start <vm-name>

# Check processed tasks
foundry vm ssh <vm-name> "cat /root/.config/gh-watcher/processed.json | jq"
```

## Advanced Usage

### Manual Control Inside VM

SSH into the VM for direct control:

```bash
# SSH into VM
foundry vm ssh <vm-name>

# Control watcher directly
/opt/foundry/gh-watcher/gh_watcher.sh status
/opt/foundry/gh-watcher/gh_watcher.sh start
/opt/foundry/gh-watcher/gh_watcher.sh stop
/opt/foundry/gh-watcher/gh_watcher.sh queue

# View logs
tail -f /root/.config/gh-watcher/watcher.log

# Check agent work session status
tmux attach -t ralph-loop  # Detach with Ctrl+b d
```

### Changing Configuration

```bash
# SSH into VM
foundry vm ssh <vm-name>

# Edit config
vi /root/.config/gh-watcher/config.conf

# Restart watcher to apply changes
foundry agent gh-watcher stop <vm-name>
foundry agent gh-watcher start <vm-name>
```

### Monitoring Multiple VMs

```bash
# Status of all watcher-enabled VMs
for vm in $(foundry vm list --format=names); do
    echo "=== $vm ==="
    foundry agent gh-watcher status $vm 2>/dev/null || echo "Not configured"
    echo ""
done
```

## Best Practices

1. **Use descriptive `!ralph` mentions**
   - Include clear requirements
   - Link to relevant documentation
   - Specify expected behavior

2. **Monitor watcher logs regularly**
   ```bash
   foundry agent gh-watcher logs <vm> --follow
   ```

3. **Rotate tokens every 90 days**
   - Set calendar reminder
   - Use GitHub token expiration feature

4. **One VM per project/team**
   - Easier to manage
   - Clearer ownership
   - Better resource isolation

5. **Review Ralph's PRs promptly**
   - Watcher continues with next task
   - PRs may need human review before merge

6. **Reset state when needed**
   - After fixing watcher bugs
   - When retrying failed tasks
   - Use `foundry agent gh-watcher reset`

## Architecture

For detailed architecture and design decisions, see:
- [Design Document](../docs/designs/2026-02-15-github-watcher-automation.md)
- [Ralph Integration](../docs/RALPH-INTEGRATION.md)

## Related Documentation

- [Ralph Documentation](https://github.com/frankbria/ralph-claude-code)
- [GitHub API Rate Limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- [Fine-Grained PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token)
