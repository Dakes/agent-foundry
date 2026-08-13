# Forgejo Watcher - Automated Agent Workflow

> **Status: not yet ported to the sandbox backend.** This document describes
> the watcher as it worked on the Firecracker VM backend. The receiver port is
> published by `foundry up`, but the watcher itself does not start yet. Host
> commands named below (`foundry agent ...`) no longer exist; the scripts under
> `templates/` are the material for the port.

The Forgejo Watcher enables fully autonomous development by monitoring Forgejo repositories for trigger mentions, receiving events via webhooks, and automatically triggering the configured autonomous agent to work on tasks.

It supports `ralph-claude-code`, `ralph-orchestrator`, and `kimi-ralph`. The watcher reads the configured agent type from `/root/.config/forgejo-watcher/config.conf` (or falls back to legacy Ralph variant detection) and loads the matching adapter.

## Overview

Unlike the GitHub watcher, which polls GitHub's API every 60 seconds, the Forgejo watcher uses Forgejo webhooks for real-time event delivery:

1. Developer posts `!ralph` in an issue or PR comment, **or** a CI pipeline fails on the default branch
2. Forgejo delivers a webhook payload to the VM receiver
3. Watcher verifies the webhook payload and queues the event
4. Watcher builds the matching agent-specific task context
5. Watcher starts the autonomous agent to work
6. Agent completes the task and creates a PR (or posts an error comment)
7. Watcher waits for the next webhook event

### Thread Session Resumption

When the configured agent is `kimi-ralph`, the watcher tracks a session ledger inside the VM at `/root/.config/foundry/sessions.json`. Each issue/PR is identified by a thread key such as `owner/repo#42`. On subsequent triggers for the same thread, the watcher resumes the previous Kimi session with `kimi -S <session-id>` instead of starting from scratch.

To see tracked sessions from the host:

```bash
foundry agent sessions <vm-name>
```

To manually resume a tracked session:

```bash
foundry agent resume <vm-name> owner/repo#42
```

Session resumption is currently enabled for `kimi-ralph`. Ralph adapters (`ralph`, `ralph-orchestrator`) maintain continuity through project files (`PROMPT.md`, `fix_plan.md`) and do not use CLI session IDs. Claude, Codex, and Gemini resume behavior has not been verified yet; they start fresh on each trigger.

## Quick Start

### Prerequisites

- VM with an autonomous agent installed and configured (Ralph or kimi-ralph)
- Self-hosted Forgejo instance reachable from the VM
- Forgejo API token with appropriate permissions
- The Forgejo instance must be able to reach the VM on the configured receiver port

### Setup

**1. Initialize the watcher:**

```bash
foundry agent forgejo-watcher init <vm-name>
```

If `~/.config/foundry/projects/<project>/forgejo-watcher.json` exists, `init` loads it automatically. Otherwise it falls back to prompts.

Minimal example:

```json
{
  "instance_url": "https://git.example.com",
  "watched_repos": ["myorg/backend", "myorg/frontend"],
  "token_file": "./secrets/forgejo-token.txt",
  "webhook_secret_file": "./secrets/forgejo-webhook-secret.txt",
  "listen_port": 8080,
  "agent_type": "ralph",
  "default_branch": "main",
  "trigger_keyword": "!ralph",
  "post_error_comments": true,
  "enabled": true
}
```

The `webhook_url` field is optional. If omitted, `init` automatically derives it from the VM's IP and `listen_port` (`http://<vm-ip>:<listen_port>/webhook`). Set it explicitly only if you use a reverse proxy, HTTPS, or a different path.

Supported token sources in `forgejo-watcher.json`:
- `token_file`
- `token_env`
- `token`

Supported webhook secret sources:
- `webhook_secret_file`
- `webhook_secret`

`init` also registers webhooks automatically. To skip registration (e.g. if you manage hooks manually):

```bash
foundry agent forgejo-watcher init <vm-name> --no-register-hooks
```

**2. Start the watcher:**

```bash
foundry agent forgejo-watcher start <vm-name>
```

