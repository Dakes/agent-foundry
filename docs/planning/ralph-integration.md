# Ralph-Claude-Code Integration Design

## Overview

Using [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) as the primary autonomous agent framework. Ralph is a mature, production-ready system specifically built for Claude Code CLI.

## How Ralph Works

Ralph orchestrates autonomous development cycles:
1. Reads instructions from `PROMPT.md` in project
2. Executes Claude Code with context
3. Tracks progress and evaluates completion
4. Repeats until project complete (dual exit conditions)

## Installation in VM

### System-wide Installation (in template)
```bash
# Clone and install ralph system-wide (one-time in template)
cd /opt
git clone https://github.com/frankbria/ralph-claude-code.git ralph
cd ralph
./install.sh
# Makes ralph-setup, ralph-import available globally
```

### Per-Project Setup (in workspace)
```bash
# Initialize Ralph in a project
cd /work/my-project/repos/backend
ralph-setup
# Creates: PROMPT.md, @fix_plan.md, specs/, src/, logs/

# OR import into existing project
ralph-import
```

## Background Execution Models

### Model 1: Manual Start with tmux (Recommended)
User SSH into VM and manually starts Ralph:
```bash
ssh root@172.16.0.11
cd /work/my-project/repos/backend
ralph-loop  # Runs in tmux automatically
# Detach from tmux (Ctrl+B, D)
exit  # VM keeps running
```

Later, re-attach:
```bash
ssh root@172.16.0.11
tmux attach -t ralph-loop
```

### Model 2: Auto-start at Boot (Optional)
Systemd service starts Ralph automatically on VM boot:
```ini
[Unit]
Description=Ralph Agent for %i
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=/work/%i
ExecStart=/usr/local/bin/ralph-loop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Enable per workspace:
```bash
systemctl enable ralph@my-project
```

### Model 3: Foundry CLI Wrapper (Best UX)
Framework provides convenient commands:

```bash
# Start Ralph agent
foundry agent start my-project --provider claude

# Check status
foundry agent status my-project

# View logs
foundry agent logs my-project --follow

# Attach to tmux session
foundry agent attach my-project

# Stop agent
foundry agent stop my-project
```

Behind the scenes:
- Creates tmux session with Ralph
- Sets up logging
- Tracks agent state in registry

## Integration with Workspace

Ralph expects specific files in project:
```
/work/my-project/repos/backend/
├── PROMPT.md           # Main instructions for Claude
├── @fix_plan.md        # Task prioritization
├── specs/              # Requirements
├── src/                # Implementation
└── logs/               # Ralph execution logs
```

### Workspace Context Integration

Ralph reads `PROMPT.md` which can reference workspace context:
```markdown
# Development Instructions

## Project Context
See /work/my-project/context/company.md for company overview
See /work/my-project/context/architecture.md for system design

## Current Task
[specific task from @fix_plan.md]

## Guidelines
Follow coding standards in /work/my-project/context/coding-standards.md
```

## Multi-Provider Support

While Ralph is Claude-specific, framework supports other agents:

```bash
# Use Claude Code with Ralph (autonomous)
foundry agent start project-a --provider claude --mode ralph

# Use Gemini CLI (interactive/manual)
foundry agent start project-b --provider gemini --mode manual

# Use OpenAI Codex (interactive/manual)
foundry agent start project-c --provider openai --mode manual
```

Modes:
- **ralph**: Autonomous loop until completion (Claude only)
- **manual**: Interactive session in screen/tmux

## Dependencies in VM Template

Required packages:
- bash 4.0+
- nodejs + npm (for Claude Code CLI)
- tmux (for session management)
- jq (for JSON parsing)
- git (for version control)
- screen (for non-Ralph agents)

## Monitoring & Observability

Ralph provides built-in tmux monitoring:
- Real-time loop status
- API call consumption
- Live log streaming

Framework enhances with:
- Centralized log aggregation
- Status dashboard (foundry status --all)
- Resource monitoring per agent

## Rate Limits & Resource Management

Ralph handles:
- Rate limiting (100 calls/hour default)
- 5-hour usage limit prompts
- Session expiration (24h default)

Framework adds:
- Cross-VM rate limit tracking
- API key rotation (if multiple keys)
- Cost monitoring

## Advantages of This Approach

1. **Proven solution** - 3.5k stars, 308 tests, mature codebase
2. **Claude-optimized** - Built specifically for Claude Code CLI
3. **Autonomous** - True 24/7 operation with safeguards
4. **Monitoring built-in** - tmux integration for visibility
5. **Extensible** - Can add other providers alongside Ralph
6. **Production-ready** - Circuit breakers, rate limiting, session management
