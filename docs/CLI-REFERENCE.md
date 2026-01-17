# Foundry CLI Reference

All commands run from the host system. Framework handles SSH connections and VM orchestration transparently.

## Command Structure

```bash
foundry <domain> <action> [arguments] [options]
```

## VM Management

### Create VM
```bash
foundry vm create <name> [options]

Options:
  --config <file>      Create from workspace config JSON
  --from <snapshot>    Create from existing snapshot
  --wizard            Interactive setup wizard
  --cpus <N>          Override default CPU count
  --memory <MB>       Override default memory
  --disk <GB>         Override default disk size

Examples:
  foundry vm create test-project
  foundry vm create my-app --config workspace.json
  foundry vm create new-feature --from company-base-v1
  foundry vm create experiment --cpus 4 --memory 4096
```

### List VMs
```bash
foundry vm list [filter]
foundry vm ps        # Alias for list

Filters:
  --all              Show all VMs (default)
  --running          Show only running VMs
  --stopped          Show only stopped VMs

Examples:
  foundry vm list
  foundry vm ps --running
```

### Start/Stop/Restart VM
```bash
foundry vm start <name>
foundry vm stop <name> [--force]
foundry vm restart <name>

Examples:
  foundry vm start my-project
  foundry vm stop my-project
  foundry vm stop hung-vm --force
  foundry vm restart my-project
```

### SSH into VM
```bash
foundry vm ssh <name>

Example:
  foundry vm ssh my-project
  # Drops you into root shell at 172.16.0.11
```

### Get VM Info
```bash
foundry vm status <name>    # Detailed VM information
foundry vm ip <name>        # Show IP address only

Examples:
  foundry vm status my-project
  foundry vm ip my-project
```

### Copy/Rename VM
```bash
foundry vm copy <source> <dest>
foundry vm rename <old-name> <new-name>

Examples:
  foundry vm copy my-project my-project-backup
  foundry vm copy production-agent dev-test
  foundry vm rename old-name better-name
```

### Snapshot VM
```bash
foundry vm snapshot <name> <snapshot-name>

Example:
  foundry vm snapshot my-project company-base-v2
  # Creates reusable template
```

### Destroy VM
```bash
foundry vm destroy <name> [--force]

Options:
  --force    Skip confirmation prompt

Examples:
  foundry vm destroy old-project
  foundry vm destroy test --force
```

## Agent Management

### Start Agent
```bash
foundry agent start <vm-name> <agent-type>

Agent Types:
  ralph-claude-code    Autonomous Claude agent (tmux)
  claude-code          Interactive Claude CLI (screen)
  gemini-cli           Interactive Gemini CLI (screen)
  openai-codex         Interactive OpenAI CLI (screen)

Examples:
  foundry agent start my-project ralph-claude-code
  foundry agent start frontend gemini-cli
  foundry agent start backend openai-codex
```

### Stop Agent
```bash
foundry agent stop <vm-name>

Example:
  foundry agent stop my-project
```

### Restart Agent
```bash
foundry agent restart <vm-name>

Example:
  foundry agent restart my-project
```

### Attach to Agent
```bash
foundry agent attach <vm-name>

Example:
  foundry agent attach my-project
  # Attaches to tmux (Ralph) or screen session
  # Detach: Ctrl+B,D (tmux) or Ctrl+A,D (screen)
```

### Agent Status
```bash
foundry agent status <vm-name>
foundry agent status --all

Examples:
  foundry agent status my-project
  foundry agent status --all    # All agents across all VMs
```

### View Agent Logs
```bash
foundry agent logs <vm-name> [options]

Options:
  --follow           Follow log output (like tail -f)
  --tail <N>         Show last N lines
  --since <time>     Show logs since timestamp

Examples:
  foundry agent logs my-project
  foundry agent logs my-project --follow
  foundry agent logs my-project --tail 100
  foundry agent logs my-project --since "1 hour ago"
```

