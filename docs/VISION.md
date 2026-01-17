# Agent Foundry - Vision & Goals

## The Problem

AI coding agents are powerful but require isolated environments to work safely and effectively. Running agents directly on developer machines risks:
- System pollution from dependencies
- Conflicts between projects
- Security concerns with AI-generated code
- Resource contention
- Lost work if agent crashes host

## The Solution

Agent Foundry provides **lightweight, isolated microVMs** where AI agents can work autonomously 24/7 on coding projects. Each VM is:
- **Isolated**: Separate filesystem, network, resources
- **Reproducible**: Built from scripts, snapshots for reuse
- **Autonomous**: Agents run unattended with safeguards
- **Disposable**: Destroy when done, all work saved to git

## Key Goals

### 1. True Autonomy
Agents work continuously without supervision:
- Start agent in VM, log out, it keeps working
- ralph-claude-code orchestrates tasks until completion
- Built-in circuit breakers prevent infinite loops
- Session continuity across restarts

### 2. Multi-Project Support
Run unlimited concurrent VMs:
- Each project gets dedicated VM
- 50% CPU cores + 8GB RAM per VM (configurable)
- Dynamic IP allocation (172.16.0.10-254)
- Maximize AI subscription usage across projects

### 3. Rich Context for Agents
Workspaces provide comprehensive project understanding:
- Company/product descriptions
- Coding standards and architecture docs
- Multi-repo support for complex projects
- Agent memory files for continuity

### 4. Multiple AI Providers
Leverage best tools for each task:
- **Claude Code** - Primary coding agent (via ralph-claude-code)
- **Gemini CLI** - Alternative for specific tasks
- **OpenAI Codex** - Additional option
- Pluggable architecture for future agents

### 5. Simple, Powerful UX
Host-based CLI abstracts VM complexity:
```bash
foundry vm create my-project --config project.json
foundry agent start my-project ralph-claude-code
foundry agent logs my-project --follow
```

### 6. Reproducibility
Templates and snapshots enable reuse:
- Base template: Clean OS foundation
- Golden template: With AI tools installed
- Custom snapshots: Company-specific setups
- Version and iterate templates

### 7. Developer Freedom
Full access when needed:
```bash
foundry vm ssh my-project
# Install tools, debug, customize
# Snapshot for reuse
```

## Use Cases

### Autonomous Feature Development
1. Define feature in `PROMPT.md`
2. Start ralph-claude-code
3. Agent implements across multiple repos
4. Commits to feature branch
5. Review and merge

### 24/7 Background Work
1. Start agent on complex refactoring
2. Log out, go to bed
3. Agent works overnight
4. Review progress in morning

### Parallel Development
1. Run 3-5 VMs simultaneously
2. Different agents on different projects
3. Maximize AI subscription usage
4. Each isolated, no conflicts

### Experimentation & Testing
1. Clone production agent VM
2. Test risky changes in copy
3. Iterate until working
4. Destroy test VM
5. Apply learnings to production

### Team Collaboration
1. Create company base template
2. Include company standards, context
3. Snapshot and share with team
4. Everyone starts from same foundation

## Design Philosophy

### System Agnostic
- Works on any Linux host
- Arch server, NixOS development
- Shell scripts for portability
- `shell.nix` for NixOS convenience

### Minimal by Default
- Small base template (essential packages only)
- Users add what they need via `packages.txt`
- Snapshot customizations for reuse
- Avoid bloat

### Git as Source of Truth
- All code lives in git repos
- Agent commits as it works
- Workspace is disposable
- VMs are ephemeral, git is permanent

### Workspace-Centric
- Workspace = project universe
- Multiple repos, rich context, agent memory
- Self-contained, portable
- Ralph orchestrates at workspace level

### Host-Based Management
- All commands run from host
- Framework handles SSH connections
- Users never need to remember IPs
- Clean, docker-like UX

## Non-Goals

- Not a container orchestration system (use k8s for that)
- Not for production workload hosting
- Not a general-purpose VM manager
- Not a replacement for local development

## Success Metrics

A successful Agent Foundry:
1. Agents work autonomously for hours/days without intervention
2. Users manage 3-5 concurrent projects effortlessly
3. Templates are reused across team/organization
4. Setup time: < 5 minutes from config to agent running
5. 90% of work happens in VMs, 10% reviewing/merging

## Future Vision

### Phase 1 (MVP)
- Arch Linux VMs only
- ralph-claude-code as primary agent
- Basic CLI (create, start, stop, destroy)
- Manual template building

### Phase 2
- Additional guest OS support (Ubuntu, Fedora)
- More agent integrations
- Advanced CLI features (copy, rename, snapshot)
- Automated template building

### Phase 3
- Web dashboard for monitoring
- Agent collaboration (multiple agents on one project)
- Cost tracking and optimization
- Template marketplace

### Phase 4
- Remote VM hosting (run on cloud)
- Team features (shared templates, workspaces)
- Advanced orchestration
- AI agent improvements feedback loop

## Why Firecracker?

- **Lightweight**: Boots in milliseconds, minimal overhead
- **Secure**: KVM isolation, minimal attack surface
- **Fast**: Near-bare-metal performance
- **Stable**: Production-proven (AWS Lambda, Fargate)
- **Simple**: Easy to integrate via JSON config

## Why MicroVMs over Containers?

- **True isolation**: Kernel-level, not just namespaces
- **Any OS**: Not limited to container-friendly apps
- **AI safety**: Harder for agent to escape VM
- **Resource guarantees**: Dedicated CPU/RAM
- **Familiar**: SSH, normal filesystem, standard tools

## Success Stories (Envisioned)

**Backend Developer**: "I start a Ralph agent on API refactoring before bed. Next morning, it's done - tests passing, PRs created. I review, merge, move on."

**Full-Stack Team**: "We have a company base template with our standards. Everyone clones it, creates VMs per feature. Agents work on frontend/backend simultaneously."

**Solo Founder**: "I run 3 agents: one on web app, one on mobile, one on docs. All working 24/7. I focus on product/design, agents handle implementation."

**Consultant**: "Each client gets a VM template with their specific context. I spin up VMs per project, agents know the client's codebase and standards instantly."

## Conclusion

Agent Foundry enables a new development paradigm: **autonomous, isolated, reproducible AI agent workspaces**. Developers describe what to build, agents execute, humans review and guide. VMs provide the safe, powerful environment agents need to work at full capability.
