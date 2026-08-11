# Agent Foundry

> Lightweight, isolated microVMs for autonomous AI coding agents

Run AI coding agents 24/7 in isolated Firecracker VMs. Each project gets its own VM with full context, multi-repo support, and autonomous operation.

## Features

- **🤖 Autonomous** - supports `ralph-claude-code`, `ralph-orchestrator`, and `kimi-ralph`
- **🔒 Isolated** - Dedicated VM per project, zero host pollution
- **🚀 Concurrent** - Run unlimited VMs simultaneously
- **📚 Rich Context** - Company docs, standards, architecture included
- **🔄 Multi-Repo** - Agents work across multiple repositories
- **🎯 Simple CLI** - Host commands abstract VM complexity

## Quick Start

```bash
# Install
git clone https://github.com/user/agent-foundry.git
cd agent-foundry
./install.sh --prefix ~/.local

# Setup
foundry host setup
foundry template build base
foundry template build golden

# Create and run
foundry vm create my-project --project example-project
foundry agent start my-project ralph
foundry agent logs my-project --follow
```

## Autonomous Agent Backends

Agent Foundry supports multiple autonomous agent backends:

- `ralph` (backed by `frankbria/ralph-claude-code`)
- `ralph-orchestrator` (backed by `mikeyobrien/ralph-orchestrator`)
- `kimi-ralph` (backed by `MoonshotAI/kimi-cli` in Ralph mode, capped at 100 iterations)

Each VM may run only one autonomous agent at a time. For Ralph-backed images, configure template builds with:

```bash
# ~/.config/foundry/config.conf
RALPH_AGENT_VARIANT=ralph-claude-code
# or
RALPH_AGENT_VARIANT=ralph-orchestrator
```

Project examples:

- `projects/example-project/` (kimi-ralph)
- `projects/example-project-orchestrator/` (ralph-orchestrator)

## Architecture

```
Host System (Arch/NixOS)
  ↓ Foundry CLI
  ↓ Firecracker + TAP (172.16.0.0/24)
  ↓
┌─────────┬─────────┬─────────┐
│  VM 1   │  VM 2   │  VM 3   │
│  .11    │  .12    │  .13    │
│ /root/  │ /root/  │ /root/  │
│  ├repos │  ├repos │  ├repos │
│  └.ralph│  └.ralph│  └.ralph│
│ Ralph → │ Gemini  │ Codex   │
│ Claude  │  CLI    │  CLI    │
└─────────┴─────────┴─────────┘
```

## Use Cases

- **Autonomous Features**: Define in `PROMPT.md`, agent implements across repos
- **24/7 Work**: Start agent on refactoring, review progress in morning
- **Parallel Development**: Run 3-5 VMs on different projects simultaneously
- **Team Collaboration**: Share base templates with company standards

## Ralph File Structure

`ralph-claude-code` projects typically use this layout:

```
/root/                          # VM workspace
├── .ralphrc                    # Config (optional, overrides default)
├── .ralph/                     # Ralph files
│   ├── PROMPT.md              # Mission: what to do
│   ├── fix_plan.md           # Tasks: - [ ] checklist
│   ├── AGENT.md              # Commands: npm test, etc
│   ├── specs/                 # Requirements (optional)
│   └── logs/                  # Execution logs
└── repos/                      # Your code
    ├── backend/
    └── frontend/
```

**How it works:**
1. Ralph reads `PROMPT.md` → Understands mission
2. Reads `fix_plan.md` → Gets next task
3. Reads `AGENT.md` → Knows how to test
4. Makes changes → Runs tests → Checks off task
5. Repeats until all done

For `ralph-orchestrator`, use top-level `ralph.yml` and `PROMPT.md` (see `projects/example-project-orchestrator/`).

## Task Modes

When a watcher triggers an agent from an issue, pull request, or comment, the
generated prompt carries an explicit **task mode** that decides what the agent
is allowed to do. State it directly to remove all ambiguity:

```
/review          read the diff and comment; never pushes or opens a PR
/implement       new branch, code, pull request
/fix             push to the existing branch; never opens a new PR
/answer          comment only; changes nothing
```

`mode: review` and `@yourbot review` work too. Without a directive the mode is
inferred from the request's leading verb ("please review this MR" → `review`).
Requests with no clear intent fall back to a conservative `default` mode that
does the least destructive thing that satisfies the request.

Every prompt also opens with an execution contract stating that the run is
headless, and that repo-level `AGENTS.md` / `CLAUDE.md` files are authoritative
for *how* to build and test but never for *whether* or *what* to do. This is
what stops agents from trying to open interactive sessions or from
implementing when asked to review.

