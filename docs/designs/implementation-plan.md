# Project Folders Refactor - Implementation Plan

**Design Doc:** `docs/designs/2025-01-22-project-folders-refactor.md`
**Execution:** Parallel using codex and gemini agents

## Independent Task Groups

Tasks grouped by independence - can be executed in parallel.

---

## Group 1: Setup & Templates (Parallel)

### Task 1A: Create Example Project Structure
**Agent:** codex
**Files:**
- Create `projects/example-project/git-config.json`
- Create `projects/example-project/overview.md`
- Create `projects/example-project/getting-started.md`
- Create `projects/example-project/.ralph/PROMPT.md`
- Create `projects/example-project/.ralph/fix_plan.md`
- Create `projects/example-project/.ralph/AGENT.md`
- Generate example SSH keys: `projects/example-project/deploy-key-example`

**Validation:**
- All files exist
- JSON is valid
- SSH keys are proper format (ssh-keygen)

### Task 1B: Create AGENT.md Template
**Agent:** codex
**Files:**
- Create `templates/AGENT.md.template` with content from design doc

**Validation:**
- File exists with correct content

### Task 1C: Update .gitignore
**Agent:** codex
**Files:**
- Add to `.gitignore`:
  ```
  projects/*
  !projects/example-project/
  ```

**Validation:**
- Git ignores `projects/test-folder/` but not `projects/example-project/`

---

## Group 2: Security Fix (Sequential - wait for Group 1)

### Task 2A: Modify build-golden.sh
**Agent:** codex
**Files:**
- `scripts/build-golden.sh`

**Changes:**
1. Create new function `setup_host_ssh_access()`:
   ```bash
   setup_host_ssh_access() {
       local target_ssh_dir="$1"
       local public_key_path="$2"

       mkdir -p "$target_ssh_dir"
       chmod 700 "$target_ssh_dir"

       # Copy ONLY public key to authorized_keys
       cat "$public_key_path" > "$target_ssh_dir/authorized_keys"
       chmod 600 "$target_ssh_dir/authorized_keys"
       chown -R root:root "$target_ssh_dir"
   }
   ```

2. Replace line 355-363:
   ```bash
   # OLD:
   copy_ssh_keys "$mount_dir/root/.ssh" "$ssh_source"

   # NEW:
   if [[ -n "$ssh_key_arg" ]]; then
       ssh_public_key="$(expand_user_path "$ssh_key_arg")"
       # If directory, look for .pub files
       if [[ -d "$ssh_public_key" ]]; then
           ssh_public_key=$(find "$ssh_public_key" -name "*.pub" | head -1)
       fi
       # If private key specified, add .pub
       if [[ ! "$ssh_public_key" =~ \.pub$ ]]; then
           ssh_public_key="${ssh_public_key}.pub"
       fi
   else
       # Auto-detect from host
       ssh_public_key="${FOUND_HOST_HOME}/.ssh/id_ed25519.pub"
       if [[ ! -f "$ssh_public_key" ]]; then
           ssh_public_key="${FOUND_HOST_HOME}/.ssh/id_rsa.pub"
       fi
   fi

   setup_host_ssh_access "$mount_dir/root/.ssh" "$ssh_public_key"
   ```

3. Remove `copy_ssh_keys()` function (lines 172-200)

**Validation:**
- Build golden template: `sudo foundry template build golden`
- Mount and inspect: NO private keys in `/root/.ssh/`
- Only `authorized_keys` should exist

---

## Group 3: Core Refactor (Parallel - wait for Group 2)

### Task 3A: Modify bin/foundry (CLI)
**Agent:** codex
**Files:**
- `bin/foundry`

**Changes:**
1. In vm create command parsing, add `--project` flag:
   ```bash
   --project)
       PROJECT_NAME="${2:-}"
       if [[ -z "$PROJECT_NAME" ]]; then
           log_error "--project requires a project name"
           exit 1
       fi
       shift 2
       ;;
   ```

