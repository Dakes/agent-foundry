# Workspace Overview

Welcome! This is an Agent Foundry workspace - a self-contained development environment where AI agents work autonomously on projects. This README provides a quick orientation.

## What Is This?

This workspace contains:
- **Multiple Git repositories** under `repos/`
- **Context files** that describe your company, product, and standards
- **Agent memory** files tracking decisions, progress, and learnings
- **Task definitions** that guide autonomous work

The AI agent (powered by Claude Code) uses everything here to understand your project and work independently.

## Quick Start

### For Humans (Project Managers / Developers)

1. **Review the setup:**
   - Copy `.example` files to remove `.example` suffix (rename `company.md.example` → `company.md`)
   - Fill in your actual company/product information
   - Customize coding standards and architecture docs
   - Update workspace.json with your repository URLs

2. **Define the work:**
   - Edit `PROMPT.md` with the current task description
   - Update `@fix_plan.md` with prioritized tasks
   - Agent will read these files to understand what to build

3. **Monitor progress:**
   - Check `memory/progress.md` for completed work
   - Review `memory/blockers.md` if agent gets stuck
   - Update task files when priorities change

4. **Start the agent:**
   ```bash
   # In the VM, navigate to workspace
   cd /work/cloudash-web

   # Start Ralph agent in background
   ralph-loop

   # Or attach from host:
   foundry agent start my-vm ralph-claude-code
   ```

5. **Review results:**
   - Check git commits for code changes
   - Review memory files for context on decisions
   - Merge completed PRs after code review

### For AI Agents (Claude Code)

1. **Understand the project:**
   - Read `context/company.md` - What are we building?
   - Read `context/architecture.md` - How does it fit together?
   - Read `context/coding-standards.md` - What are the rules?

2. **Get task instructions:**
   - Read `PROMPT.md` - What should you work on?
   - Read `@fix_plan.md` - What's the priority?
   - Check `memory/decisions.md` - What patterns to follow?

3. **Understand history:**
   - Read `memory/progress.md` - What's been done?
   - Read `memory/blockers.md` - What's blocked?
   - Read `memory/learnings.md` - What patterns work?

4. **Do your work:**
   - Work in repos/ directories (git repositories)
   - Follow coding standards from context/ files
   - Write tests as you go
   - Update memory files as you progress

5. **Commit frequently:**
   - Use conventional commits: `feat(scope): description`
   - Small, logical commits are better than big ones
   - Include references to PROMPT.md or @fix_plan.md

6. **Update memory:**
   - After each session, update `memory/progress.md`
   - Log blockers in `memory/blockers.md`
   - Document learnings in `memory/learnings.md`
   - Add decisions in `memory/decisions.md`

## Directory Structure

```
/work/<workspace-name>/
├── README.md                      # This file - workspace overview
├── PROMPT.md                      # Current task for agent (see .example)
├── @fix_plan.md                   # Prioritized task list (see .example)
├── workspace.json                 # Workspace configuration (see .example)
│
├── context/                       # Project knowledge (read-only)
│   ├── company.md                 # Company/product description
│   ├── instructions.md            # Agent behavior guidelines
│   ├── coding-standards.md        # Code style and patterns
│   └── architecture.md            # System design and architecture
│
├── memory/                        # Agent memory (read-write)
│   ├── decisions.md               # Design decisions and trade-offs
│   ├── progress.md                # Work sessions and completed tasks
│   ├── blockers.md                # Current issues and blockers
│   └── learnings.md               # Patterns and best practices
│
├── repos/                         # Git repositories (your actual code)
│   ├── backend/
│   │   ├── api/                   # API service
│   │   ├── collector/             # Data collector
│   │   └── alerter/               # Alert service
│   ├── frontend/                  # React web app
│   ├── shared/                    # Shared types and utilities
│   └── infrastructure/            # Terraform, Helm, etc.
│
├── logs/                          # Agent logs (ralph-loop output)
│   └── (automatically created)
│
└── skills/                        # Custom skills (optional)
    └── .gitkeep
```

## File Types Explained

### Context Files (read-only for agents)

These describe your project, standards, and expectations:

- **company.md** - Company mission, products, tech stack, culture
- **instructions.md** - How agents should behave, what's expected
- **coding-standards.md** - Language-specific code style, naming conventions
- **architecture.md** - System design, data flow, deployment architecture