By default, `start` first marks all currently open issues and PRs as processed so the watcher does not backfill old events after a restart. This is usually what you want when restarting for updates or maintenance.

To skip this and process the existing backlog instead:

```bash
foundry agent forgejo-watcher start <vm-name> --no-mark-all
```

**4. Verify it's running:**

```bash
foundry agent forgejo-watcher status <vm-name>
```

### Usage

Once running, the watcher reacts to two kinds of events:

1. **Trigger mentions** — mention the configured trigger keyword (default `!ralph`) anywhere in:
   - Issue body or comments
   - Pull request body or comments

2. **Pipeline failures** — when a `workflow_run` completes with `conclusion=failure` on the default branch (`main`), the watcher starts the agent to diagnose and fix the failure automatically.

The watcher will detect these events and start the configured autonomous agent automatically.

## Forgejo Token Setup

### Creating an API Token

1. Log in to your Forgejo instance
2. Go to `Settings → Applications`
3. Click `Generate New Token`
4. Name it (e.g., "Agent Foundry - VM Name")
5. Select scopes:
   - **repository**: write
   - **issue**: write
   - **pull_request**: write
6. Generate and copy the token

### Two-token setup (recommended for bot accounts)

If the watcher runs under a dedicated bot account, that account may not have repo admin rights required for webhook management. In that case, use two tokens:

- **Regular token** (`token_file`): belongs to the bot account. Used for normal watcher operations.
  - Scopes: **repository**: read, **issue**: write, **pull_request**: write
- **Admin token** (`admin_token_file`): belongs to a repo admin. Used only for `register-hooks` / `unregister-hooks`.
  - Scope: **repository**: write (this is the minimum required for webhook management)
  - **Important**: do **not** scope the admin token to a single repository. Forgejo requires a global `repository: write` token to manage webhooks. A repo-scoped token will fail with `403 Forbidden` even if it has write access to the target repository.

```json
{
  "token_file": "./secrets/forgejo-token.txt",
  "admin_token_file": "./secrets/forgejo-admin-token.txt"
}
```

### Security Best Practices

- **Never commit** the token to git
- **Set expiration** and rotate tokens regularly
- **One token per VM** - easier to revoke if compromised
- **Minimal permissions** - only what the watcher needs
- **Store securely** - token is stored as `/root/.config/forgejo-watcher/token` with 600 permissions

## Network Requirements

The Forgejo instance must be able to reach the VM on the configured receiver port (default `8080`).

Common setups:

