# Task Plan: Agent Foundry - MicroVM AI Agent Framework

## Goal
Create a reproducible, system-agnostic framework for building and managing Firecracker microVMs that run AI coding agents (Claude/Amp + Ralph Wiggum) with automated image building, git integration, and per-project isolation.

## Phases
- [ ] Phase 1: Clarify requirements and design architecture
- [ ] Phase 2: Set up project structure and git repository
- [ ] Phase 3: Create host-agnostic tooling (with nix-shell for NixOS)
- [ ] Phase 4: Implement Ubuntu Linux VM image builder
- [ ] Phase 5: Implement VM lifecycle management (create, run, stop, destroy)
- [ ] Phase 6: Add AI agent tooling integration (Amp, Ralph, etc.)
- [ ] Phase 7: Create documentation and examples

## Key Questions - ALL RESOLVED ✓
1. ✓ AI tools: Claude Code (primary), OpenAI Codex, Gemini CLI
2. ✓ Ralph: Use ralph-claude-code (frankbria/ralph-claude-code) as main autonomous agent
3. ✓ Concurrency: Unlimited VMs, 50% cores + 8GB RAM default (configurable)
4. ✓ Git workflow: Workspace-based, flexible multi-repo support
5. ✓ Authentication: Pre-configured SSH keys copied into VM template
6. ✓ Networking: TAP-based, 172.16.0.10-254 pool, static IPs, NAT for internet
7. ✓ Background execution: screen/tmux sessions for manual CLI, Ralph uses tmux monitoring
8. ✓ Workspace init: Config file, wizard, or snapshot-based
9. ✓ VM operations: Copy, rename, snapshot support
10. ✓ CLI: Host-based commands (foundry), framework abstracts SSH
11. ✓ Developer tools: Minimal+common base (includes make), customizable via packages.txt

## Decisions Made
- **Host compatibility**: System-agnostic shell scripts, with nix-shell support for NixOS hosts
- **Primary guest OS**: Ubuntu Linux 22.04 (other distros planned for later)
- **Target server**: Any Linux production server
- **Development environment**: NixOS (need nix-shell for dev tools)
- **Autonomous agent**: ralph-claude-code (frankbria/ralph-claude-code)
- **Agent types as names**: ralph-claude-code, gemini-cli, openai-codex (not --provider)
- **CLI location**: Host-based commands, framework abstracts VM access
- **VM operations**: Full lifecycle - create, copy, rename, snapshot, destroy
- **Workspace templates**: Pre-configured files in framework repo, copied to VMs
- **Ralph mode**: Manual start initially, systemd service ready for auto-start
- **Package management**: Minimal+common base (includes make), customizable via packages.txt
- **Default packages**: base-devel, git, ssh, vim, nano, bash, tmux, screen, jq, curl, wget, nodejs, python, docker

## Errors Encountered
- None yet

## Status
**Phase 1 Complete** - All requirements clarified, ready to present complete architecture design