### Auto-start on Boot
```bash
foundry agent enable-autostart <vm-name>
foundry agent disable-autostart <vm-name>

Examples:
  foundry agent enable-autostart production-api
  foundry agent disable-autostart test-project
```

## Workspace Management

### Initialize Ralph Structure
```bash
foundry workspace init-ralph <vm-name>

Example:
  foundry workspace init-ralph my-project
  # Creates PROMPT.md, @fix_plan.md, specs/, logs/ in workspace
```

### Edit Workspace Files
```bash
foundry workspace edit <vm-name> <file>

Examples:
  foundry workspace edit my-project PROMPT.md
  foundry workspace edit my-project context/company.md
  foundry workspace edit my-project memory/progress.md
  # Opens file in $EDITOR via SSH
```

## Template Management

### Build Templates
```bash
foundry template build <type> [options]

Types:
  base               Build base Arch Linux template
  golden             Build golden template (base + AI tools)

Options:
  --packages <file>  Custom packages.txt file
  --ssh-key <path>   SSH key for git auth (golden only)

Examples:
  foundry template build base
  foundry template build base --packages custom-packages.txt
  foundry template build golden --ssh-key ~/.ssh/id_agent
```

### List Templates
```bash
foundry template list

Example:
  foundry template list
  # Shows: base, golden, user snapshots
```

### Delete Template
```bash
foundry template delete <name>

Example:
  foundry template delete old-snapshot
```

## Host Setup

### Initial Setup
```bash
foundry host setup              # Interactive setup wizard
foundry host setup-network      # Configure networking only
foundry host setup-firecracker  # Install Firecracker only

Examples:
  foundry host setup
  # Runs: dependency checks, Firecracker install, network config
```

### Check Host Status
```bash
foundry host status

Example:
  foundry host status
  # Shows: Firecracker version, network config, VM count, resources
```

## Configuration

### View/Edit Config
```bash
foundry config get <key>
foundry config set <key> <value>
foundry config edit

Examples:
  foundry config get default.cpus
  foundry config set default.cpus 8
  foundry config set default.memory 16384
  foundry config set ip_range 172.16.0.10-254
  foundry config edit    # Opens in $EDITOR
```

### Configuration Keys
```
default.cpus           Default CPU cores per VM (default: 50% of host)
default.memory         Default RAM in MB (default: 8192)
default.disk           Default disk size in GB (default: 20)
ip_range               VM IP allocation range (default: 172.16.0.10-254)
gateway_ip             Host gateway IP (default: 172.16.0.1)
template_dir           Template storage location
instance_dir           Instance storage location
log_dir                Log file location
ssh_key                Default SSH key for git auth
```

## Global Options

Available for all commands:
```bash
--help, -h        Show help
--version, -v     Show version
--verbose         Verbose output
--quiet, -q       Minimal output
--dry-run         Show what would happen (no changes)
```

## Environment Variables

```bash
FOUNDRY_CONFIG_DIR    Override config directory (default: ~/.config/foundry)
FOUNDRY_DATA_DIR      Override data directory (default: ~/.local/share/foundry)
FOUNDRY_SSH_KEY       Override default SSH key
EDITOR                Editor for workspace edit command
```

## Exit Codes

```
0     Success
1     General error
2     Invalid arguments
3     VM not found
4     Network error
5     Template error
10    Firecracker error
11    SSH error
```

## Tips

### Quick Status Check
```bash
foundry vm ps --running && foundry agent status --all
```

### Batch Operations
```bash
# Stop all VMs
for vm in $(foundry vm list --running | awk '{print $1}'); do
  foundry vm stop $vm
done
```

### Monitoring Multiple Agents
```bash
# Terminal multiplexer
tmux new-session \; \
  send-keys 'foundry agent logs project1 --follow' C-m \; \
  split-window -v \; \
  send-keys 'foundry agent logs project2 --follow' C-m
```

### Backup Before Destroy
```bash
foundry vm snapshot my-project my-project-backup-$(date +%Y%m%d)
foundry vm destroy my-project
```