- **Forgejo and VM on the same host (bare metal / VM host)**: direct access to VM IP:port
- **Forgejo running in Docker on the same host**: see [Docker networking](#docker-networking) below
- **Forgejo on the public internet, VM behind NAT**: configure port forwarding on the host
- **TLS termination**: configure a reverse proxy in front of the receiver; the `webhook_url` should use HTTPS

### Docker Networking

If Forgejo runs in a container and the watcher VM runs on the same host, the container is probably isolated from the host's Firecracker TAP network (`172.16.0.0/24`). Symptoms:

- Forgejo webhooks show delivery failures/timeouts.
- `foundry agent forgejo-watcher logs <vm>` shows no incoming events.

Choose one fix:

#### Option A: Use the host network (simplest)

Run the Forgejo container with `--network host` so it can reach `172.16.0.x` directly:

```bash
docker run --network host ... codeberg/forgejo
```

Then `register-hooks` can use the auto-derived VM IP (`http://172.16.0.x:8080/webhook`).

#### Option B: Use the Docker bridge gateway

From inside a Docker container, the host is reachable at the docker bridge gateway (usually `172.17.0.1`). Set the webhook URL manually to:

```json
"webhook_url": "http://172.17.0.1:8080/webhook"
```

Then forward host port `8080` to the VM:

```bash
# Get the VM IP
foundry vm ip <vm-name>

# Forward host 8080 to VM 8080
doas iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination <vm-ip>:8080
doas iptables -t nat -A POSTROUTING -p tcp -d <vm-ip> --dport 8080 -j MASQUERADE
```

#### Option C: Add the container to the foundry bridge

Create a macvlan/bridge network that includes the host's `foundry-br0` interface, or attach the Forgejo container to a network that can route to `172.16.0.0/24`. This is more complex; Option A is recommended for single-host setups.

### Verifying connectivity

From the Forgejo host/container:

```bash
curl -X POST http://<vm-ip-or-host-ip>:8080/webhook -d '{}'
```

The receiver should respond with `200 OK`. If it times out or returns "No route to host", the network path is wrong.

## Configuration

### Config File Locations

Inside the VM: `/root/.config/forgejo-watcher/config.conf`

Optional host-side project config: `~/.config/foundry/projects/<project>/forgejo-watcher.json`

### Configuration Options

```bash
# Enable the watcher
WATCHER_ENABLED=true

# Forgejo instance URL
FORGEJO_INSTANCE_URL="https://git.example.com"

# Repositories to monitor (comma-separated)
WATCHED_REPOS="owner/repo1,owner/repo2"

# Forgejo token location
FORGEJO_TOKEN_FILE="/root/.config/forgejo-watcher/token"

# Webhook URL where Forgejo delivers events
# Optional: if omitted, init auto-derives it from the VM IP and RECEIVER_PORT.
# Set explicitly for HTTPS, reverse proxies, or a custom path.
WEBHOOK_URL="https://foundry-vm.example.com:8080/webhook"

# Webhook secret for HMAC-SHA256 verification
WEBHOOK_SECRET_FILE="/root/.config/forgejo-watcher/webhook-secret"

# Receiver bind settings
RECEIVER_PORT=8080
RECEIVER_INTERFACE="0.0.0.0"

# Agent execution timeout in minutes
AGENT_TIMEOUT=120

# Autonomous agent type
AGENT_TYPE="ralph"

# Post error comments when the agent fails
POST_ERROR_COMMENTS=true

# Trigger keyword
TRIGGER_KEYWORD="!ralph"

# Default branch for pipeline auto-fix
DEFAULT_BRANCH="main"
```

You can also set `default_branch` and `trigger_keyword` in `forgejo-watcher.json`; `init` writes them to the VM config automatically.

### Multi-Repository Monitoring

A single watcher can monitor multiple repositories:

```bash
WATCHED_REPOS="myorg/backend,myorg/frontend,myorg/shared-lib"
```

## Commands

### Initialize Watcher

```bash
foundry agent forgejo-watcher init <vm-name> [--no-register-hooks]
```

Loads `forgejo-watcher.json` when present, otherwise prompts for configuration. Automatically registers webhooks unless `--no-register-hooks` is given.

### Register Webhooks

```bash
foundry agent forgejo-watcher register-hooks <vm-name>
```

Creates webhooks on all watched repositories via the Forgejo API. Usually called automatically by `init`.

### Start Watcher

```bash
foundry agent forgejo-watcher start <vm-name> [--no-mark-all]
```

Starts the watcher daemon and webhook receiver in tmux sessions.

Before starting, it runs `mark-all` to suppress the existing open issue/PR backlog. Use `--no-mark-all` to process the backlog instead.

### Stop Watcher

```bash
foundry agent forgejo-watcher stop <vm-name>
```

Stops both the watcher and receiver.

### Check Status

```bash
foundry agent forgejo-watcher status <vm-name>
```

Shows:
- Watcher state
- Receiver state
- Configuration details
- Current task
- Processed task count

### View Logs

```bash
foundry agent forgejo-watcher logs <vm-name>          # Last 100 lines
foundry agent forgejo-watcher logs <vm-name> --follow # Tail mode
```

### Reset State

```bash
foundry agent forgejo-watcher reset <vm-name>
```

Clears all processed task history and queued events.

### Unregister Webhooks

```bash
foundry agent forgejo-watcher unregister-hooks <vm-name>
```

Removes the webhooks created by `register-hooks`.

## Task Priority

The watcher processes tasks with this priority:

1. **Trigger in PR review comments** - Fixes to existing PRs (highest priority)
2. **Trigger in issue/PR comments** - Follow-up requests
3. **Trigger in issue/PR body** - New tasks
4. **Pipeline failures on the default branch** - Automatic fixes for broken CI

Only one task is processed at a time. New events queue until the current task completes.

## Pipeline Auto-Fix

The watcher can listen for Forgejo Actions `workflow_run` events and automatically invoke the agent when a pipeline fails on the default branch.

### How it works

1. A workflow run completes with `conclusion=failure` on branch `main`.
2. Forgejo sends a `workflow_run` webhook to the receiver.
3. The watcher builds a `pipeline_failure` context that includes:
   - Workflow name, run ID, branch, and failing SHA
   - A summary of failed jobs and failed steps (fetched from the Forgejo API)
   - The repository clone URL
4. The configured agent receives a task prompt to:
   - Clone or use the local repository
   - Check out the failing SHA
   - Inspect the failure summary and reproduce the problem
   - Implement a minimal fix
   - Run the same checks locally
   - Push a fix branch and open a pull request

### Requirements

- The webhook registered by `register-hooks` must include the `workflow_run` event.
- The watcher token needs access to read Actions run details (`repository` read scope is sufficient).
- The default branch is currently hard-coded to `main`. If your default branch differs, set it in the project `forgejo-watcher.json` or override `DEFAULT_BRANCH` in the VM config.

### Disabling pipeline auto-fix

To disable auto-fix, unregister the webhook and re-register with only the desired events, or remove `workflow_run` from the event list in `templates/forgejo/forgejo_hook_manager.sh` before initializing the watcher.

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

1. Forgejo sends webhook payload for the new issue
2. Watcher detects `!ralph` and queues the event
3. Watcher builds the Ralph task file with full issue context
4. Watcher starts Ralph
5. Ralph:
   - Analyzes requirements
   - Creates branch `feat/dark-mode-support`
   - Implements toggle, state management, and styling
   - Runs tests
   - Creates PR with "Fixes #123" in description
6. Issue auto-closes when PR is merged

### Example 2: PR Review Feedback

**Reviewer comments on PR:**

```markdown
!ralph The OAuth token refresh logic is broken. Please fix:

1. Token expires after 1 hour but refresh happens after 2 hours
2. Error handling doesn't catch 401 responses
```

**What happens:**

1. Forgejo sends webhook payload for the PR comment
2. Watcher detects `!ralph` and queues the event
3. Watcher builds context including:
   - Full PR description
   - All review comments
   - Linked issue (if any)
4. Watcher starts Ralph
5. Ralph:
   - Checks out the PR branch
   - Fixes the token refresh timing
   - Adds 401 error handling
   - Runs tests
   - Pushes to the same branch
   - PR auto-updates

## State Management

### Processed Tasks

File: `/root/.config/forgejo-watcher/processed.json`

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
      "type": "issue_comment",
      "pr_number": 789,
      "comment_id": 12345,
      "processed_at": "2026-02-15T11:00:00Z",
      "result": "completed"
    },
    "workflow_run_42": {
      "type": "pipeline_failure",
      "run_id": 42,
      "repo": "myorg/backend",
      "branch": "main",
      "sha": "abc123",
      "processed_at": "2026-02-15T12:00:00Z",
      "result": "completed"
    }
  },
  "last_poll": "2026-02-15T11:30:00Z"
}
```

### Current Task

File: `/root/.config/forgejo-watcher/current_task.json`

Stores details of the task the agent is currently working on.

### Event Queue

Directory: `/root/.config/forgejo-watcher/queue/`

Validated webhook events are written here as JSON files until processed.

## Webhook Security

The receiver verifies webhook signatures using HMAC-SHA256 when a secret is configured. Set a strong, random secret and provide it in `forgejo-watcher.json`.

## Troubleshooting

### Watcher Not Starting

```bash
# Check if VM is running
foundry vm status <vm-name>

