#!/usr/bin/env bash
#
# Agent Foundry - Workspace Management
#
# Functions for initializing and managing workspaces inside VMs.
# Workspaces contain repositories, context files, and agent memory.
#
# Workspace structure:
# /work/<project-name>/
# ├── PROMPT.md              # Ralph instructions
# ├── @fix_plan.md           # Task list
# ├── workspace.json         # Configuration
# ├── README.md              # Project overview
# ├── repos/                 # Git repositories
# │   ├── backend/
# │   └── frontend/
# ├── context/               # AI context (read-only)
# │   ├── company.md
# │   ├── instructions.md
# │   ├── coding-standards.md
# │   └── architecture.md
# ├── memory/                # Agent memory (read-write)
# │   ├── decisions.md
# │   ├── progress.md
# │   ├── blockers.md
# │   └── learnings.md
# └── logs/                  # Agent logs
#

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    source "${SCRIPT_DIR}/utils.sh"
fi
if [[ -f "${SCRIPT_DIR}/registry.sh" ]]; then
    source "${SCRIPT_DIR}/registry.sh"
fi
if [[ -f "${SCRIPT_DIR}/vm.sh" ]]; then
    source "${SCRIPT_DIR}/vm.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Workspace paths
WORKSPACE_BASE="/work"

# Template locations on host
FOUNDRY_BASE_DIR="${FOUNDRY_BASE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TEMPLATES_DIR="${FOUNDRY_BASE_DIR}/templates/workspace"

# SSH settings
FOUNDRY_SSH_USER="${FOUNDRY_SSH_USER:-root}"
FOUNDRY_SSH_OPTS="${FOUNDRY_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

_get_vm_ip() {
    local vm_name="$1"
    registry_get "$vm_name" ".ip"
}

_ssh_cmd() {
    local vm_ip="$1"
    shift
    ssh $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "$@"
}

_scp_to_vm() {
    local vm_ip="$1"
    local source="$2"
    local dest="$3"
    scp $FOUNDRY_SSH_OPTS -r "$source" "${FOUNDRY_SSH_USER}@${vm_ip}:${dest}"
}

_check_vm_running() {
    local vm_name="$1"
    local status
    status=$(registry_get "$vm_name" ".status" 2>/dev/null)
    if [[ "$status" != "running" ]]; then
        log_error "VM '$vm_name' is not running (status: ${status:-unknown})"
        return 1
    fi
    return 0
}

_validate_config_file() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "Invalid JSON in config file: $config_file"
        return 1
    fi

    # Check required fields
    local name
    name=$(jq -r '.name // empty' "$config_file")
    if [[ -z "$name" ]]; then
        log_error "Config missing required 'name' field"
        return 1
    fi

    return 0
}

# ============================================================================
# WORKSPACE INITIALIZATION
# ============================================================================

