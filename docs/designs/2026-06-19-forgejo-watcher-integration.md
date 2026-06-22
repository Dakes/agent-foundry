# Forgejo Watcher Integration - Design Document

**Date:** 2026-06-19
**Status:** Approved for implementation

## Goal

Add a Forgejo-native integration to Agent Foundry that replaces the GitHub polling watcher with a real-time, webhook-driven workflow for self-hosted Forgejo instances.

## Background

The existing GitHub watcher is intentionally polling-based because Agent Foundry cannot install organization-wide webhooks on GitHub from a host-side CLI. With a self-hosted Forgejo instance, the user controls the forge and can create repository webhooks programmatically via the Forgejo API. This enables a true push integration.

## Architecture

```
┌────────────────────────────────────────┐
│ Forgejo instance (user-controlled)     │
│ - issues / pull requests / comments    │
│ - webhooks configured per repo         │
└────────────┬───────────────────────────┘
             │ POST webhook payload (JSON)
             │ X-Forgejo-Event
             │ X-Hub-Signature-256
             ▼
┌────────────────────────────────────────┐
│ Agent Foundry VM                       │
│ ┌───────────────────────────────────┐  │
│ │ forgejo_receiver.sh               │  │
│ │ - listens on TCP port             │  │
│ │ - verifies HMAC-SHA256 signature  │  │
│ │ - writes events to queue/         │  │
│ └───────────┬───────────────────────┘  │
│             │                          │
│             ▼                          │
│ ┌───────────────────────────────────┐  │
│ │ forgejo_watcher.sh                │  │
│ │ - reads queue                     │  │
│ │ - deduplicates                    │  │
│ │ - builds context via API          │  │
│ │ - invokes agent adapter           │  │
│ └───────────┬───────────────────────┘  │
│             │                          │
│             ▼                          │
│ ┌───────────────────────────────────┐  │
│ │ Agent adapter                     │  │
│ │ - ralph / ralph-orchestrator /    │  │
│ │   kimi-ralph                      │  │
│ └───────────────────────────────────┘  │
└────────────────────────────────────────┘
```

## Components

### forgejo_receiver.sh

A lightweight HTTP server implemented with `socat` (one process per connection model). It:

- Binds to `RECEIVER_INTERFACE:RECEIVER_PORT`
- Accepts `POST /webhook`
- Reads headers and body
- Verifies `X-Hub-Signature-256` when `WEBHOOK_SECRET` is configured
- Normalizes event type from `X-Forgejo-Event`, `X-Gitea-Event`, or `X-GitHub-Event`
- Writes `{event_type, received_at, payload}` to `/root/.config/forgejo-watcher/queue/event-<ts>-<rand>.json`
- Responds `200 OK` quickly to avoid Forgejo retries

### forgejo_watcher.sh

The orchestrator. It:

- Loads configuration from `/root/.config/forgejo-watcher/config.conf`
- Sources `forgejo_watcher_common.sh` and the agent adapter
- Starts `forgejo_receiver.sh` in a tmux session
- Polls the queue directory every few seconds
- Processes one event at a time
- Builds context JSON via Forgejo API
- Starts the agent in tmux session `ralph-loop`
- Posts reactions and error comments via Forgejo API
- Tracks processed tasks in `processed.json`

### forgejo_watcher_common.sh

Shared helpers:

- Logging
- Config loading
- Forgejo API client (`curl` + `jq`)
- State management (`processed.json`, `retries.json`)
- Context builders for issues and PRs
- Reaction and comment helpers

### forgejo_hook_manager.sh

Uses the Forgejo API to:

- `register`: create webhooks on all `WATCHED_REPOS`
- `unregister`: delete previously created webhooks
- `list`: show stored hook IDs

Hook IDs are stored in `/root/.config/forgejo-watcher/hooks.json`.

### Agent adapters

Forgejo-specific adapters reuse the same interface as the GitHub adapters:

- `prepare_agent_workspace <context_file>`
- `start_agent_loop()`
- `evaluate_agent_outcome [run_start_epoch]`

The input context JSON schema is identical to the GitHub watcher, so the adapters are nearly identical except for comments.

## API Mapping

| Operation | Forgejo API |
|-----------|-------------|
| Get issue | `GET /repos/{owner}/{repo}/issues/{index}` |
| Get PR | `GET /repos/{owner}/{repo}/pulls/{index}` |
| List issue comments | `GET /repos/{owner}/{repo}/issues/{index}/comments` |
| List PR comments | `GET /repos/{owner}/{repo}/pulls/{index}/comments` |
| Post comment | `POST /repos/{owner}/{repo}/issues/{index}/comments` |
| Add reaction | `POST /repos/{owner}/{repo}/issues/{index}/reactions` |
| Create webhook | `POST /repos/{owner}/{repo}/hooks` |
| Delete webhook | `DELETE /repos/{owner}/{repo}/hooks/{id}` |
| List workflow run jobs | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs` |

Authentication header: `Authorization: token <token>`

## Webhook Events

The integration subscribes to:

- `issues`
- `pull_request`
- `issue_comment`
- `pull_request_review_comment`
- `workflow_run`

On each event, the watcher inspects the relevant body for the configured trigger keyword (default `!ralph`).

For `workflow_run`, the watcher does not require a trigger keyword. When a run completes with `conclusion=failure` on the configured `DEFAULT_BRANCH` (default `main`), it builds a `pipeline_failure` context and starts the agent to diagnose and fix the failure.

## Security

- API token stored with `600` permissions
- Webhook secret stored with `600` permissions
- HMAC-SHA256 verification before processing
- Webhook events written to disk queue, not executed immediately
- No polling fallback that could leak tokens

## Network Requirements

Forgejo must be able to reach the VM on the receiver port. If the VM is behind NAT, the host must forward the port or place a reverse proxy in front of the receiver.

## Differences from GitHub Watcher

| Aspect | GitHub Watcher | Forgejo Watcher |
|--------|---------------|-----------------|
| Trigger detection | Polling every 60s | Webhook push |
| API client | `gh` CLI | `curl` + `jq` |
| Webhook registration | Not supported | Supported via API |
| Rate limits | GitHub's strict limits | Instance-controlled |
| Instance | github.com only | Any Forgejo instance |

## Future Enhancements

- Host-side webhook proxy mode for NAT/firewall scenarios
- Fine-grained workflow_run filtering by workflow name or path
