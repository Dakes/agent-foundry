# Agent Foundry

> Lightweight, isolated microVMs for autonomous AI coding agents

Run AI coding agents 24/7 in isolated Firecracker VMs. Each project gets its own VM with full context, multi-repo support, and autonomous operation.

## Features

- **🤖 Autonomous** - ralph-claude-code runs unattended with safeguards
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

See `projects/example-project/.ralph/` for complete example.

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
foundry agent start <vm> <agent-type>  # ralph, claude, gemini, codex
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
- [RALPH-INTEGRATION.md](docs/RALPH-INTEGRATION.md) - Ralph-claude-code details
- [TODO.md](TODO.md) - Implementation roadmap

## Development

```bash
# For NixOS
nix-shell

# Run tests
# (tests are not fully scaffolded yet)

# Build templates
./scripts/build-ubuntu-base.sh
```

## Docker Bridge Networking Kernel (Option C)

Base template builds now compile a Firecracker kernel using the upstream microVM
config plus `config/kernel/docker-netfilter.fragment` so Docker bridge NAT works
inside guest VMs.

Validation commands:

```bash
# Rebuild base template + kernel
sudo foundry template build base

# Confirm VM is using the built kernel and inspect baked config
ls -lh ~/.local/share/foundry/vms/kernels/vmlinux
grep -E '^(CONFIG_NETFILTER|CONFIG_NF_TABLES|CONFIG_IP_NF_NAT|CONFIG_BRIDGE_NETFILTER)=' \
  ~/.local/share/foundry/vms/kernels/vmlinux.config
```

Practical smoke test (inside a VM):

```bash
foundry vm create net-smoke --project example-project
foundry vm start net-smoke

# Build and run with default Docker bridge networking
foundry vm ssh net-smoke 'cat > /root/Dockerfile <<EOF
FROM busybox:1.36
CMD ["sh", "-c", "ip route && wget -qO- https://ifconfig.me || true"]
EOF
docker build -t net-smoke:latest /root
docker run --rm net-smoke:latest'

# Optional compose test
foundry vm ssh net-smoke 'cat > /root/compose.yaml <<EOF
services:
  web:
    image: busybox:1.36
    command: ["sh", "-c", "ip route && wget -qO- https://ifconfig.me || true"]
EOF
docker compose -f /root/compose.yaml up --abort-on-container-exit'
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

Built on [Firecracker](https://firecracker-microvm.github.io/) • Uses [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) • Inspired by the Ralph Wiggum technique

## Support

- **GitHub Issues**: Report bugs, request features
- **Discussions**: Ask questions, share setups
- **Wiki**: Community guides and tips

---

**Note**: Agent Foundry is for development use only. Not intended for production workload hosting.
