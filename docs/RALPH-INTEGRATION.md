# Ralph-Claude-Code Integration

## Overview

Agent Foundry uses [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) as the primary autonomous agent framework. Ralph is a mature, production-ready system specifically built for Claude Code CLI with 3.5k+ stars and comprehensive testing.

## How Ralph Works

Ralph orchestrates autonomous development cycles:

1. **Read** instructions from `PROMPT.md` in workspace
2. **Execute** Claude Code with full project context
3. **Track** progress and evaluate completion signals
4. **Verify** using dual-condition exit gate
5. **Repeat** until project completion or circuit breaker

## Key Features

### Dual-Condition Exit Gate
Ralph requires BOTH:
- Completion heuristics (≥2 indicators like "done", "complete", etc.)
- Claude's explicit `EXIT_SIGNAL: true` in response

This prevents premature exits during productive iterations.

### Advanced Circuit Breaker
- Two-stage error filtering prevents infinite loops
- Eliminates false positives from JSON fields containing "error"
- Accurately detects stuck states through multi-line pattern matching
- Automatic reset triggers on circuit breaker open

### Session Continuity
- Preserves context across loop iterations
- Automatic reset on manual interrupts
- Configurable expiration (24-hour default)
- Session state saved between runs

### Rate Limiting
- 100 API calls/hour (customizable)
- Handles Claude's 5-hour usage limit
- User prompts when limits reached
- Smart throttling to maximize throughput

### Built-in Monitoring
- Integrated tmux monitoring
- Real-time loop status display
- API consumption tracking
- Live log streaming

## Installation in VM

### System-wide Installation (in template)

During golden template build:
```bash
cd /opt
git clone https://github.com/frankbria/ralph-claude-code.git ralph
cd ralph
./install.sh
```

This makes `ralph-setup`, `ralph-import`, and `ralph-loop` available globally.

### Per-Project Setup (in workspace)

After VM creation, Ralph structures can be initialized:

**Option 1: New Project**
```bash
cd /work/my-project
ralph-setup
# Creates: PROMPT.md, fix_plan.md, specs/, src/, logs/
```

**Option 2: Existing Project**
```bash
cd /work/my-project
ralph-import
# Adds Ralph files to existing codebase
```

## Workspace Integration

### Ralph at Workspace Level

Ralph operates at `/work/<project-name>/` level, orchestrating across all repositories:

```
/work/my-project/               # Ralph runs here
├── PROMPT.md                   # Main instructions
├── fix_plan.md               # Task prioritization
├── specs/                      # Requirements
├── logs/                       # Ralph execution logs
│
├── repos/                      # All repos Ralph can work in
│   ├── backend/
│   ├── frontend/
│   └── shared-lib/
│
├── context/                    # Rich project context
│   ├── company.md
│   ├── instructions.md
│   ├── coding-standards.md
│   └── architecture.md
│
└── memory/                     # Agent memory
    ├── decisions.md
    ├── progress.md
    └── blockers.md
```

### Multi-Repo Support

Ralph can work across multiple repos for one feature:

**Example PROMPT.md:**
```markdown
# Task: Implement User Authentication

## Context
- See context/company.md for security requirements
- See context/architecture.md for system design

## Implementation Required

### Backend (repos/backend/)
- Add JWT authentication middleware
- Create /auth/login and /auth/logout endpoints
- Add user session management

### Frontend (repos/frontend/)
- Create login form component
- Add authentication context provider
- Implement protected routes

### Shared (repos/shared-lib/)
- Define AuthUser type
- Add authentication utility functions

## Success Criteria
- All tests pass in all repos
- Login flow works end-to-end
- JWT tokens properly validated
- Protected routes redirect to login

## Guidelines
- Follow coding standards in context/coding-standards.md
- Write tests for all new code
- Use conventional commits
```

Ralph will work across all three repos, making cohesive changes.

## Background Execution

### Manual Start (Recommended)

User SSH into VM and starts Ralph:
```bash
ssh root@172.16.0.11
cd /work/my-project
ralph-loop
# Runs in tmux automatically
# Detach: Ctrl+B, D
exit
```

Later, re-attach:
```bash
foundry agent attach my-project
# or manually: ssh root@172.16.0.11 && tmux attach -t ralph-loop
```

### Auto-start on Boot (Optional)

Systemd service template provided at `templates/systemd/ralph-agent@.service`:

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
RestartSec=60

[Install]
WantedBy=multi-user.target
```

Enable per workspace:
```bash
systemctl enable ralph@my-project
systemctl start ralph@my-project
```

### Foundry CLI Wrapper

Framework provides convenient commands:

```bash
# Start Ralph agent
foundry agent start my-project ralph-claude-code

# Behind the scenes:
# 1. SSH into VM
# 2. Navigate to /work/my-project
# 3. Start ralph-loop in tmux
# 4. Register in agent registry
# 5. Return to host

# Check status
foundry agent status my-project

