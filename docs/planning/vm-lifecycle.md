# VM Lifecycle and Management

## VM Creation Flow

### Step 1: Create VM from Template
```bash
foundry vm create my-project [--config workspace.json]
```

**What happens:**
1. Copy golden template disk → `my-project.ext4`
2. Allocate resources (IP, TAP device, CPU, RAM)
3. Boot VM with Firecracker
4. Wait for SSH availability
5. Initialize workspace structure inside VM
6. Copy workspace template files from framework repo
7. Clone repositories (if specified in config)
8. Register VM in `~/.config/foundry/vms.json`

**Output:**
```
✓ Created VM disk: my-project.ext4
✓ Assigned IP: 172.16.0.11
✓ Created TAP device: tap-agent-01
✓ VM booted successfully
✓ Workspace initialized: /work/my-project
✓ Copied template files
✓ Cloned 2 repositories
✓ VM ready!

Access: foundry vm ssh my-project
Start agent: foundry agent start my-project ralph-claude-code
```

### Step 2: Interactive Setup (Optional)
```bash
# SSH in for manual customization
foundry vm ssh my-project

# Customize workspace, install extra tools, etc.
cd /work/my-project
vim context/company.md
# ... customize ...

# Exit when done
exit
```

### Step 3: Snapshot for Reuse (Optional)
```bash
# Create reusable snapshot of customized VM
foundry vm snapshot my-project my-project-configured

# Later, create new VMs from snapshot
foundry vm create new-feature --from my-project-configured
```

## Workspace Template Structure

Framework repo contains default templates:

```
agent-foundry/
├── templates/
│   ├── workspace/              # Workspace template (copied to VM)
│   │   ├── context/
│   │   │   ├── company.md.example
│   │   │   ├── instructions.md.example
│   │   │   ├── coding-standards.md.example
│   │   │   └── architecture.md.example
│   │   ├── memory/
│   │   │   ├── decisions.md
│   │   │   ├── progress.md
│   │   │   ├── blockers.md
│   │   │   └── learnings.md
│   │   ├── skills/
│   │   │   └── .gitkeep
│   │   ├── workspace.json.example
│   │   └── README.md
│   └── systemd/
│       └── ralph-agent@.service  # Systemd service template
```

**During VM creation:**
- Copy `templates/workspace/` → `/work/<project-name>/` in VM
- Remove `.example` suffix from files
- Fill in project name in templates
- User edits actual files after creation

## VM Copy/Clone

```bash
# Copy entire VM (disk + config)
foundry vm copy my-project my-project-backup

# Copy and rename
foundry vm copy my-project new-feature --rename

# What happens:
# 1. Stop source VM (if running)
# 2. Copy disk image: my-project.ext4 → new-feature.ext4
# 3. Boot new VM with new IP/TAP
# 4. (if --rename) Update workspace name inside VM
# 5. Register new VM in registry
```

**Copy vs Snapshot:**
- **copy**: Exact duplicate, includes all workspace state
- **snapshot**: Creates reusable template, strips project-specific data

## VM Rename

```bash
foundry vm rename my-project better-name

# What happens:
# 1. Stop VM
# 2. Rename disk file
# 3. Rename workspace inside VM (/work/my-project → /work/better-name)
# 4. Update registry
# 5. Restart VM (optional)
```

## workspace.json Config

Used during VM creation:

```json
{
  "name": "my-project",
  "description": "Full-stack web application",
  "repositories": [
    {
      "name": "backend",
      "url": "git@github.com:user/backend.git",
      "branch": "main",
      "path": "repos/backend"
    },
    {
      "name": "frontend",
      "url": "git@github.com:user/frontend.git",
      "branch": "main",
      "path": "repos/frontend"
    }
  ],
  "context_files": {
    "company.md": "path/to/your/company.md",
    "instructions.md": "path/to/your/instructions.md"
  },
  "vm": {
    "cpus": null,
    "memory_mb": 8192,
    "disk_gb": 20
  },
  "agent": {
    "type": "ralph-claude-code",
    "auto_start": false
  }
}
```

**Usage:**
```bash
# Create with config
foundry vm create my-project --config ~/my-project.json

# Or wizard mode (interactive)
foundry vm create my-project --wizard
# Asks: How many repos? Repo URLs? CPU/RAM? etc.
```

## Pre-configured Setup Patterns

### Pattern 1: Quick Start (No Config)
```bash
foundry vm create quick-test
# Creates VM with empty workspace, manual setup
```

### Pattern 2: From Config File
```bash
foundry vm create my-project --config workspace.json
# Creates VM, clones repos, copies context files
```

### Pattern 3: From Snapshot
```bash
foundry vm create new-feature --from my-company-base
# Uses your customized snapshot with all your company context
```

### Pattern 4: Clone Existing
```bash
foundry vm copy production-agent dev-agent
# Exact copy for testing before modifying production agent
```

## Typical Workflow

**Initial Setup (Once):**
```bash
# Create base VM with company context
foundry vm create company-base --config company-base.json
foundry vm ssh company-base
# Customize company.md, instructions.md, install extra tools
exit

# Snapshot for reuse
foundry vm snapshot company-base company-base-v1
```

**Per-Project (Repeated):**
```bash
# Create from company snapshot
foundry vm create project-x --from company-base-v1 --config project-x.json

# Start agent
foundry agent start project-x ralph-claude-code

# Monitor
foundry agent logs project-x --follow

# When done, destroy
foundry agent stop project-x
foundry vm destroy project-x
```

## VM Storage Location

All VM disks stored in configured directory:
```
~/.local/share/foundry/vms/
├── templates/
│   ├── ubuntu-base.ext4           # Base template
│   ├── golden.ext4                # Golden template (with tools)
│   └── company-base-v1.ext4       # User snapshots
├── instances/
│   ├── my-project.ext4
│   ├── another-project.ext4
│   └── backup-project.ext4
└── kernels/
    └── vmlinux                     # Firecracker kernel
```

## Benefits of This Design

1. **Flexible creation** - From scratch, config, or snapshot
2. **Easy cloning** - Copy VMs for backup/testing
3. **Template reuse** - Snapshot customized setups
4. **Pre-configured files** - Framework provides examples
5. **Versioned snapshots** - Track VM template evolution
6. **Rename support** - Fix mistakes or rebrand projects