See [PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md).

## Configuration

### .ralphrc (Two-Tier System)

**Default** (`templates/.ralphrc.template`) - Full tool access, used when no project config exists

**Project-Specific** (`projects/your-project/.ralphrc`) - Overrides default

Customize: `ALLOWED_TOOLS`, `MAX_CALLS_PER_HOUR`, `CLAUDE_TIMEOUT_MINUTES`, circuit breaker thresholds

```bash
# Customize for a project
cp templates/.ralphrc.template projects/my-project/.ralphrc
vim projects/my-project/.ralphrc
foundry workspace sync my-vm my-project  # Apply to VM
```

### VM Resources

**Defaults:** 4 vCPUs, 8GB RAM, 20GB disk

**Override:**
- Global: `~/.config/foundry/config.conf`
- At create time: choose a different template and per-VM SSH key

### SSH Keys

Per-VM keypair in `~/.local/share/foundry/vms/<name>/ssh/`. Never reads `~/.ssh/` unless you pass `--ssh-key <path>`.

### Custom Packages

Add to `~/.config/foundry/packages.txt`:
```txt
postgresql
redis
go
rustup
```

## CLI Commands

```bash
# VM lifecycle
foundry vm create <name> [template] [--project <project>] [--ssh-key <path>]
foundry vm start <name>
foundry vm stop <name>
foundry vm ssh <name> [command]
foundry vm destroy <name>
foundry vm list
foundry vm status <name>
foundry vm update <name>

# VM operations
foundry vm copy <src> <dst>
foundry vm rename <old> <new>
foundry vm snapshot <name> <snapshot>

# Agent management
foundry agent start <vm> <agent-type>  # ralph, ralph-orchestrator, kimi-ralph, claude, gemini, codex
foundry agent stop <vm>
foundry agent restart <vm>
foundry agent logs <vm> [--follow]
foundry agent attach <vm>
foundry agent status <vm>
foundry agent gh-watcher <action> <vm>

# Workspace
foundry workspace init <vm> <config.json>
foundry workspace sync <vm> [project]
foundry workspace init-ralph <vm>
foundry workspace edit <vm> <file>
foundry workspace info <vm>
foundry workspace template [file]

# Templates
foundry template build base      # Downloads Ubuntu 22.04 base
foundry template build golden    # Configures AI tools (apt based)
foundry template list

# Host setup
foundry host setup
foundry host status

# Network
foundry network init
foundry network status
foundry network cleanup
```

Full reference: [CLI-REFERENCE.md](docs/CLI-REFERENCE.md)

## Requirements

**Host System:**
- Linux (Arch, NixOS, Ubuntu, Fedora)
- KVM enabled (hardware virtualization)
- 4+ CPU cores, 16GB+ RAM recommended
- 100GB+ disk space

**Dependencies:**
- Firecracker, QEMU utils (`qemu-img`), iproute2 (`ip`), iptables/nftables, jq, SSH, Git

**NixOS:** Use included `shell.nix`

## Documentation

- [VISION.md](docs/VISION.md) - Project goals and philosophy
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - Complete architecture overview
- [CLI-REFERENCE.md](docs/CLI-REFERENCE.md) - Full command reference
- [PROMPT-ARCHITECTURE.md](docs/PROMPT-ARCHITECTURE.md) - How agent prompts are built, and the rules that keep them consistent
- [RALPH-INTEGRATION.md](docs/RALPH-INTEGRATION.md) - Ralph integration details
- [REPO-REVIEW.md](docs/REPO-REVIEW.md) - Review findings and open items
- [TODO.md](TODO.md) - Implementation roadmap

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

# Build templates
./scripts/build-ubuntu-base.sh
```

Release bundle is built automatically by `install.sh` if needed.

## Project Status

🚧 **Early Development** - Core architecture defined, implementation in progress.

See [TODO.md](TODO.md) for roadmap.

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

1. Read [VISION.md](docs/VISION.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)
2. Check [TODO.md](TODO.md) for open tasks
3. Create issue or PR
4. Follow existing code style

## Credits

Built on [Firecracker](https://firecracker-microvm.github.io/) • Supports [ralph-claude-code](https://github.com/frankbria/ralph-claude-code), [ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator), and [kimi-cli](https://github.com/MoonshotAI/kimi-cli) • Inspired by the Ralph Wiggum technique

## Support

- **GitHub Issues**: Report bugs, request features
- **Discussions**: Ask questions, share setups
- **Wiki**: Community guides and tips

---

**Note**: Agent Foundry is for development use only. Not intended for production workload hosting.