# View logs
foundry agent logs my-project --follow

# Attach to tmux session
foundry agent attach my-project

# Stop agent
foundry agent stop my-project
```

## Configuration

Ralph reads configuration from workspace:

### PROMPT.md Structure
```markdown
# [Feature/Task Name]

## Context
[Background information, links to context/ files]

## Current Task
[Specific task from fix_plan.md]

## Implementation Details
[Specific requirements, files to modify, approach]

## Success Criteria
[How to know when task is complete]

## Guidelines
[Coding standards, testing requirements, commit style]
```

### fix_plan.md Structure
```markdown
# Fix Plan

## High Priority
- [ ] User authentication system
- [ ] Password reset flow
- [ ] Email verification

## Medium Priority
- [ ] Two-factor authentication
- [ ] OAuth integration
- [ ] Session management

## Low Priority
- [ ] Remember me functionality
- [ ] Login history
- [ ] Device management

## Completed
- [x] Database schema for users
- [x] Basic user model
```

## Monitoring & Observability

### Ralph Built-in Monitoring

Ralph provides tmux monitoring:
- Real-time loop iteration count
- API call consumption (X / 100 per hour)
- Current task being worked on
- Live log streaming

### Foundry Enhancements

Framework adds:
- Centralized log aggregation at `~/.local/share/foundry/logs/`
- Status dashboard via `foundry agent status --all`
- Resource monitoring per agent
- API usage tracking across VMs

## Rate Limits & Resource Management

### Ralph Handles
- Rate limiting (100 calls/hour default, configurable)
- 5-hour usage limit prompts
- Session expiration (24h default)
- Circuit breaker for stuck states

### Framework Adds
- Cross-VM rate limit tracking
- API key rotation (if multiple keys configured)
- Cost monitoring and reporting
- Resource allocation per VM

## Best Practices

### Writing Effective PROMPT.md
1. **Be specific** - "Add login endpoint" not "improve auth"
2. **Reference context** - Point to architecture.md, coding-standards.md
3. **Define success** - Clear, testable completion criteria
4. **Guide approach** - Suggest file locations, patterns to use
5. **Break down complexity** - Large tasks → smaller subtasks in fix_plan.md

### Managing Long-Running Agents
1. **Start small** - Test with simple task first
2. **Monitor initially** - Watch first few iterations
3. **Check progress** - Review memory/progress.md periodically
4. **Commit frequency** - Configure Ralph for frequent commits
5. **Set checkpoints** - Break large features into milestones

### Multi-Repo Coordination
1. **Shared types first** - Define interfaces in shared-lib
2. **Backend before frontend** - API contracts established first
3. **Test integration** - E2E tests verify cross-repo changes
4. **Atomic PRs** - One feature = one PR across all repos

### Debugging Failed Iterations
1. **Check logs** - `foundry agent logs my-project --tail 200`
2. **Review PROMPT** - Is task description clear?
3. **Circuit breaker** - Did it detect a stuck state?
4. **Context files** - Are architecture.md, coding-standards.md accurate?
5. **Restart** - Sometimes a fresh session helps

## Advantages Over Alternatives

### vs. Manual Claude Code Usage
- **Autonomous**: Runs unattended vs. manual prompts
- **Iterative**: Loops until complete vs. one-shot
- **Safeguards**: Circuit breakers vs. manual monitoring
- **Context preservation**: Maintains state across runs

### vs. Amp + Ralph
- **No subscription**: Uses your Claude API directly
- **Claude-optimized**: Built specifically for Claude Code
- **More mature**: 3.5k stars, extensive testing
- **Better integration**: Native Claude Code CLI support

### vs. Custom Loops
- **Production-ready**: Tested, documented, maintained
- **Rate limiting**: Built-in, no custom implementation
- **Monitoring**: tmux integration included
- **Exit detection**: Sophisticated dual-condition logic

## Troubleshooting

### Ralph Not Starting
```bash
# Check Claude Code CLI installed
which claude

# Check ralph installed
which ralph-loop

# Check workspace structure
ls /work/my-project/PROMPT.md
```

### Infinite Loop Detected
- Circuit breaker opened, check logs
- Review PROMPT.md for ambiguity
- Ensure success criteria are testable
- Check if tests are flaky

### API Rate Limit Hit
- Default: 100 calls/hour
- Configure higher limit if you have more capacity
- Wait for limit reset
- Consider breaking task into smaller chunks

### Agent Stopped Unexpectedly
```bash
# Check tmux session
tmux list-sessions

# Check logs
foundry agent logs my-project --tail 100

# Check system resources
foundry vm status my-project
```

## Future Enhancements

### Planned
- Multi-agent collaboration (multiple agents on one workspace)
- Web UI for monitoring Ralph progress
- Integration with GitHub Actions
- Automatic PR creation after task completion

### Possible
- Support for other LLM providers via adapters
- Distributed Ralph (work across multiple VMs)
- Agent-to-agent communication
- Learning from past iterations
