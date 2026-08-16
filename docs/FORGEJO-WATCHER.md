# Forgejo Watcher

Turns comments on your Forgejo instance into agent runs. Someone writes
`@yourbot implement ...` on an issue; the agent opens the pull request.

For a first setup, follow
[GETTING-STARTED.md § 8](GETTING-STARTED.md#8-add-the-watcher-optional). This
document is the reference: how it works, every setting, and what to do when it
misbehaves.

## How it works

Webhooks, not polling — events arrive as they happen:

1. Someone comments `@yourbot review this` on an issue or pull request.
2. Forgejo POSTs to the **receiver**, which listens inside the sandbox on
   `receiver_port` and answers `POST /webhook` only.
3. The receiver verifies the HMAC-SHA256 signature and writes the event to a
   queue directory. An unsigned or wrongly signed request is dropped here,
   before anything reads its contents.
4. The **watcher loop** picks the event up, resolves the task mode from the
   word after the keyword, and builds the prompt.
5. It starts the agent in a tmux session and waits.
6. The agent works, pushes, opens a pull request, and the watcher posts the
   result back as a comment.

Inside the sandbox, `forgejo-receiver` is the listener and `foundry-work` is
the agent run. The watcher loop itself runs as a **foreground exec held open
from the host** - see below.

### Why a host-side supervisor

sbx stops a sandbox about a minute after the last exec returns, and what runs
*inside* does not count as activity: a detached session holds nothing open. A
watcher waiting for webhooks is idle by definition, so running it inside and
letting go meant the sandbox stopped underneath it - and the forge got
"connection refused" from a project that looked perfectly up.

So `foundry up` starts a small supervisor on the host
(`.config/forgejo-watcher/supervisor.sh`). It keeps one exec in the foreground,
which is what holds the sandbox open, and restarts the watcher - and the
sandbox - if either stops. It is detached with `setsid`, so it survives the
command finishing and the terminal closing. Its pid is in `supervisor.pid`,
its log in `supervisor.log`, and `foundry watcher status` reports on it.

Five quick failures in a row and it gives up rather than restarting a broken
config forever; the reason is in `supervisor.log`.

**One task at a time.** New events queue until the current run finishes.

### It starts from now, not from the backlog

Whatever is already queued when the watcher starts is discarded, and work
created before it started is recorded as seen rather than acted on. A watcher
coming back after an outage cannot tell a request from five minutes ago from
one from last month, and answering a month of them at once is never what was
wanted - the forge redelivers failed hooks, so the backlog can be large.

`foundry watcher logs` shows the cutoff on every start. Set
`WATCHER_PROCESS_BACKLOG=true` in the environment to take the queue as it
stands instead.

### It ignores its own comments

Every reply the watcher writes tends to contain the trigger keyword - the
usage reply lists it by definition - so acting on its own events means
answering itself as fast as the forge accepts comments. It resolves the
account its token belongs to and drops events authored by it, and **refuses to
start** if it cannot determine that account, because running without it means
looping.

A second guard caps replies per thread (5 in 5 minutes, `REPLY_CAP_PER_WINDOW`
and `REPLY_WINDOW_SECONDS`). That covers the case the account check cannot:
another bot, or a mirror, echoing the keyword back.

## Requirements

- `.agent` must be a **goal agent** — `claude-goal`, `codex-goal` or
  `agy-goal`. The watcher runs headless, so an interactive CLI would sit
  waiting for a human. Foundry refuses the combination rather than hanging.
- A Forgejo token in the volume root (see [Token](#token)).
- Forgejo must be able to **reach the receiver**. The port is published to the
  host; `public_url` is how the forge addresses it.

## Configuration

Everything lives in `foundry.json` under `.watcher`:

```json
{
  "agent": "claude-goal",
  "watcher": {
    "kind": "forgejo",
    "instance_url": "https://git.example.com",
    "receiver_port": 9174,
    "trigger_keyword": "@mybot",
    "watched_repos": ["you/backend", "you/frontend"],
    "token_file": "secrets/forgejo-token.txt",
    "public_url": "http://localhost",
    "agent_timeout": 120,
    "dry_run": false
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `kind` | yes | `forgejo` — the only supported watcher |
| `instance_url` | yes | Your Forgejo instance, for API calls |
| `receiver_port` | yes | The port the receiver **listens on**, ≥ 1024 |
| `trigger_keyword` | yes | What people type to summon the agent |
| `watched_repos` | yes | `owner/repo` entries |
| `token_file` | yes | Path to the token, relative to the volume root |
| `user` | no | The account the token belongs to. Looked up from the token when absent; set it when your instance refuses that lookup, since the watcher will not start without knowing which events are its own |
| `public_url` | for registration | The receiver **as Forgejo sees it** |
| `agent_timeout` | no | Minutes before a run is abandoned (default 120) |
| `dry_run` | no | Process events and log, but start no agent |
| `process_backlog` | no | Act on work that predates the watcher's start (default: no) |

### receiver_port is inbound

It is the port Forgejo **POSTs to**, not one the watcher talks to. It must be
1024 or above: the sandbox runs the watcher unprivileged, so a privileged port
cannot be bound.

### public_url

Only you know how your forge addresses the machine running Foundry, so this is
the one part that can't be derived. The port and the `/webhook` path are
appended when missing:

| You write | Registered as |
|---|---|
| `http://localhost` | `http://localhost:9174/webhook` |
| `foundry.example.com` | `http://foundry.example.com:9174/webhook` |
| `https://foundry.example.com/webhook` | unchanged — a reverse proxy in front |

The path matters: the receiver answers `POST /webhook` and refuses everything
else, so a hook registered without it delivers successfully from Forgejo's
point of view and is rejected on arrival.

### When the forge runs in a container

`localhost` then means *the forge's own container*, not your host, and the
webhook fails with `connection refused` even though the receiver is fine. Use
the address the container reaches the host on - its default gateway:

```bash
docker compose exec forgejo sh -c 'ip route | grep default'   # -> default via 172.22.0.1
```

Then `"public_url": "http://172.22.0.1:9174/webhook"`. On a compose stack with
several networks those subnets can renumber when the stack is recreated; adding
`extra_hosts: ["host.docker.internal:host-gateway"]` to the forge service and
using `http://host.docker.internal:9174/webhook` survives that.

Prefer an IP to `localhost` in general: the receiver listens on IPv4, and
`localhost` can resolve to `::1`, which fails with `dial tcp [::1]` even when
nothing is containerized.

### Generated config

On every `foundry up`, Foundry writes
`<volume root>/.config/forgejo-watcher/config.conf` from `foundry.json`. It is
**generated** — edit `foundry.json` instead; your changes there are overwritten
on the next `up`.

## Token

Forgejo: **Settings → Applications → Generate New Token**.

| Scope | Needed for |
|---|---|
| `read:issue`, `write:issue` | reading comments, replying |
| `read:repository`, `write:repository` | pull requests |
| `write:admin` (repo) | `foundry watcher register` only |

Put it in the file named by `token_file`, mode 600, contents only:

```bash
install -m 600 /dev/null secrets/forgejo-token.txt
$EDITOR secrets/forgejo-token.txt
```

Foundry also uses this token to log `fj` (forgejo-cli) into the instance on
`up`, so the agent can use it without a separate setup.

## Webhook registration

### Automatic

```bash
foundry watcher register my-project     # needs the admin scope
foundry watcher list my-project         # what is registered
foundry watcher unregister my-project
```

Registration is idempotent: an existing hook with the same URL is left alone.

### By hand

Repository → **Settings → Webhooks → Add Webhook → Forgejo**:

| Field | Value |
|---|---|
| Target URL | your `public_url`, with port and `/webhook` |
| HTTP Method | `POST` |
| POST Content Type | `application/json` |
| Secret | output of `foundry watcher secret <project>` — **not** the API token |
| Trigger On | Issues, Issue Comment, Pull Request, Pull Request Comment |
| Active | ✓ |

The secret is generated on the first `up` and then kept — regenerating it
would silently invalidate every hook already registered.

**It is not the API token.** `.config/forgejo-watcher/` holds both: `token`
(Foundry authenticating to the forge) and `webhook-secret` (the forge proving
a delivery is genuine). The token in the Secret field yields a well-formed
signature that can never match, logged as `Invalid webhook signature` like any
other failure. `foundry watcher secret` prints the right value, and
`foundry watcher register` sets it on the forge for you.

## Commands

```bash
foundry watcher status <project>      # config summary and whether it runs
foundry watcher logs <project>        # follow the watcher log
foundry watcher secret <project>      # the value the forge's Secret field needs
foundry watcher start <project>       # up starts it; this is for after a stop
foundry watcher stop <project>
foundry watcher restart <project>
foundry watcher register <project>    # also: unregister, list
```

`foundry up` starts the watcher whenever one is configured, and `foundry down`
stops it. Starting it by hand is only needed after an explicit stop — a forge
that gets a connection refused does not retry, so a watcher that has to be
started manually silently drops work.

## Task modes

The mode is the word after the keyword, and it decides what the agent may do:

| Comment | The agent |
|---|---|
| `@mybot review ...` | reads the diff and comments; never pushes, never opens a PR |
| `@mybot implement ...` | new branch, code, pull request |
| `@mybot fix ...` | pushes to the existing branch; never opens a new PR |
| `@mybot answer ...` | comments only; changes nothing |

`/review` and `mode: review` also work anywhere in the comment.

A comment stating no mode gets a reply listing this syntax and **starts no
agent**. The mode is never inferred from phrasing: what is being chosen is
which prohibitions the agent receives, and guessing wrong costs an unwanted
pull request. See [PROMPT-ARCHITECTURE.md](PROMPT-ARCHITECTURE.md).

## Priority

1. Trigger in a PR review comment — fixes to an existing PR
2. Trigger in an issue or PR comment — follow-ups
3. Trigger in an issue or PR body — new work

## State

Under `<volume root>/.config/forgejo-watcher/`:

| File | What |
|---|---|
| `config.conf` | generated from `foundry.json` |
| `token`, `webhook-secret` | secrets, mode 600 |
| `processed.json` | events already handled, so nothing runs twice |
| `retries.json` | rate-limit backoff |
| `queue/` | validated events waiting their turn |
| `current_task.json`, `current_context.json` | the run in flight |
| `supervisor.sh`, `supervisor.pid` | the host-side supervisor |
| `watcher.log`, `receiver.log`, `supervisor.log` | logs |

Because the volume root is a host directory, all of this survives the sandbox
being stopped, recreated, or rebuilt — which is what makes "already processed"
mean anything across restarts.

## Security

- Webhook payloads are rejected unless the HMAC-SHA256 signature matches the
  shared secret, before the body is parsed.
- Untrusted text from issues and comments is fenced in the generated prompt so
  it reads as data rather than instructions.
- The token and secret live in mode-600 files, never in `config.conf`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Watcher exits right after start | Config failed to validate. Read `watcher.log`; the error names the field. |
| Forgejo shows a delivery error | The forge cannot reach `public_url`. Check the host and port from the forge's side. |
| Delivery succeeds, nothing happens | Wrong secret, or the URL is missing `/webhook`. `receiver.log` shows rejections. |
| `Unsupported watcher agent type` | `.agent` is interactive; use a `*-goal` agent. |
| Nothing on a comment that looks right | The mode word is missing — check for the help reply on the issue. |
| Runs repeat after a restart | `processed.json` was deleted with the volume root. |
| Agent dies with `Invalid API key · Fix external API key` | sbx exports `ANTHROPIC_API_KEY=proxy-managed` into every sandbox, and a key beats a logged-in account. Foundry strips that placeholder; if you see this, the image predates the fix — rebuild it. |

```bash
foundry watcher status <project>
foundry watcher logs <project>
tail -f <volume root>/.config/forgejo-watcher/receiver.log
```

## Architecture

```
Forgejo ──POST /webhook──► published port
                              │
                    ┌─────────▼──────────── sandbox ─────────┐
                    │  forgejo-receiver  (verify HMAC, queue) │
                    │           │                             │
                    │           ▼                             │
                    │  forgejo-watcher   (mode, prompt)       │
                    │           │                             │
                    │           ▼                             │
                    │  foundry-work      (the agent run)      │
                    └──────────────────────────────────────────┘
                              │
                    comment posted back via the API
```

The scripts live in the image at `/opt/foundry/forgejo/`; their configuration
and state live in the volume root. One image serves every project.
