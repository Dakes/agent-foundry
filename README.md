# Agent Foundry

> Isolated Docker Sandboxes for autonomous AI coding agents

Run AI coding agents in isolated sandboxes. Each project gets its own sandbox
and its own host directory, with multi-repo support, a reviewable network
posture, and unattended operation.

## Features

- **🤖 Autonomous or interactive** — `claude`, `gemini`, `codex`, plus the
  Ralph family (`ralph`, `ralph-orchestrator`, `kimi-ralph`)
- **🔒 Isolated** — one sandbox per project, zero host pollution
- **📂 No sync step** — the volume root is a live-mounted host directory, and
  files the agent writes stay owned by you
- **🌐 Open internet, closed LAN** — enforced by policy, per-project
  exceptions written back into the project config
- **🔄 Multi-repo** — agents work across several repositories
- **🎯 Three verbs** — `init`, `up`, `down` cover the common path

## Quick Start

```bash
# Install (needs Docker Sandboxes: https://docs.docker.com/ai/sandboxes/)
git clone https://github.com/user/agent-foundry.git
cd agent-foundry
./install.sh --prefix ~/.local

# Set up the host and build the agent image
foundry doctor --fix
foundry image build

# Create a project, add git keys, run it
foundry init my-project
$EDITOR ~/.local/share/foundry/volumes/my-project/foundry.json
$EDITOR ~/.local/share/foundry/volumes/my-project/.ssh/config
foundry up my-project
foundry logs -f my-project
```

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
│  claude      │  ralph       │  codex       │
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
| `ralph` | autonomous | `frankbria/ralph-claude-code` |
| `ralph-orchestrator` | autonomous | `@ralph-orchestrator/ralph-cli` |
| `kimi-ralph` | autonomous | `kimi-code`, capped at 100 iterations |

One agent per project, set with `.agent` in `foundry.json`. The interactive
CLIs all live in `foundry-agent:base`; each autonomous runner gets its own
image tag (`foundry image build ralph`).

## Use Cases

- **Autonomous features**: define the mission in `PROMPT.md`, the agent
  implements it across repos
- **Unattended work**: start an agent on a refactor, review progress later
- **Parallel development**: several sandboxes on different projects at once
- **Shared context**: `~/.local/share/foundry/shared/` is mounted read-only
  into every sandbox

## Ralph File Structure

`ralph-claude-code` projects use this layout inside the volume root:

```
<volume root>/
├── .ralphrc                    # Config (optional, overrides default)
├── .ralph/
│   ├── PROMPT.md               # Mission: what to do
│   ├── fix_plan.md             # Tasks: - [ ] checklist
│   ├── AGENT.md                # Commands: npm test, etc
│   ├── specs/                  # Requirements (optional)
│   └── logs/                   # Execution logs
└── repos/
    ├── backend/
    └── frontend/
```

1. Ralph reads `PROMPT.md` → understands the mission
2. Reads `fix_plan.md` → gets the next task
3. Reads `AGENT.md` → knows how to test
4. Makes changes → runs tests → checks off the task
5. Repeats until done

For `ralph-orchestrator`, use a top-level `ralph.yml` and `PROMPT.md`.

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

- [VISION.md](docs/VISION.md) — project goals and philosophy
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — complete architecture overview
- [PROJECT-SETUP.md](docs/PROJECT-SETUP.md) — creating and configuring projects
- [CLI-REFERENCE.md](docs/CLI-REFERENCE.md) — full command reference
- [PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md) — how agent prompts are built, and the rules that keep them consistent
- [RALPH-INTEGRATION.md](docs/RALPH-INTEGRATION.md) — Ralph integration details
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
foundry image build [ralph|ralph-orchestrator|kimi-ralph]
```

The release bundle is built automatically by `install.sh` if needed.

## Project Status

🚧 **Early development.** The sandbox core (project verbs, policy, images,
agents) is implemented. Forge watchers are not yet ported to the sandbox
transport — `foundry up` publishes the receiver port and says so.

See [TODO.md](TODO.md) for the roadmap.

## License

MIT License — See [LICENSE](LICENSE)

## Contributing

1. Read [VISION.md](docs/VISION.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)
2. Check [TODO.md](TODO.md) for open tasks
3. Create an issue or PR
4. Follow the existing code style

## Credits

Built on [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) • Supports
[ralph-claude-code](https://github.com/frankbria/ralph-claude-code),
[ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator) and
[kimi-cli](https://github.com/MoonshotAI/kimi-cli) • Inspired by the Ralph
Wiggum technique

---

**Note**: Agent Foundry is for development use only. Not intended for
production workload hosting.