# Check if watcher is initialized
foundry vm ssh <vm-name> "ls -la /root/.config/forgejo-watcher/"

# Check logs for errors
foundry agent forgejo-watcher logs <vm-name>
```

### Webhooks Not Reaching the VM

```bash
# Check receiver session
foundry vm ssh <vm-name> "tmux has-session -t forgejo-receiver"

# Test connectivity from Forgejo host
curl -X POST http://<vm-ip>:8080/webhook -d '{}'

# Check receiver log
foundry vm ssh <vm-name> "tail -f /root/.config/forgejo-watcher/receiver.log"
```

### Agent Not Triggering

```bash
# Check if watcher sees the event
foundry agent forgejo-watcher status <vm-name>

# Verify token permissions
foundry vm ssh <vm-name> "curl -H 'Authorization: token <token>' https://<forgejo>/api/v1/user"

# Check if the autonomous agent is installed
foundry vm ssh <vm-name> "command -v ralph"   # for Ralph
foundry vm ssh <vm-name> "command -v kimi"    # for kimi-ralph
```

### Token Issues

```bash
# Re-create token file
foundry vm ssh <vm-name> "echo 'new_token' > /root/.config/forgejo-watcher/token && chmod 600 /root/.config/forgejo-watcher/token"
```

## Best Practices

1. **Use descriptive trigger mentions**
   - Include clear requirements
   - Link to relevant documentation
   - Specify expected behavior

2. **Monitor watcher logs regularly**
   ```bash
   foundry agent forgejo-watcher logs <vm> --follow
   ```

3. **Rotate tokens every 90 days**
   - Set calendar reminder
   - Use token expiration feature

4. **One VM per project/team**
   - Easier to manage
   - Clearer ownership
   - Better resource isolation

5. **Review agent PRs promptly**
   - Watcher continues with next task
   - PRs may need human review before merge

6. **Reset state when needed**
   - After fixing watcher bugs
   - When retrying failed tasks
   - Use `foundry agent forgejo-watcher reset`

## forgejo-cli in the VM

`forgejo-cli` is pre-installed in the VM as `fj`. It is a companion tool for agents that need to interact with Forgejo beyond what the watcher handles (e.g., creating releases, listing tags, fetching repo metadata).

### Authentication

`fj` supports OAuth login via:

```bash
fj auth login
```

This opens an authorization page in a browser. **This does not work in headless VMs** — the agent has no browser.

Instead, agents should use the Forgejo REST API directly via `curl` with the token that is already present in the VM:

```bash
FORGEJO_TOKEN=$(cat /root/.config/forgejo-watcher/token)
FORGEJO_URL=$(grep '^FORGEJO_INSTANCE_URL=' /root/.config/forgejo-watcher/config.conf | cut -d'"' -f2)