2. Validate project exists:
   ```bash
   if [[ -n "$PROJECT_NAME" ]]; then
       PROJECT_DIR="${FOUNDRY_BASE}/projects/${PROJECT_NAME}"
       if [[ ! -d "$PROJECT_DIR" ]]; then
           log_error "Project not found: $PROJECT_DIR"
           exit 1
       fi
       if [[ ! -f "$PROJECT_DIR/git-config.json" ]]; then
           log_error "Project missing git-config.json: $PROJECT_DIR"
           exit 1
       fi
   fi
   ```

3. Call workspace_init with project_dir:
   ```bash
   workspace_init "$VM_NAME" "$PROJECT_DIR"
   ```

4. Remove `--config` flag support entirely

**Validation:**
- `foundry vm create test-vm --project example-project` parses correctly
- Error on missing project
- Error on invalid project (no git-config.json)

### Task 3B: Refactor lib/workspace.sh (Core Logic)
**Agent:** codex
**Files:**
- `lib/workspace.sh`

**Major Changes:**

1. **Modify `workspace_init` signature:**
   ```bash
   workspace_init() {
       local vm_name="$1"
       local project_dir="$2"  # Changed from config_file

       if [[ -z "$vm_name" || -z "$project_dir" ]]; then
           log_error "VM name and project directory required"
           return 1
       fi

       _check_vm_running "$vm_name" || return 1

       local vm_ip
       vm_ip=$(_get_vm_ip "$vm_name")

       local git_config="$project_dir/git-config.json"
       if [[ ! -f "$git_config" ]]; then
           log_error "git-config.json not found in $project_dir"
           return 1
       fi

       local workspace_path="${WORKSPACE_BASE}/${vm_name}"

       log_info "Initializing workspace '$vm_name' in VM..."

       # Create directory structure
       _ssh_cmd "$vm_ip" "mkdir -p '$workspace_path'/{repos,context,memory,logs}"

       # Setup SSH keys and clone repos
       _setup_ssh_keys "$vm_ip" "$project_dir" "$git_config"
       _clone_repositories "$vm_ip" "$workspace_path" "$project_dir" "$git_config"

       # Copy project files
       _copy_project_files "$vm_ip" "$workspace_path" "$project_dir"

       # Initialize memory files
       _init_memory_files "$vm_ip" "$workspace_path" "$vm_name"

       # Update registry
       registry_update "$vm_name" ".workspace" "\"$vm_name\""

       log_info "Workspace initialized: $workspace_path"
   }
   ```

2. **Create `_setup_ssh_keys` function:**
   ```bash
   _setup_ssh_keys() {
       local vm_ip="$1"
       local project_dir="$2"
       local git_config="$3"

       log_info "Setting up SSH keys..."

       # Parse git-config.json to extract repos
       local repos_count
       repos_count=$(jq '.repositories | length' "$git_config")

       # Copy deploy keys and build SSH config
       local ssh_config_content="# Auto-generated by Agent Foundry\n\n"

       local i=0
       local copied_keys=()

       while [[ $i -lt $repos_count ]]; do
           local repo_name repo_url ssh_key
           repo_name=$(jq -r ".repositories[$i].name" "$git_config")
           repo_url=$(jq -r ".repositories[$i].url" "$git_config")
           ssh_key=$(jq -r ".repositories[$i].ssh_key" "$git_config")

           # Extract domain from URL (git@github.com:... -> github.com)
           local domain
           domain=$(echo "$repo_url" | sed -n 's/.*@\([^:]*\):.*/\1/p')

           # Copy key if not already copied
           if [[ ! " ${copied_keys[@]} " =~ " ${ssh_key} " ]]; then
               local key_path="$project_dir/$ssh_key"
               if [[ ! -f "$key_path" ]]; then
                   log_error "SSH key not found: $key_path"
                   return 1
               fi

               # Copy private key to VM
               _scp_to_vm "$vm_ip" "$key_path" "/root/.ssh/$ssh_key"
               _ssh_cmd "$vm_ip" "chmod 600 /root/.ssh/$ssh_key"

               copied_keys+=("$ssh_key")
               log_debug "Copied key: $ssh_key"
           fi

           # Add to SSH config
           ssh_config_content+="Host ${domain}-${repo_name}\n"
           ssh_config_content+="    HostName ${domain}\n"
           ssh_config_content+="    User git\n"
           ssh_config_content+="    IdentityFile ~/.ssh/${ssh_key}\n"
           ssh_config_content+="    StrictHostKeyChecking no\n\n"

           i=$((i + 1))
       done

       # Write SSH config to VM
       _ssh_cmd "$vm_ip" "cat > /root/.ssh/config" <<< "$(echo -e "$ssh_config_content")"
       _ssh_cmd "$vm_ip" "chmod 600 /root/.ssh/config"

       log_info "SSH keys configured for $repos_count repositories"
   }
   ```

