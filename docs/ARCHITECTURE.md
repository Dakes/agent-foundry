# Agent Foundry - Architecture

## Overview

Agent Foundry manages isolated [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
that run AI coding agents. Each project gets one sandbox and one host directory
— the *volume root* — that is bind-mounted into it. Agents work without
polluting the host, while the files they produce stay ordinary host files.

## Core Principles

1. **Isolation** — one sandbox per project, no cross-contamination
2. **The volume root is the workspace** — a live-mounted host directory, not a
   copy that needs syncing
3. **Idempotent reconciliation** — `foundry up` makes reality match
   `foundry.json`; run it any time
4. **Autonomy** — agents run unattended in a tmux session inside the sandbox
5. **Reviewable egress** — the network posture is policy, and every project
   exception is written back into the project's config

## Two-Layer Architecture

### Layer 1: Host

- Any Linux with Docker Sandboxes (`sbx`) installed. No KVM, no TAP devices,
  no golden image: sandboxes are containers.
- The `foundry` CLI manages sandboxes, network policy, volume roots and agents.
- Holds every piece of durable state, because the volume root lives here.

### Layer 2: Sandbox

- One container per project, created from the agent image.
- The volume root is mounted **at the same absolute path it has on the host**,
  so a path is valid on both sides — this is what removes the whole
  copy-in/copy-out layer the VM backend needed.
- Runs as an unprivileged user whose UID/GID match the host user's, so files
  written into the mount stay editable on the host.

## The Agent Image

Built from `docker/foundry-agent.Dockerfile`, replacing the old
base/golden/snapshot template pipeline. It carries **binaries only** — every
piece of per-project state (auth, agent memory, prompts, repos) lives in the
mounted volume root, so nothing needs baking per project.

- `foundry-agent:base` — git, tmux, node, gh, jq, ripgrep, plus the interactive
  CLIs (claude, gemini, codex). This is what most projects use.
- `foundry-agent:<variant>` — the above plus exactly one autonomous runner
  (`ralph`, `ralph-orchestrator`, `kimi-ralph`).

`foundry image build` also imports the result into the sandbox runtime's own
image store, which is separate from the local docker daemon's.

## Network Architecture

There is no host-managed network: no TAP devices, no IP pool, no NAT. What
Foundry manages instead is the **egress policy** enforced by the sandbox
proxy.

- The global policy is initialized `allow-all`, then every private, loopback
  and link-local range is explicitly denied.
- Result: the open internet is reachable — including a self-hosted forge on a
  public URL — while the LAN and the host are not.
- Per-project holes are derived from the project's git remotes and written
  back into `foundry.json`, so every exception is reviewable in a diff.
- Non-HTTP TCP (git over SSH on `:22`) needs an explicit `host:22` rule. UDP
  and ICMP are blocked at the network layer and cannot be allowed.
- These rules govern *egress only*: a service the agent starts on its own
  loopback inside the sandbox is unaffected.

Ports the outside world must reach (a webhook receiver) are published
explicitly. Port mappings do **not** survive a sandbox restart, which is why
`foundry up` re-applies them every time.

## Volume Root Structure

```
~/.local/share/foundry/volumes/<project>/
├── foundry.json            # agent, repos, resources, watcher, network rules
├── repos/                  # git repositories, cloned inside the sandbox
├── .ssh/                   # git keys + hand-editable config (700 / 600)
├── .foundry/               # generated start scripts
├── .ralph/ .kimi/ .claude/ # per-agent state, whichever applies
└── logs/                   # agent logs, readable directly on the host
```

`~/.local/share/foundry/shared/` is mounted read-only into every sandbox for
context you want available everywhere.

## Agent Integration

Agent types are defined in `lib/agent-registry.sh`, which is transport-agnostic
and survived the migration unchanged.

| Agent | Kind | Backed by |
|---|---|---|
| `claude` | interactive | `@anthropic-ai/claude-code` |
| `gemini` | interactive | `@google/gemini-cli` |
| `codex` | interactive | `@openai/codex` |
| `ralph` | autonomous | `frankbria/ralph-claude-code` |
| `ralph-orchestrator` | autonomous | `@ralph-orchestrator/ralph-cli` |
| `kimi-ralph` | autonomous | `kimi-code` |

Both kinds run in a tmux session inside the sandbox: autonomous agents run a
generated start script, interactive ones run the bare CLI so you can
`foundry attach`.

## CLI Interface

Thirteen commands, of which three cover the common path:

```bash
foundry init <project>     # volume root + policy + sandbox + clone
foundry up [project]       # start box, publish ports, clone, start agent
foundry down [project]     # stop agent and sandbox, keep all state

foundry status / logs / attach / shell / rm / doctor
foundry policy / image / config
```

See `docs/CLI-REFERENCE.md` for the full surface.

## Implementation Modules

- `lib/sandbox.sh` — the `sbx` wrapper: create/start/stop/rm/exec/publish
- `lib/policy.sh` — network baseline, rule derivation, policy matrix
- `lib/project.sh` — volume root scaffold, `foundry.json`, in-box cloning
- `lib/agent-sandbox.sh` — agent sessions over `sbx exec`
- `lib/agent-registry.sh` — agent type definitions and metadata
- `lib/commands.sh` — the verb layer
- `lib/config.sh` — configuration management
- `lib/utils.sh` — common utilities

## Security Considerations

- Egress is open to the internet but closed to the LAN, the host and
  link-local/metadata space.
- Git keys live in the project's `.ssh/`, are never read from `~/.ssh`, and are
  set up by hand — `init` seeds a commented `config` and warns when repos are
  declared without a key.
- The agent runs unprivileged inside the sandbox, as the host user's UID.
- The first `git clone` happens inside the box on purpose: it exercises the key
  and the policy before any agent starts.

## Extensibility

### Adding a new AI agent type
1. Add the agent to `lib/agent-registry.sh`
2. Provide a start-script template under `templates/<agent>/` if autonomous
3. Add a watcher adapter under `templates/<agent>/` if it should react to
   forge events
4. Add its install step to `docker/foundry-agent.Dockerfile`
5. Document it in the CLI reference

### Customizing the image
1. Add packages to `config/packages.txt`
2. Rebuild with `foundry image build [variant]`
3. Or set `.image` in a project's `foundry.json` to use your own tag
