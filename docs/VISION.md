# Agent Foundry - Vision & Goals

## The Problem

AI coding agents are powerful but require isolated environments to work safely and effectively. Running agents directly on developer machines risks:
- System pollution from dependencies
- Conflicts between projects
- Security concerns with AI-generated code
- Resource contention
- Lost work if agent crashes host

## The Solution

Agent Foundry provides **isolated sandboxes** where AI agents can work autonomously on coding projects. Each sandbox is:
- **Isolated**: separate filesystem and process space, with egress governed by policy
- **Reproducible**: built from one Dockerfile, not a hand-tended disk image
- **Autonomous**: agents run unattended with safeguards
- **Disposable**: remove the sandbox when done; the volume root and its git history stay on the host

## Key Goals

### 1. True Autonomy
Agents work continuously without supervision:
- Start the agent, log out, it keeps working
- Each CLI's own goal loop runs until its completion condition holds
- A forge comment is enough to start work; the result comes back as a comment
- State lives on the host, so a restart resumes rather than repeats

### 2. Multi-Project Support
Run many concurrent sandboxes:
- Each project gets its own sandbox and its own host directory
- Resources default to the sandbox runtime's choice, configurable per project
- Maximize AI subscription usage across projects

### 3. Rich Context for Agents
Workspaces provide comprehensive project understanding:
- Company/product descriptions
- Coding standards and architecture docs
- Multi-repo support for complex projects
- Agent memory files for continuity

### 4. Multiple AI Providers
Leverage best tools for each task:
- **Claude Code** - primary coding agent, interactive or `/goal`
- **Codex** - interactive or `/goal`
- **Antigravity CLI** - `/goal`
- **Gemini CLI** - interactive
- A registry that keeps agent differences in one file

### 5. Simple, Powerful UX
A host-based CLI, three verbs for the common path:
```bash
foundry init my-project
foundry up my-project
foundry logs -f my-project
```

### 6. Reproducibility
One image definition, versioned in git:
- `foundry-agent:base`: the interactive agent CLIs
- One tag per autonomous runner
- Custom packages via `config/packages.txt`
- Rebuild instead of hand-editing a disk image

### 7. Developer Freedom
Full access when needed:
```bash
foundry shell my-project
# Install tools, debug, customize
```

## Use Cases

### Autonomous Feature Development
1. Write the standing instructions in `AGENT.md`
2. Set `.agent` to a goal agent and run `foundry up`
3. Comment `@yourbot implement ...` on an issue
4. The agent works across repos and opens a pull request
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
1. Clone the production agent sandbox
2. Test risky changes in copy
3. Iterate until working
4. Remove the test sandbox
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
- Sandboxes are ephemeral, git and the volume root are permanent

### Workspace-Centric
- Workspace = project universe
- Multiple repos, rich context, agent memory
- Self-contained, portable
- The volume root is the agent's home, mounted at the same path inside

### Host-Based Management
- All commands run from the host
- Users never need to know how the sandbox is addressed
- Clean, docker-like UX

## Non-Goals

- Not a container orchestration system (use k8s for that)
- Not for production workload hosting
- Not a general-purpose sandbox or VM manager
- Not a replacement for local development

## Success Metrics

A successful Agent Foundry:
1. Agents work autonomously for hours/days without intervention
2. Users manage 3-5 concurrent projects effortlessly
3. Templates are reused across team/organization
4. Setup time: < 5 minutes from config to agent running
5. 90% of work happens in sandboxes, 10% reviewing/merging

## Future Vision

### Phase 1 (MVP)
- Ubuntu sandboxes on Docker Sandboxes
- Goal-mode agents as the autonomous path
- Project verbs (init, up, down, status)
- Forgejo watcher

### Phase 2
- Additional guest OS support (Fedora, Alpine)
- More agent integrations
- Advanced CLI features (copy, rename, snapshot)
- Automated template building

### Phase 3
- Web dashboard for monitoring
- Agent collaboration (multiple agents on one project)
- Cost tracking and optimization
- Template marketplace

### Phase 4
- Remote hosting (run sandboxes in the cloud)
- Team features (shared templates, workspaces)
- Advanced orchestration
- AI agent improvements feedback loop

## Why Docker Sandboxes?

Foundry originally ran agents in Firecracker microVMs. The isolation was
excellent, but the cost was a whole second system to maintain: a golden image
pipeline, TAP devices and an IP pool, an SSH transport, and a workspace that
had to be synced in and out because the VM's filesystem was not the host's.

Docker Sandboxes removes all of that while keeping what actually mattered:

- **Isolation with a policy layer**: egress is enforced by the sandbox proxy,
  so "open internet, closed LAN" is a rule set rather than a firewall to build
- **The workspace is the host directory**: bind-mounted at the same absolute
  path, so there is nothing to sync and no copy to drift
- **One image definition**: a Dockerfile instead of debootstrap, a kernel and
  a chroot
- **No host networking to own**: no TAP devices, no IP pool, no NAT
- **Fast**: start and stop in about the time an SSH handshake used to take

The trade-off is honest: container isolation is namespace-based, not
kernel-level. For an agent running code you chose to give it, with the LAN and
the host cut off at the network layer, that is the right trade.

## Success Stories (Envisioned)

**Backend Developer**: "I comment `@bot implement` on the refactoring issue before bed. Next morning it's done - tests passing, PR opened. I review, merge, move on."

**Full-Stack Team**: "We have a company agent image with our standards. Everyone builds it, creates a sandbox per feature. Agents work on frontend/backend simultaneously."

**Solo Founder**: "I run 3 agents: one on web app, one on mobile, one on docs. All working around the clock. I focus on product/design, agents handle implementation."

**Consultant**: "Each client gets a project with their specific context. I spin up a sandbox per project, agents know the client's codebase and standards instantly."

## Conclusion

Agent Foundry enables a new development paradigm: **autonomous, isolated, reproducible AI agent workspaces**. Developers describe what to build, agents execute, humans review and guide. Sandboxes provide the safe, powerful environment agents need to work at full capability.