3. **Modify `_clone_repositories` function:**
   ```bash
   _clone_repositories() {
       local vm_ip="$1"
       local workspace_path="$2"
       local project_dir="$3"
       local git_config="$4"

       local repos_count
       repos_count=$(jq '.repositories | length' "$git_config")

       if [[ "$repos_count" -eq 0 ]]; then
           log_debug "No repositories to clone"
           return 0
       fi

       log_info "Cloning $repos_count repositories..."

       local i=0
       while [[ $i -lt $repos_count ]]; do
           local repo_name repo_url repo_branch
           repo_name=$(jq -r ".repositories[$i].name" "$git_config")
           repo_url=$(jq -r ".repositories[$i].url" "$git_config")
           repo_branch=$(jq -r ".repositories[$i].branch // \"main\"" "$git_config")

           # Extract domain (git@github.com:... -> github.com)
           local domain
           domain=$(echo "$repo_url" | sed -n 's/.*@\([^:]*\):.*/\1/p')

           # Modify URL to use SSH config Host alias
           # git@github.com:org/repo.git -> git@github.com-reponame:org/repo.git
           local modified_url
           modified_url=$(echo "$repo_url" | sed "s/@${domain}/@${domain}-${repo_name}/")

           log_debug "Cloning $repo_name from $modified_url (branch: $repo_branch)..."

           _ssh_cmd "$vm_ip" "cd '${workspace_path}/repos' && \
               git clone --branch '$repo_branch' '$modified_url' '$repo_name' 2>&1" || {
               log_warn "Failed to clone $repo_name"
           }

           i=$((i + 1))
       done
   }
   ```

4. **Create `_copy_project_files` function:**
   ```bash
   _copy_project_files() {
       local vm_ip="$1"
       local workspace_path="$2"
       local project_dir="$3"

       log_info "Copying project files..."

       # Copy AGENT.md template
       local agent_template="${TEMPLATES_DIR}/../AGENT.md.template"
       if [[ -f "$agent_template" ]]; then
           _scp_to_vm "$vm_ip" "$agent_template" "${workspace_path}/AGENT.md"
       fi

       # Copy .ralph/ folder if exists
       if [[ -d "$project_dir/.ralph" ]]; then
           log_debug "Copying .ralph/ folder..."
           _ssh_cmd "$vm_ip" "mkdir -p '${workspace_path}/.ralph'"
           _scp_to_vm "$vm_ip" "$project_dir/.ralph/." "${workspace_path}/.ralph/"
       fi

       # Copy all .md files to context/ (excluding .ralph/)
       local md_files
       md_files=$(find "$project_dir" -maxdepth 1 -name "*.md" -type f)

       if [[ -n "$md_files" ]]; then
           log_debug "Copying .md files to context/..."
           while IFS= read -r md_file; do
               if [[ -f "$md_file" ]]; then
                   local filename
                   filename=$(basename "$md_file")
                   _scp_to_vm "$vm_ip" "$md_file" "${workspace_path}/context/${filename}"
               fi
           done <<< "$md_files"
       fi
   }
   ```

5. **Remove functions:**
   - `_copy_context_files()` - No longer needed
   - `_validate_config_file()` - workspace.json validation

**Validation:**
- Create VM with `--project example-project`
- SSH in, verify:
  - `/root/.ssh/config` exists with correct Host entries
  - `/root/.ssh/deploy-key-example` exists (600 perms)
  - `/work/test-vm/AGENT.md` exists
  - `/work/test-vm/.ralph/` exists with files
  - `/work/test-vm/context/*.md` files exist
  - `/work/test-vm/repos/` has cloned repos

---

## Group 4: Cleanup (Parallel - wait for Group 3)