**How agents use them:** Read during task planning to ensure aligned behavior.

### Memory Files (read-write for agents)

These track work and learning:

- **decisions.md** - Record design choices and trade-offs (e.g., "Why Kafka instead of direct DB?")
- **progress.md** - Session logs showing completed work and next steps
- **blockers.md** - Current obstacles, troubleshooting guides, prevention checklist
- **learnings.md** - Patterns that work, anti-patterns to avoid, team insights

**How agents use them:** Reference when starting work, update after each session.

### Task Files

- **PROMPT.md** - Main instructions for current task (what to build, success criteria)
- **@fix_plan.md** - Prioritized list of all work (agents read to find next task)

**How agents use them:** PROMPT.md is detailed, @fix_plan.md shows overall roadmap.

## Getting Started with Custom Workspace

### Step 1: Rename Template Files

Remove `.example` suffix from context files:

```bash
cd context/
mv company.md.example company.md
mv instructions.md.example instructions.md
mv coding-standards.md.example coding-standards.md
mv architecture.md.example architecture.md

cd ../
mv PROMPT.md.example PROMPT.md
mv @fix_plan.md.example @fix_plan.md
mv workspace.json.example workspace.json
```

### Step 2: Customize Context Files

Edit each context file with your actual information:

1. **company.md**
   - Company name and mission
   - Product description and tech stack
   - Strategic goals
   - Repository organization
   - Team contacts

2. **instructions.md**
   - Your team's working style
   - Code quality expectations
   - Testing requirements
   - Documentation standards
   - Error handling patterns

3. **coding-standards.md**
   - Language-specific guidelines
   - Naming conventions
   - File organization
   - Comment style
   - Tool configurations (ESLint, Prettier, TypeScript)

4. **architecture.md**
   - System overview and components
   - Database schemas
   - API endpoints
   - Data flows
   - Deployment architecture
   - Scaling considerations

### Step 3: Configure workspace.json

Update with your actual repositories:

```json
{
  "name": "your-project-name",
  "description": "What your project does",
  "repositories": [
    {
      "name": "repo-name",
      "url": "git@github.com:yourorg/repo.git",
      "branch": "main",
      "directory": "repos/folder-name"
    }
  ],
  "agent": {
    "default_cli": "claude-code",
    "model": "claude-opus-4-5",
    "environment": {
      "CI": "false"
    }
  }
}
```

### Step 4: Define Initial Task

