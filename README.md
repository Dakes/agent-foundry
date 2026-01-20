# Agent Foundry

> Lightweight, isolated microVMs for autonomous AI coding agents

Agent Foundry is a framework for managing Firecracker microVMs where AI coding agents work autonomously on your projects. Each VM is an isolated development environment with rich context, allowing agents to code 24/7 while you focus on architecture and review.

## Features

- **🤖 Autonomous Agents** - ralph-claude-code runs unattended with built-in safeguards
- **🔒 Isolated Environments** - Each project gets dedicated VM, no host pollution
- **🚀 Multiple Concurrent VMs** - Run unlimited projects simultaneously
- **📚 Rich Context** - Workspaces include company docs, standards, architecture
- **🔄 Multi-Repo Support** - Agents work across multiple repositories seamlessly
- **💾 Reproducible** - Templates and snapshots for instant project setup
- **🎯 Simple CLI** - Host-based commands abstract VM complexity
- **🔌 Pluggable** - Support for Claude Code, Gemini CLI, OpenAI Codex

## Quick Start

```bash
# Clone and install (automatically builds release bundle)
git clone https://github.com/user/agent-foundry.git
cd agent-foundry
./install.sh --prefix ~/.local

# Setup host
foundry host setup

# Build templates
foundry template build base
foundry template build golden --ssh-key ~/.ssh/id_agent

# Create VM
foundry vm create my-project --config workspace.json

# Start autonomous agent
foundry agent start my-project ralph-claude-code

# Monitor
foundry agent logs my-project --follow

# Attach anytime
foundry agent attach my-project
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Host System (Arch/NixOS)              │
│  ┌────────────────────────────────────────────────────┐ │
│  │         Foundry CLI (bin/foundry)                  │ │
│  │  vm create | agent start | agent logs | vm ssh    │ │
│  └────────────────────────────────────────────────────┘ │
│                           │                              │
│  ┌────────────────────────▼────────────────────────┐   │
│  │         Firecracker + TAP Networking             │   │
│  │  172.16.0.1 → 172.16.0.10-254                    │   │
│  └────────────────────────┬────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
   ┌────▼─────┐        ┌────▼─────┐        ┌────▼─────┐
   │  VM 1    │        │  VM 2    │        │  VM 3    │
   │ .11      │        │ .12      │        │ .13      │
   │          │        │          │        │          │
   │ /work/   │        │ /work/   │        │ /work/   │
   │ project1/│        │ frontend/│        │ backend/ │
   │  ├repos/ │        │  ├repos/ │        │  ├repos/ │
   │  ├context│        │  ├context│        │  ├context│
   │  └memory/│        │  └memory/│        │  └memory/│
   │          │        │          │        │          │
   │ Ralph →  │        │ Gemini → │        │ Codex →  │
   │ Claude   │        │ CLI      │        │ CLI      │
   └──────────┘        └──────────┘        └──────────┘
```

## Use Cases

### Autonomous Feature Development
Define feature in `PROMPT.md`, start ralph-claude-code, agent implements across repos and commits to branch. Review and merge.

### 24/7 Background Work
Start agent on complex refactoring, log out. Agent works overnight. Review progress in morning.

### Parallel Development
Run 3-5 VMs with different agents on different projects. Maximize AI subscription usage.

### Team Collaboration
Create company base template with standards. Everyone starts from same foundation.

## Documentation

- **[VISION.md](docs/VISION.md)** - Project vision and goals
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Complete architecture overview
- **[CLI-REFERENCE.md](docs/CLI-REFERENCE.md)** - Command reference
- **[RALPH-INTEGRATION.md](docs/RALPH-INTEGRATION.md)** - Ralph-claude-code integration details
- **[TODO.md](TODO.md)** - Implementation roadmap

## Requirements

### Host System
- Linux (Arch, NixOS, Ubuntu, Fedora, etc.)
- KVM enabled (hardware virtualization)
- 4+ CPU cores recommended
- 16GB+ RAM recommended
- 100GB+ disk space

### Dependencies
- Firecracker
- QEMU utilities (`qemu-img`)
- iproute2 (`ip` command)
- iptables or nftables
- jq
- SSH client
- Git

*Note: tmux and screen are only needed inside VMs for agent management, not on the host*

For NixOS hosts, use included `shell.nix`.

## Configuration

### Default Resources per VM
- **CPU**: 50% of host cores
- **RAM**: 8GB
- **Disk**: 20GB

Configurable via:
- Global: `~/.config/foundry/config.conf`
- Per-VM: `workspace.json`
- CLI flags: `--cpus 8 --memory 16384`

### Custom Packages
Add packages to `~/.config/foundry/packages.txt`:
```txt
# Additional packages for my VMs
postgresql
redis
go
rustup
```

## Workspace Structure

```
/work/<project-name>/
├── PROMPT.md                   # Ralph instructions
├── @fix_plan.md               # Task list
├── repos/                      # Git repositories
│   ├── backend/
│   ├── frontend/
│   └── shared-lib/
├── context/                    # AI context files
│   ├── company.md
│   ├── instructions.md
│   └── architecture.md
├── memory/                     # Agent memory
│   ├── progress.md
│   └── decisions.md
└── workspace.json              # Configuration
```

## CLI Commands

```bash
# VM lifecycle
foundry vm create <name>
foundry vm start <name>
foundry vm stop <name>
foundry vm ssh <name>
foundry vm destroy <name>

# VM operations
foundry vm copy <src> <dst>
foundry vm rename <old> <new>
foundry vm snapshot <name> <snapshot>

# Agent management
foundry agent start <vm> <agent-type>
foundry agent stop <vm>
foundry agent logs <vm> --follow
foundry agent attach <vm>
foundry agent status --all

# Templates
foundry template build base      # Downloads Ubuntu 22.04 base
foundry template build golden    # Configures AI tools (apt based)

# Host setup
foundry host setup
foundry host status
```

## Development

```bash
# For NixOS hosts
nix-shell

# For other Linux
# Install dependencies manually

# Run tests
./tests/run-all.sh

# Build templates (from repo)
./scripts/build-arch-base.sh
```

**Note**: The release bundle is built automatically by `install.sh` if needed.

## Project Status

🚧 **Early Development** - Core architecture defined, implementation in progress.

See [TODO.md](TODO.md) for roadmap.

## License

MIT License - See [LICENSE](LICENSE) file

## Contributing

Contributions welcome! This is a community-driven project.

1. Read [VISION.md](docs/VISION.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)
2. Check [TODO.md](TODO.md) for open tasks
3. Create issue or PR
4. Follow existing code style

## Credits

- Built on [Firecracker](https://firecracker-microvm.github.io/)
- Uses [ralph-claude-code](https://github.com/frankbria/ralph-claude-code)
- Inspired by the Ralph Wiggum technique

## Support

- GitHub Issues: Report bugs, request features
- Discussions: Ask questions, share setups
- Wiki: Community guides and tips

---

**Note**: Agent Foundry is for development use. Not intended for production workload hosting. Use proper container orchestration (Kubernetes, Docker Swarm) for production.
