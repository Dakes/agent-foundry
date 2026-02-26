# Agent Foundry - Architecture

## Overview

Agent Foundry is a framework for managing isolated Firecracker microVMs that run AI coding agents autonomously. Each VM is a self-contained development environment where agents can work 24/7 on projects without host system pollution.

## Core Principles

1. **Isolation** - Each project gets its own VM, no cross-contamination
2. **Reproducibility** - VMs built from scripts, snapshots for reuse
3. **Autonomy** - Agents run unattended with ralph-claude-code
4. **Flexibility** - Support multiple AI CLIs and concurrent VMs
5. **Portability** - System-agnostic host, works on any Linux

## Three-Layer Architecture

### Layer 1: Host System
- Any Linux with KVM/Firecracker support (NixOS, Ubuntu, Arch, etc.)
- Provides: Firecracker, networking (TAP devices), VM storage
- Framework CLI (`foundry`) manages everything from host

### Layer 2: VM Templates
- **Base template**: Official Firecracker Ubuntu 22.04 rootfs + kernel
- **Golden template**: Base + AI tools + authentication
- **Custom snapshots**: User-customized for specific needs

### Layer 3: Workspaces
- Self-contained project environments inside VMs
- Contains: repos, context files, agent memory, skills
- Portable across VMs, git-friendly structure

## Template System

### Base Template (`ubuntu-base.ext4`)
- Downloaded from official Firecracker resource bucket
- Kernel is built locally from Firecracker microVM config + Docker netfilter fragment
- Ubuntu 22.04 with essential cloud-init and networking
- SSH enabled with key-based auth
- No AI tools yet - pure OS foundation
- Built once, rarely updated

### Golden Template (`golden.ext4`)
- Base template + AI development stack
- Pre-installed: Claude Code CLI, Gemini CLI, OpenAI CLI
- ralph-claude-code system-wide installation in `/opt/ralph`
- Per-VM SSH keys for git authentication (generated at VM create time)
- Docker, Node.js, Python 3, development tools
- This is what users actually clone

### User Snapshots
- Golden template + company/project customizations
- Custom packages from `packages.txt`
- Company context files pre-loaded
- Additional tools for specific workflows
- Users create these for reuse

## Networking Architecture

### TAP-Based Networking Model
- Host gateway: `172.16.0.1/24`
- VM IP pool: `172.16.0.10-254` (245 VMs max)
- Each VM gets dedicated TAP device: `tap-agent-01`, `tap-agent-02`, etc.
- Static IP assignment inside VM
- NAT for internet access
- Direct SSH access: `ssh root@172.16.0.X`

### Network Lifecycle
1. VM Creation: Allocate IP, create TAP device, configure VM
2. VM Destruction: Delete TAP device, release IP, update registry

### VM Registry
Located at `~/.config/foundry/vms.json`:
```json
{
  "vms": {
    "my-project": {
      "ip": "172.16.0.11",
      "tap": "tap-agent-01",
      "disk": "/path/to/my-project.ext4",
      "status": "running",
      "pid": 12345
    }
  },
  "network": {
    "next_ip": "172.16.0.12",
    "next_tap_id": 2
  }
}
```

## Workspace Structure

Current runtime workspace lives in `/root` inside each VM:

```
/root/
├── repos/                      # Git repositories
├── .ralph/                     # Ralph config + plans
├── .claude/                    # Claude config (optional)
├── .codex/                     # Codex config (optional)
├── .gemini/                    # Gemini config (optional)
├── .ralphrc                    # Ralph runtime config
├── *.md                        # Top-level project docs
└── logs/
    └── ralph.log
```

## Agent Integration

### Supported Agent Types

1. **ralph** (Autonomous)
   - Continuous loop until tasks complete
   - Built-in tmux monitoring
   - Primary autonomous agent

2. **claude** (Interactive)
   - Claude Code CLI in screen session
   - Manual or script-driven

3. **gemini** (Interactive)
   - Google's Gemini CLI
   - Screen session for interaction

4. **codex** (Interactive)
   - OpenAI's Codex CLI
   - Screen session for interaction

### Skills Management

Each tool has its own skills directory:
- Claude Code: `/root/.claude/skills/`
- OpenAI Codex: `/root/.codex/skills/`
- Gemini CLI: `/root/.gemini/commands/`

Skills from `agent-foundry/skills/` are copied to appropriate locations during VM creation.

## CLI Interface

Host-based commands abstract VM complexity:

```bash
# VM management
foundry vm create <name>
foundry vm ssh <name>
foundry vm destroy <name>

# Agent management
foundry agent start <vm-name> <agent-type>
foundry agent logs <vm-name> --follow
foundry agent attach <vm-name>

# Templates
foundry template build base
foundry template build golden
```

## Resource Configuration

### Default Resources Per VM
- **CPU**: 4 vCPUs
- **RAM**: 8GB
- **Disk**: 20GB (expandable)

Configured via defaults in `config/default.conf` and user overrides in `~/.config/foundry/config.conf`.

## Data Storage

### Host Locations
```
~/.config/foundry/
├── config.conf              # User configuration
├── packages.txt             # Custom packages
└── vms.json                 # VM registry

~/.local/share/foundry/
├── vms/
│   ├── templates/           # VM templates
│   ├── instances/           # Running VMs
│   └── kernels/             # Firecracker kernels
└── logs/                    # Agent logs
```

## Implementation Modules

- `lib/vm.sh` - VM lifecycle functions
- `lib/agent.sh` - Agent management
- `lib/network.sh` - Networking setup
- `lib/template.sh` - Template building
- `lib/workspace.sh` - Workspace initialization
- `lib/config.sh` - Configuration management
- `lib/registry.sh` - VM registry operations
- `lib/utils.sh` - Common utilities

## Security Considerations

- SSH key-based authentication only (no passwords)
- Per-VM SSH key isolation with auto-generated keys in `~/.local/share/foundry/vms/<name>/ssh/`
- Foundry never reads `~/.ssh/` unless you explicitly pass `--ssh-key <path>`
- Isolated VM network namespaces
- NAT firewall for outbound traffic
- No inbound connections to VMs from internet
- Git authentication via dedicated per-VM SSH keys
- User-controlled VM lifecycle

## Extensibility

### Adding New Guest OS Support
1. Create build script in `scripts/build-<os>-base.sh`
2. Implement OS-specific package management in template builder
3. Add OS detection in VM initialization

### Adding New AI Agent Types
1. Install CLI in golden template
2. Add start/stop logic in `lib/agent.sh`
3. Configure skills directory mapping
4. Document in CLI reference

### Custom Template Variants
1. Create custom `packages.txt`
2. Build with `foundry template build <variant>`
3. Snapshot and reuse