Edit PROMPT.md:
- What should the agent build first?
- Success criteria (how to know it's done)
- Guidelines to follow
- Implementation details

Edit @fix_plan.md:
- List high-priority tasks
- Add medium and low priority items
- Include subtasks
- Estimate hours needed

### Step 5: Clone Repositories

The VM setup will clone repos listed in workspace.json. Or manually:

```bash
for repo in repos/*; do
  cd "$repo"
  git clone <url> .
  git checkout <branch>
  npm install  # or language-specific setup
  cd ..
done
```

### Step 6: Start the Agent

```bash
# From host:
foundry agent start my-project ralph-claude-code

# Or manually in VM:
cd /work/my-project
ralph-loop
```

## Memory Files: How to Use Them

### decisions.md - Record Design Choices

When your agent makes a significant decision, document it:

```markdown
## Decision: Use Kafka for metrics pipeline

**Date:** 2024-01-17
**Context:** Need to handle 100k+ metrics/second
**Options Considered:**
- Database writes (simple but slow)
- Kafka queue (complex but scalable)
- Redis pub/sub (fast but no persistence)

**Decision:** Use Kafka because [reasons]
**Trade-offs:** Added operational complexity for unlimited scale
**Implications for Agents:** Always use Kafka for metrics, not DB writes
```

### progress.md - Track Work Sessions

After each work session, log what was done:

```markdown
## Session: 2024-01-17 - Claude Code Agent

**Duration:** 3.5 hours
**Focus:** User authentication system
**Status:** Complete

### Completed
- [x] JWT token generation
- [x] Login endpoint
- [x] Auth middleware
- [x] Tests (87% coverage)

### Notes for Next Session
- Token refresh needs configuration
- Consider password reset in next iteration
```

### blockers.md - Track Issues

When work gets stuck, document the blocker:

```markdown
## Blocker: Database migration failed

**Severity:** High
**Status:** Active

**Description:** PostgreSQL migration failed with constraint error
**Root Cause:** Users table created before organizations table
**Impact:** Cannot create foreign key

**Resolution:** [To be filled in when resolved]
```

### learnings.md - Share Patterns

Document what works for future reference:

```markdown
## Pattern: Shared Types First

When building cross-service features:
1. Define types in repos/shared/ first
2. Create validation schemas alongside types
3. Use in all services

**Why it works:** Prevents API mismatches, enables early feedback
**When to use:** Starting any feature spanning multiple services
```

## Typical Agent Workflow

1. **Session Start (30 min)**
   - Read PROMPT.md and @fix_plan.md
   - Review memory files for context
   - Check environment setup

2. **Work Phase (2-3 hours)**
   - Implement features from PROMPT.md
   - Write tests as you go
   - Make atomic git commits
   - Update PROMPT.md if understanding changes

3. **Checkpoint (15 min)**
   - Run full test suite
   - Verify linting and TypeScript
   - Commit any work-in-progress

4. **Session End (15 min)**
   - Update memory/progress.md with what was done
   - Log any blockers in memory/blockers.md
   - Document learnings in memory/learnings.md
   - Check git log to verify commits are good
   - Commit memory file updates

## Common Agent Mistakes (and How to Avoid)

❌ **Mistake:** Committing broken code or code with failing tests
✅ **Fix:** Always run full test suite before committing

❌ **Mistake:** Not updating memory files, next agent has no context
✅ **Fix:** Update progress.md and blockers.md after each session

❌ **Mistake:** Writing code that doesn't match coding-standards.md
✅ **Fix:** Read standards first, lint before committing

❌ **Mistake:** Ignoring architectural decisions from decisions.md
✅ **Fix:** Follow established patterns, document exceptions

❌ **Mistake:** Working on wrong task because PROMPT.md wasn't clear
✅ **Fix:** Ask clarifying questions, update PROMPT.md if needed

## Monitoring Agent Progress

### From the Host

```bash
# Check agent status
foundry agent status my-project

# View recent logs
foundry agent logs my-project --tail 50

# Attach to agent session
foundry agent attach my-project

# Check git history
cd /path/to/workspace/repos/backend
git log --oneline -20

# Check tests
npm test
```

### Check Memory Files

Read memory files to understand context:

- **progress.md** - What was completed recently?
- **blockers.md** - What's stuck?
- **decisions.md** - Why were choices made this way?
- **learnings.md** - What patterns are working?

### Merge Code

When agent completes work:

```bash
# Review commits
git log origin/develop..feature/my-feature --oneline

# Check diffs
git diff origin/develop..feature/my-feature

# If good, merge
git checkout develop
git merge feature/my-feature
```

## FAQ

**Q: Can I modify context files while agent is working?**
A: Yes, but it's better to wait until session ends or communicate changes clearly.

**Q: What if agent makes a mistake?**
A: Check memory/blockers.md, revert commits if needed, update task definition and restart.

**Q: Can multiple agents work on same project?**
A: Yes! Use different feature branches. They'll stay in sync via git.

**Q: How often should I review memory files?**
A: At least daily. They're your primary visibility into agent progress.

**Q: What if agent is stuck for hours?**
A: Check memory/blockers.md for details, then either resolve blocker or manually help the agent.

## Workspace Best Practices

1. **Keep context files current** - They're agent knowledge base
2. **Write clear task definitions** - Ambiguity causes agent confusion
3. **Update memory files regularly** - They're your visibility into progress
4. **Review commits frequently** - Catch issues early
5. **Communicate changes** - Update task files if priorities shift
6. **Test before merging** - Run full test suite before integration
7. **Document decisions** - Future agents (and you!) will reference them

## Next Steps

1. Rename `.example` files to remove suffix
2. Customize context files with your actual information
3. Update PROMPT.md with your first task
4. Update @fix_plan.md with your roadmap
5. Configure workspace.json with your repositories
6. Start the agent and monitor progress
7. Review completed work and merge when ready

Good luck! Your AI agent is ready to work autonomously on your project.

---

**For more information:**
- Agent Foundry Docs: [foundry documentation]
- Ralph CLI: [ralph-claude-code documentation]
- Example Workspaces: [example workspaces]
