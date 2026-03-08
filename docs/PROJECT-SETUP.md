# Project Setup Guide

This guide explains how to create and configure project folders for Agent Foundry VMs.

## Overview

Agent Foundry uses project folders to configure VMs. Each project folder contains:
- **git-config.json**: Repository configuration (required)
- **agents.json**: Agent selection for workspace provisioning (required)
- **Context markdown files**: Project documentation for agents
- **Deploy keys (optional)**: Per-repo SSH keys for git authentication
- **.ralph/ folder**: Optional Ralph-specific configuration

## SSH Key Isolation (Per-VM)

By default, Foundry generates a unique SSH keypair for each VM under:
`~/.local/share/foundry/vms/<name>/ssh/`.

- The generated key is used for VM access and git authentication.
- Foundry never reads `~/.ssh/` unless you explicitly pass `--ssh-key <path>` when creating a VM.

## Project Folder Structure

```
projects/
  my-project/
    git-config.json           # Required: Repository configuration
    agents.json               # Required: selected agents (one Ralph max)
    overview.md               # Project context
    architecture.md           # Architecture documentation
    coding-standards.md       # Coding guidelines
    ralph.yml                 # Optional: Ralph Orchestrator config
    PROMPT.md                 # Optional: Ralph Orchestrator prompt file
    .ralph/                   # Optional: Ralph-specific
      PROMPT.md
      fix_plan.md
      AGENT.md
    backend-deploy-key        # SSH private key for backend repo
    backend-deploy-key.pub    # SSH public key
    frontend-deploy-key       # SSH private key for frontend repo
    frontend-deploy-key.pub   # SSH public key
```

## Creating a Project Folder

### Step 1: Create Project Directory

```bash
mkdir -p projects/my-project
cd projects/my-project
```

### Step 2: Create git-config.json

Create `git-config.json` with your repositories:

```json
{
  "repositories": [
    {
      "name": "backend",
      "url": "git@github.com:myorg/backend.git",
      "branch": "main",
      "ssh_key": "backend-deploy-key"
    },
    {
      "name": "frontend",
      "url": "git@gitlab.com:myorg/frontend.git",
      "branch": "develop",
      "ssh_key": "frontend-deploy-key"
    }
  ]
}
```

**Fields:**
- `name`: Directory name in VM (`/work/<vm>/repos/<name>/`)
- `url`: Standard git SSH URL
- `branch`: Branch to checkout (default: "main")
- `ssh_key`: Filename of deploy key (without .pub extension)

### Step 3: Create agents.json

Create `agents.json` to declare which agents this project uses:

```json
{
  "agents": [
    "frankbria/ralph-claude-code",
    "@anthropic-ai/claude-code",
    "@openai/codex",
    "@google/gemini-cli"
  ]
}
```

For Ralph Orchestrator projects, replace `frankbria/ralph-claude-code` with `mikeyobrien/ralph-orchestrator`.

Important: include at most one Ralph-family agent per project/image.

### Step 4: Generate Deploy Keys

Generate a deploy key for each repository (optional):

```bash
# For backend repo
ssh-keygen -t ed25519 -f backend-deploy-key -C "backend-deploy-key" -N ""

# For frontend repo
ssh-keygen -t ed25519 -f frontend-deploy-key -C "frontend-deploy-key" -N ""
```

**Add public keys to your git hosting:**
- GitHub: Settings → Deploy keys
- GitLab: Settings → Repository → Deploy keys

### Step 5: Add Context Files

Create markdown files with project documentation:

```bash
# Project overview
cat > overview.md << 'EOF'
# My Project

High-level description of the project, its purpose, and key components.
EOF

# Architecture documentation
cat > architecture.md << 'EOF'
# Architecture

System architecture, component relationships, data flow.
EOF

# Coding standards
cat > coding-standards.md << 'EOF'
# Coding Standards

- Style guide
- Naming conventions
- Best practices
EOF
```

### Step 6: (Optional) Add Ralph Configuration

If using Ralph, create `.ralph/` folder:

```bash
mkdir .ralph
cat > .ralph/PROMPT.md << 'EOF'
# Task Instructions

Current development task and requirements.
EOF

cat > .ralph/fix_plan.md << 'EOF'
# Task List

- [ ] Task 1
- [ ] Task 2
EOF
```

## Using Your Project

### Create a VM

```bash
foundry vm create dev-vm-1 --project my-project
```

This will:
1. Create VM from golden template
2. Generate a per-VM SSH keypair in `~/.local/share/foundry/vms/<name>/ssh/`
3. Copy deploy keys to VM's `/root/.ssh/` (if provided)
4. Generate SSH config for per-repo keys
5. Clone repositories using deploy keys
6. Copy markdown files to `/work/dev-vm-1/context/`
7. Copy `.ralph/` folder if it exists
8. Copy `ralph.yml` / `ralph.*.yml` if present

### Create Multiple VMs from Same Project

```bash
foundry vm create dev-vm-2 --project my-project
foundry vm create staging-vm --project my-project
```

All VMs use the same project configuration but are independent instances.

## Multi-Agent Support

The project folder structure is agent-agnostic:

**Ralph (Autonomous):**
- `frankbria/ralph-claude-code`: uses `.ralph/` + optional `.ralphrc`
- `mikeyobrien/ralph-orchestrator`: uses `ralph.yml` + `PROMPT.md` (+ optional `.ralph/`)
- Only one Ralph-family agent should be configured per project/image

**Claude Code (Interactive):**
- No `.ralph/` folder needed
- User provides instructions interactively
- Context files available in `context/`

**Other Agents (Gemini, etc.):**
- Create agent-specific folders as needed
- Use `AGENT.md` as entrypoint

## Example: Complete Setup

See `projects/example-project/` in the repository for a complete working example.
For Ralph Orchestrator, see `projects/example-project-orchestrator/`.

## Tips

1. **Security**: Never commit private deploy keys to git (use .gitignore)
2. **Multiple repos can share keys**: Use same `ssh_key` value in git-config.json
3. **Per-environment configs**: Create separate projects for dev/staging/prod
4. **Team sharing**: Share project folder structure (without private keys)
5. **Deploy key management**: Use read-only deploy keys when possible

## Troubleshooting

**Repos fail to clone:**
- Check deploy key is added to git hosting
- Verify key permissions (600 for private key)
- Check URL format in git-config.json

**Agent can't find context:**
- Markdown files should be in project root (not subfolders)
- Check files were copied to VM: `foundry vm ssh <name>`

**Ralph-specific files missing:**
- Ensure `.ralph/` exists in project folder
- Check files were copied: `foundry vm ssh <name>` → `ls /work/<name>/.ralph/`