### Task 4A: Remove Old Templates
**Agent:** codex
**Files:**
- Remove `templates/workspace/workspace.json.example`
- Remove `templates/workspace/context/*.md.example` (if any exist)

**Keep:**
- `templates/workspace/memory/*.md` (used for empty file creation)

**Validation:**
- Files removed
- Memory templates still exist

### Task 4B: Remove workspace.json References
**Agent:** gemini
**Files:**
- Search codebase for "workspace.json" references
- Remove or update any remaining references

**Validation:**
- No workspace.json references except in design docs

---

## Group 5: Documentation (Parallel - wait for Group 4)

### Task 5A: Update Core Documentation
**Agent:** gemini
**Files:**
- `README.md` - Update quick start, examples
- `docs/CLI-REFERENCE.md` - Document --project flag, remove --config
- `docs/ARCHITECTURE.md` - Update security model, project folders

**Changes:**
- Replace all `--config workspace.json` with `--project <name>`
- Document new security model (no private keys in golden)
- Explain project folder structure

**Validation:**
- All examples use new CLI
- No references to workspace.json

### Task 5B: Create New Documentation
**Agent:** gemini
**Files:**
- Create `docs/PROJECT-SETUP.md`

**Content:**
- How to create a project folder
- git-config.json format and examples
- How to generate deploy keys
- .md file conventions
- Ralph-specific .ralph/ folder
- Multi-agent support (Ralph vs Claude Code)

**Validation:**
- Complete guide exists
- Examples are accurate

### Task 5C: Update VM Lifecycle Docs
**Agent:** gemini
**Files:**
- `docs/planning/vm-lifecycle.md`

**Changes:**
- Update workflow examples
- New project-based creation flow
- Remove workspace.json references

**Validation:**
- Workflow matches new design

---

## Group 6: Testing (Sequential - wait for Group 5)

### Task 6: End-to-End Testing
**Agent:** codex
**Test Cases:**

1. Build golden template:
   ```bash
   sudo foundry template build golden
   # Mount and verify: NO private keys in /root/.ssh/
   ```

2. Create VM from example-project:
   ```bash
   foundry vm create test-vm-1 --project example-project
   ```

3. Verify workspace structure:
   ```bash
   foundry vm ssh test-vm-1
   ls -la /work/test-vm-1/
   cat /root/.ssh/config
   ls -la /root/.ssh/
   cat /work/test-vm-1/AGENT.md
   ls /work/test-vm-1/.ralph/
   ls /work/test-vm-1/context/
   ls /work/test-vm-1/repos/
   ```

4. Test multi-VM from same project:
   ```bash
   foundry vm create test-vm-2 --project example-project
   # Both should work independently
   ```

5. Test Ralph workflow:
   ```bash
   foundry agent start test-vm-1 ralph-claude-code
   foundry agent attach test-vm-1
   # Verify Ralph sees .ralph/ folder
   ```

**Success Criteria:**
- All tests pass
- No private keys in golden template
- SSH keys work correctly
- Repos clone successfully
- Documentation accurate

---

## Execution Order

```
Group 1 (Setup & Templates) - Parallel
   ├─ Task 1A: Example project
   ├─ Task 1B: AGENT.md template
   └─ Task 1C: .gitignore

↓

Group 2 (Security Fix) - Sequential
   └─ Task 2A: build-golden.sh

↓

Group 3 (Core Refactor) - Parallel
   ├─ Task 3A: bin/foundry
   └─ Task 3B: lib/workspace.sh

↓

Group 4 (Cleanup) - Parallel
   ├─ Task 4A: Remove templates
   └─ Task 4B: Remove references

↓

Group 5 (Documentation) - Parallel
   ├─ Task 5A: Core docs
   ├─ Task 5B: PROJECT-SETUP.md
   └─ Task 5C: VM lifecycle

↓

Group 6 (Testing) - Sequential
   └─ Task 6: End-to-end tests
```

## Agent Assignments

**Codex (shell scripts, CLI):**
- Task 1A, 1B, 1C
- Task 2A
- Task 3A, 3B
- Task 4A
- Task 6

**Gemini (documentation):**
- Task 4B
- Task 5A, 5B, 5C

Total: 13 tasks across 6 groups
