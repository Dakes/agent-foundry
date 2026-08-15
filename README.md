# Agent Foundry

> Isolated Docker Sandboxes for autonomous AI coding agents

Run AI coding agents in isolated sandboxes. Each project gets its own sandbox
and its own host directory, with multi-repo support, a reviewable network
posture, and unattended operation.

## Features

- **🤖 Autonomous or interactive** — `claude`, `gemini`, `codex` by hand, or
  their `/goal` loops running unattended
- **🔒 Isolated** — one sandbox per project, zero host pollution
- **📂 No sync step** — the volume root is a live-mounted host directory, and
  files the agent writes stay owned by you
- **🌐 Open internet, closed LAN** — enforced by policy, per-project
  exceptions written back into the project config
- **🔄 Multi-repo** — agents work across several repositories
- **🎯 Three verbs** — `init`, `up`, `down` cover the common path
- **💬 Forge-driven** — a comment on an issue or PR starts a run, with the
  task mode stated explicitly rather than guessed

## Quick Start

```bash
# Install (needs Docker Sandboxes: https://docs.docker.com/ai/sandboxes/)
git clone https://github.com/user/agent-foundry.git
cd agent-foundry
./install.sh --prefix ~/.local

# One-time, BY HAND: choose the sandbox network policy
sbx policy reset          # then choose "1. Open"

# Set up the host and build the agent image
foundry doctor --fix
foundry image build

# Create a project, add git keys and repos, run it
foundry init my-project
$EDITOR ~/.local/share/foundry/volumes/my-project/foundry.json
$EDITOR ~/.local/share/foundry/volumes/my-project/.ssh/config
foundry up my-project
foundry logs -f my-project
```

New here? **[GETTING-STARTED.md](docs/GETTING-STARTED.md)** walks the whole
path, including the Forgejo watcher.

## Architecture

```
Host
  ↓ foundry CLI  ──────────────►  sbx (Docker Sandboxes)
  ↓                                 ↓ egress policy: internet yes, LAN no
  ↓ ~/.local/share/foundry/volumes/<project>/   ← bind-mounted, same path
┌──────────────┬──────────────┬──────────────┐
│  sandbox 1   │  sandbox 2   │  sandbox 3   │
│  ├ repos/    │  ├ repos/    │  ├ repos/    │
│  ├ .ssh/     │  ├ .ssh/     │  ├ .ssh/     │
│  └ logs/     │  └ logs/     │  └ logs/     │
│  claude      │  claude-goal │  codex       │
└──────────────┴──────────────┴──────────────┘
```

No KVM, no TAP devices, no golden image: sandboxes are containers, and the
volume root is mounted at the same absolute path inside as on the host.

## Agent Backends

| Agent | Kind | Backed by |
|---|---|---|
| `claude` | interactive | `@anthropic-ai/claude-code` |
| `gemini` | interactive | `@google/gemini-cli` |
| `codex` | interactive | `@openai/codex` |
| `claude-goal` | autonomous | Claude Code's `/goal` |
| `codex-goal` | autonomous | Codex's `/goal` |
| `agy-goal` | autonomous | Antigravity CLI's `/goal` |

