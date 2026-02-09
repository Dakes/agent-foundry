# Notes: Agent Foundry Design

## Sources

### Source 1: SUMMARY.md (User-provided vision document)
- Comprehensive guide for Firecracker + Arch Linux microVMs
- Detailed networking setup (TAP devices, NAT, static IPs 172.16.0.x)
- AI agent tooling: Amp CLI with Ralph Wiggum loop
- Git workflow: SSH keys, branch-based work, push to remote
- Self-contained VMs (no external volumes)
- SSH access for manual intervention

## Key Requirements from SUMMARY.md

### Infrastructure
- Firecracker for lightweight KVM-based VMs
- Reproducible image builds (no untrusted prebuilt images)
- TAP networking with NAT for internet access
- SSH access to VMs from host

### Guest OS (Arch Linux focus)
- Base system via pacstrap
- Pre-installed: base-devel, git, openssh, nodejs, python, jq
- Networking via systemd-networkd (static IP)
- SSH server enabled, key-based auth only

### AI Agent Tooling
- Amp CLI (Claude interface)
- Ralph Wiggum loop (autonomous coding agent)
- PRD and Ralph skills for Amp
- Git configured for commits and pushes

### Workflow
1. Build base image (automated, reproducible)
2. Boot once, install agent tools, authenticate (manual)
3. Snapshot as "golden template"
4. Clone template per project
5. Boot VM, clone repos, run agent loop
6. Push branch to remote for review
7. Cleanup (delete VM)

## User Clarifications

### Host System
- Production: Arch Linux server
- Development: NixOS (need nix-shell file)
- Framework must be system-agnostic (Linux only)

### Guest OS Support
- Priority: Arch Linux
- Future: Ubuntu, Fedora (design for extensibility)

### AI Tools (UPDATED - Ignore Amp)
- **Primary coding CLI**: Claude Code (Anthropic's official CLI)
- **Additional CLIs**: OpenAI Codex, Gemini CLI
- **Autonomous agent**: Ralph Wiggum-inspired loop (actual Ralph when it supports Claude)
- **NOT using**: Amp CLI (ignore from SUMMARY.md)

### Ralph Wiggum Strategy - UPDATED!
- **Using**: https://github.com/frankbria/ralph-claude-code (3.5k stars)
- **Purpose**: Autonomous development framework wrapping Claude Code CLI
- **Architecture**: Two-phase install (system-wide + per-project setup)
- **Operation**: Reads PROMPT.md, runs Claude Code cycles until completion
- **Features**:
  - Dual-condition exit gate (completion heuristics + explicit EXIT_SIGNAL)
  - Advanced circuit breaker (prevents infinite loops)
  - Session continuity (preserves context across iterations)
  - Rate limiting (100 calls/hour, configurable)
  - tmux-based monitoring
- **Dependencies**: Bash 4.0+, Claude Code CLI (npm), tmux, jq, git
- **Project structure**: PROMPT.md, fix_plan.md, specs/, src/, logs/

### Skills System
- Skills folder in repo (not tracked)
- .gitignore it so users can add their own
- Extensible/pluggable skills architecture

### Developer Environment
- Full dev environment with most useful tools
- Docker pre-installed
- Comprehensive toolchain for AI agents to work with

### Usage Pattern
- Start agent in VM
- Log out while keeping VM running (daemon/background mode)
- Agent continues working autonomously

### Custom Instructions
- Project/company/domain-specific instructions
- Should be added into VM container
- Used as context for AI models
- Need to design injection mechanism

### VM Concurrency & Resources
- **Unlimited concurrent VMs** - Start as many as resources allow
- **Default resources per VM**: 50% of host CPU cores, 8GB RAM
- **Configurable**: Users can override per-VM or globally
- **Dynamic allocation**: IP addresses, TAP devices auto-assigned
- **Resource awareness**: Framework should warn if resources insufficient

### Workspace Architecture
- **Workspace = Project entrypoint** - Main folder in VM containing everything
- **Workspace structure**:
  - One or multiple git repositories
  - LLM prompt files (instructions for agents)
  - Company/product description files
  - Agent memory files (agents can read/write)
  - Project-specific context
- **Benefits**: Self-contained, portable, agents have full context
- **Location**: `/work/<project-name>/` in VM

### Git Authentication
- **Pre-configured SSH keys** - User provides SSH keys on host
- **Copied into VM template** - Keys baked into golden template
- **Benefit**: Zero-config, agent can immediately push/pull
- **Security**: Use dedicated "agent" GitHub account or deploy keys

### Networking Architecture
- **TAP-based networking** (per SUMMARY.md design)
- **Host gateway**: 172.16.0.1
- **VM IP pool**: 172.16.0.10-254 (245 available IPs)
- **Dynamic assignment**: Framework tracks next available IP
- **TAP devices**: `tap-agent-01`, `tap-agent-02`, etc. auto-created
- **NAT**: iptables/nftables for internet access
- **SSH access**: Direct via `ssh root@172.16.0.X`
- **Cleanup**: TAP devices removed when VM destroyed

## Design Considerations

### System Agnosticism
- Use POSIX-compliant shell scripts where possible
- Detect host OS and adapt tooling
- Provide nix-shell for NixOS development
- Document dependencies per OS

### VM Template Strategy
- Base template: minimal OS + essential tools
- Golden template: base + AI tools + authentication
- Project instances: golden template copy + project code

### Extensibility Points
- Guest OS selection (arch/ubuntu/fedora)
- AI agent tools (amp/gemini/openai)
- VM resources (CPU/RAM)
- Networking configuration