# Example: list open issues
curl -s -H "Authorization: token $FORGEJO_TOKEN" \
    "$FORGEJO_URL/api/v1/repos/owner/repo/issues?state=open"
```

The watcher config at `/root/.config/forgejo-watcher/config.conf` always contains the instance URL and the token file path, so agents can source both from there.

### Available instance support

The set of Forgejo instances that support OAuth via `fj auth login` depends on the installation. In practice, agents in foundry VMs should avoid `auth login` entirely and use the API token approach above, which works on all instances and requires no browser interaction.

### Common operations via API

```bash
# Post a comment on an issue
curl -s -X POST -H "Authorization: token $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"body\": \"Comment text\"}" \
    "$FORGEJO_URL/api/v1/repos/owner/repo/issues/1/comments"

# Create a release
curl -s -X POST -H "Authorization: token $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"tag_name\": \"v1.0.0\", \"name\": \"v1.0.0\"}" \
    "$FORGEJO_URL/api/v1/repos/owner/repo/releases"
```

The full API reference is at `<your-forgejo-instance>/api/swagger`.

## Architecture

For detailed architecture and design decisions, see:
- [Design Document](../docs/designs/2026-06-19-forgejo-watcher-integration.md)
- [Ralph Integration](../docs/RALPH-INTEGRATION.md)