# Initialize workspace in VM from config file
# Usage: workspace_init <vm_name> <config_file>
#
# Config file format (JSON):
# {
#   "name": "project-name",
#   "repositories": [
#     {"name": "backend", "url": "git@github.com:org/backend.git", "branch": "main"},
#     {"name": "frontend", "url": "git@github.com:org/frontend.git"}
#   ],
#   "agent": {
#     "default_cli": "claude",
#     "context_files": ["company.md", "instructions.md"]
#   }
# }
workspace_init() {
    local vm_name="$1"
    local config_file="$2"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    if [[ -z "$config_file" ]]; then
        log_error "Config file required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1
    _validate_config_file "$config_file" || return 1

    local vm_ip
    vm_ip=$(_get_vm_ip "$vm_name")

    # Parse config
    local project_name
    project_name=$(jq -r '.name' "$config_file")

    local workspace_path="${WORKSPACE_BASE}/${project_name}"

    log_info "Initializing workspace '$project_name' in VM '$vm_name'..."

    # Create workspace directory structure
    log_debug "Creating workspace directory structure..."
    _ssh_cmd "$vm_ip" "mkdir -p '$workspace_path'/{repos,context,memory,logs,specs}"

    # Create base files
    log_debug "Creating base workspace files..."

    # workspace.json - copy config
    _scp_to_vm "$vm_ip" "$config_file" "${workspace_path}/workspace.json"

    # README.md
    _ssh_cmd "$vm_ip" "cat > '${workspace_path}/README.md'" << EOF
# ${project_name}

This workspace was created by Agent Foundry.

## Structure

- \`repos/\` - Git repositories
- \`context/\` - Context files for AI agents (read-only reference)
- \`memory/\` - Agent memory files (updated by agents)
- \`logs/\` - Agent execution logs
- \`specs/\` - Specifications and requirements

## Agent

Start agent with: \`foundry agent start $vm_name\`
Attach to session: \`foundry agent attach $vm_name\`

## Configuration

See \`workspace.json\` for project configuration.
EOF

    # Clone repositories
    _clone_repositories "$vm_ip" "$workspace_path" "$config_file"

    # Copy context templates
    _copy_context_files "$vm_ip" "$workspace_path" "$config_file"

    # Initialize memory files
    _init_memory_files "$vm_ip" "$workspace_path" "$project_name"

    # Update registry with workspace info
    registry_update "$vm_name" ".workspace" "\"$project_name\""

    log_info "Workspace initialized: $workspace_path"
    log_info "Next steps:"
    log_info "  1. Edit context files: foundry workspace edit $vm_name context/instructions.md"
    log_info "  2. Initialize Ralph: foundry workspace init-ralph $vm_name"
    log_info "  3. Start agent: foundry agent start $vm_name"

    return 0
}

# Clone repositories specified in config
_clone_repositories() {
    local vm_ip="$1"
    local workspace_path="$2"
    local config_file="$3"

    local repos_count
    repos_count=$(jq '.repositories | length' "$config_file")

    if [[ "$repos_count" -eq 0 ]]; then
        log_debug "No repositories to clone"
        return 0
    fi

    log_info "Cloning $repos_count repositories..."

    local i=0
    while [[ $i -lt $repos_count ]]; do
        local repo_name repo_url repo_branch
        repo_name=$(jq -r ".repositories[$i].name" "$config_file")
        repo_url=$(jq -r ".repositories[$i].url" "$config_file")
        repo_branch=$(jq -r ".repositories[$i].branch // \"main\"" "$config_file")

        log_debug "Cloning $repo_name from $repo_url (branch: $repo_branch)..."

        _ssh_cmd "$vm_ip" "cd '${workspace_path}/repos' && \
            git clone --branch '$repo_branch' '$repo_url' '$repo_name' 2>&1" || {
            log_warn "Failed to clone $repo_name - may need SSH keys configured"
        }

        i=$((i + 1))
    done
}

# Copy context files from templates
_copy_context_files() {
    local vm_ip="$1"
    local workspace_path="$2"
    local config_file="$3"

    log_debug "Copying context file templates..."

    # Copy all context templates
    local context_files=("company.md" "instructions.md" "coding-standards.md" "architecture.md")

    for file in "${context_files[@]}"; do
        local template="${TEMPLATES_DIR}/context/${file}.example"
        if [[ -f "$template" ]]; then
            _scp_to_vm "$vm_ip" "$template" "${workspace_path}/context/${file}"
            log_debug "Copied $file"
        else
            # Create placeholder if template doesn't exist
            _ssh_cmd "$vm_ip" "echo '# ${file%.md}' > '${workspace_path}/context/${file}'"
            _ssh_cmd "$vm_ip" "echo '' >> '${workspace_path}/context/${file}'"
            _ssh_cmd "$vm_ip" "echo 'TODO: Add content for ${file}' >> '${workspace_path}/context/${file}'"
        fi
    done
}

# Initialize memory files
_init_memory_files() {
    local vm_ip="$1"
    local workspace_path="$2"
    local project_name="$3"

    log_debug "Initializing memory files..."

    local timestamp
    timestamp=$(date -Iseconds)

    # decisions.md
    _ssh_cmd "$vm_ip" "cat > '${workspace_path}/memory/decisions.md'" << EOF
# Design Decisions

Track important technical decisions made during development.

## Format

### [Date] Decision Title
- **Context**: Why this decision was needed
- **Decision**: What was decided
- **Consequences**: What this means going forward

---

*Initialized: $timestamp*
EOF

    # progress.md
    _ssh_cmd "$vm_ip" "cat > '${workspace_path}/memory/progress.md'" << EOF
# Work Progress

Track completed work and milestones.

## Current Sprint

### In Progress
- [ ] ...

### Completed
- [x] Workspace initialized ($timestamp)

---

*Last updated: $timestamp*
EOF

    # blockers.md
    _ssh_cmd "$vm_ip" "cat > '${workspace_path}/memory/blockers.md'" << EOF
# Current Blockers

Track issues blocking progress and their resolution.

## Active Blockers

*None currently*

## Resolved Blockers

---

*Last updated: $timestamp*
EOF

    # learnings.md
    _ssh_cmd "$vm_ip" "cat > '${workspace_path}/memory/learnings.md'" << EOF
# Patterns & Learnings

Track patterns discovered and lessons learned about this codebase.

## Codebase Patterns

*Discover patterns as you work*

## Common Pitfalls

*Document issues to avoid*

---

*Initialized: $timestamp*
EOF
}

# ============================================================================
# RALPH INITIALIZATION
# ============================================================================

# Initialize Ralph structure in workspace
# Usage: workspace_init_ralph <vm_name>
workspace_init_ralph() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip workspace_name workspace_path
    vm_ip=$(_get_vm_ip "$vm_name")
    workspace_name=$(registry_get "$vm_name" ".workspace" 2>/dev/null)

    if [[ -z "$workspace_name" || "$workspace_name" == "null" ]]; then
        workspace_name="$vm_name"
    fi

    workspace_path="${WORKSPACE_BASE}/${workspace_name}"

    log_info "Initializing Ralph in workspace '$workspace_name'..."

    # Check if workspace exists
    if ! _ssh_cmd "$vm_ip" "test -d '$workspace_path'"; then
        log_error "Workspace not found: $workspace_path"
        log_info "Initialize workspace first with: foundry workspace init $vm_name <config.json>"
        return 1
    fi

    # Create PROMPT.md
    log_debug "Creating PROMPT.md..."

    local prompt_template="${TEMPLATES_DIR}/PROMPT.md.example"
    if [[ -f "$prompt_template" ]]; then
        _scp_to_vm "$vm_ip" "$prompt_template" "${workspace_path}/PROMPT.md"
    else
        _ssh_cmd "$vm_ip" "cat > '${workspace_path}/PROMPT.md'" << 'EOF'
# Project: {{PROJECT_NAME}}

## Current Focus
Describe the current task or feature being worked on.

## Instructions
1. Read context files in `context/` for project guidelines
2. Update `memory/progress.md` as you complete tasks
3. Document decisions in `memory/decisions.md`
4. Note any blockers in `memory/blockers.md`

## Tasks
See `@fix_plan.md` for prioritized task list.

## Repository Structure
- `repos/` - Git repositories for this project

## Notes
- Commit frequently with clear messages
- Run tests before committing
- Ask for clarification if requirements are unclear
EOF
    fi

    # Create @fix_plan.md
    log_debug "Creating @fix_plan.md..."

    local fixplan_template="${TEMPLATES_DIR}/@fix_plan.md.example"
    if [[ -f "$fixplan_template" ]]; then
        _scp_to_vm "$vm_ip" "$fixplan_template" "${workspace_path}/@fix_plan.md"
    else
        _ssh_cmd "$vm_ip" "cat > '${workspace_path}/@fix_plan.md'" << 'EOF'
# Task List

## Priority 1 - Critical
- [ ] ...

## Priority 2 - High
- [ ] ...

## Priority 3 - Normal
- [ ] ...

## Completed
- [x] Workspace setup
EOF
    fi

    # Ensure logs directory exists
    _ssh_cmd "$vm_ip" "mkdir -p '${workspace_path}/logs'"

    # Check if Ralph is installed
    if _ssh_cmd "$vm_ip" "command -v ralph >/dev/null 2>&1"; then
        log_info "Ralph is installed and ready"
    else
        log_warn "Ralph not found in VM. Install with:"
        log_warn "  foundry vm ssh $vm_name"
        log_warn "  npm install -g ralph-claude-code"
    fi

    log_info "Ralph initialization complete"
    log_info "Edit PROMPT.md to set current task: foundry workspace edit $vm_name PROMPT.md"
    log_info "Start Ralph: foundry agent start $vm_name ralph"

    return 0
}

# ============================================================================
# WORKSPACE EDITING
# ============================================================================

# Edit a workspace file via SSH
# Usage: workspace_edit <vm_name> <file>
workspace_edit() {
    local vm_name="$1"
    local file="$2"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    if [[ -z "$file" ]]; then
        log_error "File path required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip workspace_name workspace_path
    vm_ip=$(_get_vm_ip "$vm_name")
    workspace_name=$(registry_get "$vm_name" ".workspace" 2>/dev/null)

    if [[ -z "$workspace_name" || "$workspace_name" == "null" ]]; then
        workspace_name="$vm_name"
    fi

    workspace_path="${WORKSPACE_BASE}/${workspace_name}"

    # Determine full path
    local full_path
    if [[ "$file" == /* ]]; then
        full_path="$file"
    else
        full_path="${workspace_path}/${file}"
    fi

    # Check if file exists
    if ! _ssh_cmd "$vm_ip" "test -f '$full_path'"; then
        log_warn "File does not exist: $full_path"
        if confirm "Create new file?"; then
            _ssh_cmd "$vm_ip" "touch '$full_path'"
        else
            return 1
        fi
    fi

    log_info "Opening $full_path in editor..."

    # Determine editor
    local editor="${EDITOR:-vim}"

    # Open SSH connection with editor
    exec ssh -t $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "$editor '$full_path'"
}

# ============================================================================
# WORKSPACE INFO
# ============================================================================

# Show workspace information
# Usage: workspace_info <vm_name>
workspace_info() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_error "VM name required"
        return 1
    fi

    _check_vm_running "$vm_name" || return 1

    local vm_ip workspace_name workspace_path
    vm_ip=$(_get_vm_ip "$vm_name")
    workspace_name=$(registry_get "$vm_name" ".workspace" 2>/dev/null)

    if [[ -z "$workspace_name" || "$workspace_name" == "null" ]]; then
        workspace_name="$vm_name"
    fi

    workspace_path="${WORKSPACE_BASE}/${workspace_name}"

    echo "Workspace: $workspace_name"
    echo "Path: $workspace_path"
    echo "VM: $vm_name ($vm_ip)"
    echo ""

    # Check if workspace exists
    if ! _ssh_cmd "$vm_ip" "test -d '$workspace_path'"; then
        echo "Status: NOT INITIALIZED"
        echo ""
        echo "Initialize with: foundry workspace init $vm_name <config.json>"
        return 0
    fi

    echo "Status: Initialized"
    echo ""

    # Show workspace.json if exists
    if _ssh_cmd "$vm_ip" "test -f '${workspace_path}/workspace.json'"; then
        echo "=== Configuration ==="
        _ssh_cmd "$vm_ip" "jq '.' '${workspace_path}/workspace.json' 2>/dev/null" || \
            _ssh_cmd "$vm_ip" "cat '${workspace_path}/workspace.json'"
        echo ""
    fi

    # Show repositories
    echo "=== Repositories ==="
    _ssh_cmd "$vm_ip" "ls -1 '${workspace_path}/repos/' 2>/dev/null" | \
        while read -r repo; do
            echo "  $repo"
        done
    echo ""

    # Show context files
    echo "=== Context Files ==="
    _ssh_cmd "$vm_ip" "ls -1 '${workspace_path}/context/' 2>/dev/null" | \
        while read -r file; do
            echo "  $file"
        done
    echo ""

    # Show disk usage
    echo "=== Disk Usage ==="
    _ssh_cmd "$vm_ip" "du -sh '${workspace_path}' 2>/dev/null" || echo "  Unknown"

    return 0
}

# ============================================================================
# WORKSPACE TEMPLATES
# ============================================================================

# Create a workspace config template
# Usage: workspace_template <output_file>
workspace_template() {
    local output_file="${1:-workspace.json}"

    log_info "Creating workspace config template: $output_file"

    cat > "$output_file" << 'EOF'
{
  "name": "my-project",
  "description": "Project description here",
  "repositories": [
    {
      "name": "backend",
      "url": "git@github.com:myorg/backend.git",
      "branch": "main"
    },
    {
      "name": "frontend",
      "url": "git@github.com:myorg/frontend.git",
      "branch": "main"
    }
  ],
  "agent": {
    "default_cli": "claude",
    "auto_start": false,
    "context_files": [
      "company.md",
      "instructions.md",
      "coding-standards.md",
      "architecture.md"
    ]
  },
  "settings": {
    "git_user_name": "AI Agent",
    "git_user_email": "agent@example.com"
  }
}
EOF

    log_info "Template created. Edit and use with: foundry workspace init <vm> $output_file"
    return 0
}

# ============================================================================
# TESTING/EXAMPLES
# ============================================================================
#
# Example workflow:
#
#   # Create config template
#   workspace_template my-project.json
#
#   # Edit configuration
#   vim my-project.json
#
#   # Initialize workspace in VM
#   workspace_init my-project my-project.json
#
#   # Initialize Ralph
#   workspace_init_ralph my-project
#
#   # Edit files
#   workspace_edit my-project PROMPT.md
#   workspace_edit my-project context/instructions.md
#
#   # Show workspace info
#   workspace_info my-project
#
#   # Start agent
#   foundry agent start my-project ralph
#