The `*-goal` agents need no image of their own — all three CLIs are in
`foundry-agent:base`. Each keeps working across turns until a completion
condition holds, so there is no loop for Foundry to run: a forge event supplies
the goal, and the CLI owns the iteration. See
[PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md#goal-mode-agents).

One agent per project, set with `.agent` in `foundry.json`. There is a single
image, `foundry-agent:base`, carrying every CLI.

A **watcher can only drive a `*-goal` agent**: it runs headless, and an
interactive CLI would sit waiting for a human nobody can provide.

## Use Cases

- **Forge-driven work**: comment `@yourbot implement ...` on an issue and the
  agent opens the pull request
- **Unattended work**: start an agent on a refactor, review progress later
- **Parallel development**: several sandboxes on different projects at once
- **Shared context**: `~/.local/share/foundry/shared/` is mounted read-only
  into every sandbox

## Project Layout

The volume root is the agent's home inside the sandbox, and a real directory
on the host:

```
<volume root>/
├── foundry.json     # project settings; init and up both read this
├── AGENT.md         # standing instructions, loaded by every agent CLI
├── repos/           # clones
│   ├── backend/
│   └── frontend/
├── secrets/         # tokens (0700)
├── logs/
├── .ssh/            # per-project git keys (0700)
└── .config/forgejo-watcher/    # watcher config and state, if configured
```

Nothing is copied in or out: the agent writes here directly, as your user.

## Task Modes

When a watcher triggers an agent from an issue, pull request, or comment, the
generated prompt carries an explicit **task mode** that decides what the agent
is allowed to do. You state it: the word straight after the trigger keyword.

```
@yourbot review     read the diff and comment; never pushes or opens a PR
@yourbot implement  new branch, code, pull request
@yourbot fix        push to the existing branch; never opens a new PR
@yourbot answer     comment only; changes nothing
```

`/review` and `mode: review` work anywhere in the comment too.

The mode is never inferred from phrasing. A request that states no mode gets a
hardcoded reply listing this syntax and **no agent is started** — asking costs
one comment, while guessing wrong costs an unwanted pull request, and what is
being guessed is which prohibitions the agent receives.

Every prompt also opens with an execution contract stating that the run is
headless, and that repo-level `AGENTS.md` / `CLAUDE.md` files are authoritative
for *how* to build and test but never for *whether* or *what* to do. This is
what stops agents from trying to open interactive sessions or from
implementing when asked to review.

See [PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md).

## Configuration

Project settings live in the volume root's `foundry.json`; host-wide defaults
in `~/.config/foundry/config.conf`. See
[PROJECT-SETUP.md](docs/PROJECT-SETUP.md).

### Resources

Defaults come from the sandbox runtime (all host CPUs, 50% of host memory).
Override globally with `DEFAULT_CPUS` / `DEFAULT_MEMORY`, or per project with
`.resources` in `foundry.json`.

### Network policy — a required manual step

Docker Sandboxes asks once, interactively, which network policy to install, and
there is no flag to script it. **Foundry cannot do this for you**, so do it
before the first project:

```bash
sbx policy reset          # choose "1. Open"
foundry doctor --fix      # then Foundry adds its own deny rules on top
```

Pick **Open**. Foundry's posture is "open internet, closed LAN": it wants full
egress from sbx and applies the LAN denials itself, which is what
`doctor --fix` sets up.

The other presets work, with one consequence worth knowing: **sbx gates DNS on
the policy**, so a host that is not allowed does not even resolve. On
*Balanced* or *Locked Down* an unlisted host fails with
`Could not resolve hostname` rather than a denial, which is a confusing way to
learn that a rule is missing. Project git remotes are allowed automatically;
anything else the agent needs — a package mirror, an internal API — you allow
by hand:

```bash
foundry policy allow registry.example.com
```

`foundry doctor` reports which preset is active.

### Standing instructions

`AGENT.md` in the volume root is where project-wide instructions go — the ones
that apply across every repository in the sandbox and that a per-repo
`AGENTS.md` cannot carry. `foundry init` symlinks `.claude/CLAUDE.md`,
`.gemini/GEMINI.md` and `.codex/AGENTS.md` at it, so each CLI loads it
natively.

### SSH keys

Per-project keys in the volume root's `.ssh/`, written by hand. Foundry never
reads `~/.ssh/` and never generates a key behind your back — `init` seeds a
commented `config` with the patterns to fill in, including a separate agent
identity on the same forge.

### Custom packages

Add to `config/packages.txt` and rebuild the image with `foundry image build`.

## CLI Commands

```bash
foundry init <project>     # volume root + config + policy + sandbox + clone
foundry up [project]       # start, publish ports, clone missing, start agent
foundry down [project]     # stop agent and sandbox, keep all state
foundry status [project]   # sandbox, agent, repos, ports, policy
foundry logs [project]     # -f to follow
foundry attach [project]   # attach to the agent's tmux session
foundry shell [project]    # shell inside the sandbox
foundry rm [project]       # remove the sandbox; volume root is kept
foundry doctor [project]   # check host, policy, ports, keys (--fix repairs)

foundry watcher <action>   # start | stop | status | logs | register
foundry policy <action>    # baseline | allow | deny | check | ls
foundry image <action>     # build | push
foundry config <action>    # get | set | edit | show
```

Full reference: [CLI-REFERENCE.md](docs/CLI-REFERENCE.md)

## Requirements

**Host system:**
- Linux (Arch, NixOS, Ubuntu, Fedora)
- Docker Sandboxes (`sbx`), signed in
- 4+ CPU cores, 16GB+ RAM recommended

**Dependencies:** `sbx`, `docker`, `jq`, `git`

**NixOS:** use the included `shell.nix`

## Documentation

- [GETTING-STARTED.md](docs/GETTING-STARTED.md) — **start here**: a complete first run
- [FORGEJO-WATCHER.md](docs/FORGEJO-WATCHER.md) — the watcher in depth
- [VISION.md](docs/VISION.md) — project goals and philosophy
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — complete architecture overview
- [PROJECT-SETUP.md](docs/PROJECT-SETUP.md) — creating and configuring projects
- [CLI-REFERENCE.md](docs/CLI-REFERENCE.md) — full command reference
- [PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md) — how agent prompts are built, and the rules that keep them consistent
- [TODO.md](TODO.md) — implementation roadmap

## Development

```bash
# For NixOS
nix-shell

# Validate shell scripts
./scripts/shellcheck.sh
./scripts/syntax-check.sh

# Validate prompt architecture and run prompt tests
./scripts/check-prompts.sh
./scripts/test-prompt-lib.sh

# Build the agent image
foundry image build
```

The release bundle is built automatically by `install.sh` if needed.

## Project Status

🚧 **Early development.** The sandbox core (project verbs, policy, images,
agents) and the Forgejo watcher are implemented and run on the sandbox
transport. There is no GitHub watcher.

See [TODO.md](TODO.md) for the roadmap.

## License

MIT License — See [LICENSE](LICENSE)

## Contributing

1. Read [VISION.md](docs/VISION.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)
2. Check [TODO.md](TODO.md) for open tasks
3. Create an issue or PR
4. Follow the existing code style

## Credits

Built on [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) •
Drives [Claude Code](https://github.com/anthropics/claude-code), Codex,
Gemini CLI and Antigravity CLI

---

**Note**: Agent Foundry is for development use only. Not intended for
production workload hosting.
