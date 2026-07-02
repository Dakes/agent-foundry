# Agent Foundry - Implementation TODO

## Project Status

🚧 **Phase 2+: Active Development** - In Progress

## Phase 1: Foundation & Core Structure ✅

### Documentation ✅
- [x] Create ARCHITECTURE.md
- [x] Create VISION.md
- [x] Create CLI-REFERENCE.md
- [x] Create RALPH-INTEGRATION.md
- [x] Create README.md
- [x] Create TODO.md
- [x] Set up project structure
- [x] Initialize git repository

### Project Setup 🔄
- [x] Create LICENSE file (MIT)
- [x] Create shell.nix for NixOS development
- [x] Create install.sh script
- [x] Set up config/ directory with default configs
- [x] Create template workspace files
- [ ] Create template systemd service
- [x] Create example project config files

## Phase 2: Host Setup & Dependencies

### Host Configuration Scripts
- [x] `scripts/setup-host.sh` - Master setup script
  - [ ] Detect host OS (Arch, NixOS, Ubuntu, Fedora)
  - [ ] Check for KVM support
  - [ ] Check/install dependencies
  - [ ] Run network setup
  - [ ] Install Firecracker if needed
  - [ ] Initialize config directories
  - [ ] Validate setup

- [x] `scripts/install-firecracker.sh`
  - [ ] Download Firecracker binary
  - [ ] Verify checksum
  - [ ] Install to /usr/local/bin/
  - [ ] Set permissions
  - [ ] Test execution

- [x] `scripts/setup-network.sh`
  - [ ] Enable IP forwarding
  - [ ] Create base TAP device structure
  - [ ] Configure iptables/nftables NAT
  - [ ] Set up routing rules
  - [ ] Make persistent across reboots
  - [ ] Validate network connectivity

### Dependency Checking
- [x] `lib/utils.sh` - Utility functions
  - [x] `check_command()` - Check if command exists
  - [x] `check_kvm()` - Verify KVM available
  - [x] `detect_os()` - Detect host OS
  - [x] `log_info/warn/error()` - Logging functions
  - [x] `confirm()` - User confirmation prompts
  - [x] `cleanup_on_exit()` - Trap handlers

## Phase 3: VM Template Building

### Base Template Builder
- [x] `scripts/build-ubuntu-base.sh`
  - [ ] Create disk image with qemu-img
  - [ ] Format as ext4
  - [ ] Mount loopback
  - [ ] Download Ubuntu rootfs from Firecracker S3
  - [ ] Configure systemd-networkd
  - [ ] Enable sshd
  - [ ] Configure SSH authorized_keys
  - [ ] Disable root password
  - [ ] Set timezone/locale
  - [ ] Unmount and finalize
  - [ ] Test boot with Firecracker

### Golden Template Builder
- [x] `scripts/build-golden.sh`
  - [ ] Copy base template
  - [ ] Mount and chroot
  - [ ] Install Node.js and npm
  - [ ] Install Python and pip
  - [ ] Install Docker
  - [ ] Install Claude Code CLI
  - [ ] Install Gemini CLI
  - [ ] Install OpenAI CLI
  - [ ] Clone and install ralph-claude-code
  - [ ] Install additional packages from packages.txt
  - [ ] Copy SSH keys for git
  - [ ] Configure git global settings
  - [ ] Create /work directory
  - [ ] Unmount and finalize

### Kernel Preparation
- [x] `scripts/prepare-kernel.sh`
  - [ ] Download kernel source (or extract from Arch)
  - [ ] Use Firecracker microvm config
  - [ ] Build vmlinux
  - [ ] Or extract from Arch kernel
  - [ ] Place in templates directory

### Template Management Module
- [x] `lib/template.sh`
  - [x] `template_list()` - List available templates
  - [x] `template_build()` - Build template (calls scripts)
  - [x] `template_delete()` - Delete template
  - [x] `template_exists()` - Check if template exists
  - [x] `template_path()` - Get template file path

## Phase 4: VM Lifecycle Management

### VM Creation
- [x] `lib/vm.sh` - Core VM functions
  - [x] `vm_create()` - Create new VM
    - [ ] Parse arguments (name, config, from snapshot)
    - [ ] Allocate IP address (read registry)
    - [ ] Generate TAP device name
    - [ ] Copy template to instance disk
    - [ ] Apply copy-on-write if supported (btrfs/xfs)
    - [ ] Generate Firecracker config JSON
    - [ ] Update registry
    - [ ] Boot VM
    - [ ] Wait for SSH
    - [ ] Initialize workspace
    - [ ] Clone repositories
    - [ ] Copy workspace template files
    - [ ] Return success

  - [x] `vm_start()` - Start stopped VM
    - [ ] Read VM config from registry
    - [ ] Create TAP device
    - [ ] Start Firecracker process
    - [ ] Update registry status
    - [ ] Wait for SSH

  - [x] `vm_stop()` - Stop running VM
    - [ ] Send graceful shutdown to VM
    - [ ] Wait for process exit
    - [ ] Force kill if --force flag
    - [ ] Remove TAP device
    - [ ] Update registry status

  - [x] `vm_restart()` - Restart VM
    - [ ] Call vm_stop()
    - [ ] Call vm_start()

  - [x] `vm_destroy()` - Destroy VM
    - [ ] Confirm with user (unless --force)
    - [ ] Stop VM if running
    - [ ] Delete disk file
    - [ ] Remove from registry
    - [ ] Clean up TAP device

  - [x] `vm_ssh()` - SSH into VM
    - [ ] Read IP from registry
    - [ ] Exec ssh command

  - [x] `vm_list()` - List VMs
    - [ ] Read registry
    - [ ] Filter by status (--all, --running, --stopped)
    - [ ] Format output (table)

  - [x] `vm_status()` - Show VM details
    - [ ] Read from registry
    - [ ] Check Firecracker process
    - [ ] Test SSH connectivity
    - [ ] Show resource usage
    - [ ] Format detailed output

  - [x] `vm_ip()` - Get VM IP
    - [ ] Read from registry
    - [ ] Return IP address

### VM Operations
- [x] `lib/vm.sh` - Extended operations
  - [x] `vm_copy()` - Copy VM
    - [ ] Stop source VM if running
    - [ ] Copy disk file
    - [ ] Allocate new IP
    - [ ] Generate new TAP device
    - [ ] Register new VM
    - [ ] Optionally rename workspace inside

  - [x] `vm_rename()` - Rename VM
    - [ ] Stop VM
    - [ ] Rename disk file
    - [ ] Update registry
    - [ ] Rename workspace inside VM
    - [ ] Restart if was running

  - [x] `vm_snapshot()` - Create snapshot
    - [ ] Stop VM
    - [ ] Copy to templates directory
    - [ ] Add to template list
    - [ ] Restart VM

## Phase 5: Networking Management

### Network Module
- [x] `lib/network.sh`
  - [x] `network_init()` - Initialize networking
    - [ ] Create host TAP bridge/gateway
    - [ ] Set up IP forwarding
    - [ ] Configure NAT rules
    - [ ] Verify connectivity

  - [x] `network_create_tap()` - Create TAP device
    - [ ] Generate device name
    - [ ] Create with ip tuntap add
    - [ ] Configure IP address
    - [ ] Bring up interface
    - [ ] Add routing rules

  - [x] `network_destroy_tap()` - Remove TAP device
    - [ ] Bring down interface
    - [ ] Delete device
    - [ ] Remove routing rules

  - [x] `network_allocate_ip()` - Allocate IP from pool
    - [ ] Read next_ip from registry
    - [ ] Increment and save
    - [ ] Return allocated IP

  - [x] `network_release_ip()` - Release IP back to pool
    - [ ] Mark as available (future optimization)

  - [x] `network_status()` - Show network status
    - [ ] List TAP devices
    - [ ] Show IP allocations
    - [ ] Test connectivity

## Phase 6: Registry Management

### Registry Module
- [x] `lib/registry.sh`
  - [x] `registry_init()` - Initialize registry file
    - [ ] Create ~/.config/foundry/vms.json
    - [ ] Write initial structure

  - [x] `registry_add()` - Add VM to registry
    - [ ] Read JSON
    - [ ] Add VM entry
    - [ ] Write JSON

  - [x] `registry_update()` - Update VM entry
    - [ ] Read JSON
    - [ ] Update fields
    - [ ] Write JSON

  - [x] `registry_remove()` - Remove VM from registry
    - [ ] Read JSON
    - [ ] Remove entry
    - [ ] Write JSON

  - [x] `registry_get()` - Get VM info
    - [ ] Read JSON
    - [ ] Return VM object

  - [x] `registry_list()` - List all VMs
    - [ ] Read JSON
    - [ ] Return VM array

  - [x] `registry_lock()` - Lock for concurrent access
  - [x] `registry_unlock()` - Release lock

## Phase 7: Workspace Management

### Workspace Module
- [x] `lib/workspace.sh`
  - [x] `workspace_init()` - Initialize workspace in VM
    - [ ] SSH into VM
    - [ ] Create /work/<name> structure
    - [ ] Copy template files from framework
    - [ ] Set permissions
    - [ ] Clone repositories from config
    - [ ] Initialize git config

  - [x] `workspace_init_ralph()` - Initialize Ralph structure
    - [ ] SSH into VM
    - [ ] Run ralph-setup in workspace
    - [ ] Create PROMPT.md template
    - [ ] Create fix_plan.md template
    - [ ] Create specs/ and logs/

  - [x] `workspace_edit()` - Edit workspace file
    - [ ] SSH into VM
    - [ ] Open file in $EDITOR

## Phase 8: Agent Management

### Agent Module
- [x] `lib/agent.sh`
  - [x] `agent_start()` - Start agent
    - [ ] Determine agent type
    - [ ] SSH into VM
    - [ ] Start appropriate CLI in tmux/screen
    - [ ] For ralph-claude-code: run ralph-loop
    - [ ] For others: start CLI in screen
    - [ ] Update registry with agent info
    - [ ] Return session name

  - [x] `agent_stop()` - Stop agent
    - [ ] Read agent info from registry
    - [ ] SSH into VM
    - [ ] Kill tmux/screen session
    - [ ] Update registry

  - [x] `agent_restart()` - Restart agent
    - [ ] Call agent_stop()
    - [ ] Call agent_start()

  - [x] `agent_attach()` - Attach to agent session
    - [ ] Read session info from registry
    - [ ] SSH into VM with tmux/screen attach

  - [x] `agent_status()` - Show agent status
    - [ ] Read registry
    - [ ] Check if session exists
    - [ ] Show agent type, runtime, status
    - [ ] If --all: show all agents

  - [x] `agent_logs()` - View agent logs
    - [ ] Determine log location
    - [ ] SSH into VM
    - [ ] tail logs with options (--follow, --tail N)

  - [x] `agent_enable_autostart()` - Enable systemd autostart
    - [ ] Copy systemd service template
    - [ ] Instantiate for workspace
    - [ ] Enable service

  - [x] `agent_disable_autostart()` - Disable autostart
    - [ ] Disable systemd service
    - [ ] Remove service file

  - [x] `agent_sessions()` - List tracked thread sessions in VM
  - [x] `agent_resume()` - Resume a tracked session for a thread
  - [x] Thread-aware session ledger for `kimi-ralph`
    - [x] VM-side ledger at `/root/.config/foundry/sessions.json`
    - [x] Watcher adapters compute thread key and resume existing Kimi sessions
    - [x] Host CLI `foundry agent sessions` and `foundry agent resume`
  - [ ] Verify and enable session resumption for claude/codex/gemini

## Phase 9: Configuration Management

### Config Module
- [x] `lib/config.sh`
  - [x] `config_init()` - Initialize config
    - [ ] Create ~/.config/foundry/
    - [ ] Copy default config
    - [ ] Create ~/.local/share/foundry/ directories

  - [x] `config_get()` - Get config value
    - [ ] Read config file
    - [ ] Return value for key

  - [x] `config_set()` - Set config value
    - [ ] Read config file
    - [ ] Update value
    - [ ] Write config

  - [x] `config_edit()` - Edit config in editor
    - [ ] Open config file in $EDITOR

  - [x] `config_load()` - Load all config
    - [ ] Read system config (/etc/foundry/config.conf)
    - [ ] Read user config (~/.config/foundry/config.conf)
    - [ ] Merge and return

## Phase 10: Main CLI

### CLI Entry Point
- [x] `bin/foundry` - Main CLI script
  - [x] Parse command structure (domain action args)
  - [x] Route to appropriate lib function
  - [x] Handle --help, --version
  - [x] Handle global flags (--verbose, --dry-run)
  - [x] Error handling and user-friendly messages
  - [ ] Exit codes

### CLI Subcommands
- [x] Route `vm` commands to `lib/vm.sh`
- [x] Route `agent` commands to `lib/agent.sh`
- [x] Route `template` commands to `lib/template.sh`
- [x] Route `workspace` commands to `lib/workspace.sh`
- [x] Route `host` commands to `scripts/setup-*`
- [x] Route `config` commands to `lib/config.sh`

### Help System
- [ ] `--help` for each command
- [ ] Examples in help text
- [ ] Man page generation (optional)

## Phase 11: Template Files

### Workspace Templates
- [ ] `templates/workspace/context/company.md.example`
- [ ] `templates/workspace/context/instructions.md.example`
- [ ] `templates/workspace/context/coding-standards.md.example`
- [ ] `templates/workspace/context/architecture.md.example`
- [x] `templates/workspace/memory/decisions.md`
- [x] `templates/workspace/memory/progress.md`
- [x] `templates/workspace/memory/blockers.md`
- [x] `templates/workspace/memory/learnings.md`
- [ ] `templates/workspace/PROMPT.md.example`
- [ ] `templates/workspace/fix_plan.md.example`
- [ ] `templates/workspace/workspace.json.example`
- [x] `templates/workspace/README.md`

### System Templates
- [ ] `templates/systemd/ralph-agent@.service`
- [ ] `templates/firecracker/vm-config.json.template`
- [ ] `templates/network/eth0.network.template`

### Example Configs
- [ ] `docs/examples/single-repo.json`
- [ ] `docs/examples/multi-repo.json`
- [ ] `docs/examples/full-stack.json`
- [x] `config/default.conf`
- [x] `config/packages.txt`

## Phase 12: Testing

### Unit Tests
- [ ] `tests/test-utils.sh` - Test utility functions
- [ ] `tests/test-registry.sh` - Test registry operations
- [ ] `tests/test-network.sh` - Test network functions
- [ ] `tests/test-config.sh` - Test config management

### Integration Tests
- [ ] `tests/test-vm-lifecycle.sh` - Test VM create/start/stop/destroy
- [ ] `tests/test-agent.sh` - Test agent start/stop/logs
- [ ] `tests/test-template.sh` - Test template building
- [ ] `tests/test-workspace.sh` - Test workspace initialization

### E2E Tests
- [ ] `tests/test-full-workflow.sh` - Complete workflow test
- [ ] Test script runner: `tests/run-all.sh`

## Phase 13: Installation & Distribution

### Installation
- [x] `install.sh` - Main installation script
  - [ ] Detect host OS
  - [ ] Check dependencies
  - [ ] Copy bin/foundry to /usr/local/bin/
  - [ ] Create config directories
  - [ ] Copy default configs
  - [ ] Run host setup (optional)
  - [ ] Verify installation

### Distribution
- [ ] Create releases
- [ ] Package for different distros (AUR, deb, rpm)
- [ ] Docker image for development
- [ ] Installation docs

## Phase 14: Documentation

### User Documentation
- [ ] `docs/installation.md` - Installation guide
- [ ] `docs/quickstart.md` - Quick start tutorial
- [ ] `docs/troubleshooting.md` - Common issues
- [ ] `docs/configuration.md` - Configuration guide
- [ ] `docs/workspace-guide.md` - Workspace structure guide
- [ ] `docs/agent-guide.md` - Agent management guide
- [ ] `docs/templates.md` - Template customization

### Developer Documentation
- [ ] `docs/CONTRIBUTING.md` - Contribution guidelines
- [ ] `docs/DEVELOPMENT.md` - Development setup
- [ ] `docs/TESTING.md` - Testing guide
- [ ] Code comments in all modules

## Phase 15: Polish & Refinement

### UX Improvements
- [ ] Progress bars for long operations
- [ ] Colored output (with --no-color flag)
- [ ] Better error messages
- [ ] Interactive wizards for complex commands
- [ ] Shell completions (bash, zsh, fish)

### Performance
- [ ] Optimize template copying (copy-on-write)
- [ ] Parallel VM operations where possible
- [ ] Cache frequently accessed registry data
- [ ] Optimize network setup

### Robustness
- [ ] Comprehensive error handling
- [ ] Rollback on failures
- [ ] Lock files for concurrent access
- [ ] Validation of all inputs
- [ ] Graceful degradation

## Future Enhancements (Post-MVP)

### Additional Features
- [ ] Web UI for monitoring
- [ ] Multi-user support
- [ ] Remote VM hosting (cloud)
- [ ] Agent collaboration (multi-agent)
- [ ] Advanced metrics and monitoring
- [ ] Cost tracking
- [ ] Template marketplace
- [ ] CI/CD integration
- [ ] GitHub Actions workflow
- [ ] Automated backups

### Additional Guest OS
- [ ] Ubuntu base template
- [ ] Fedora base template
- [ ] NixOS base template (advanced)

### Additional Agents
- [ ] Support for Aider
- [ ] Support for Cursor
- [ ] Support for Cody
- [ ] Custom agent adapters

## Priority Matrix

### P0 - Critical (Must have for MVP)
- Host setup scripts
- Base and golden template builders
- VM lifecycle (create, start, stop, destroy, ssh)
- Basic agent management (start, stop, logs)
- Registry management
- Network setup
- Main CLI routing
- Installation script

### P1 - High (Important for usability)
- VM operations (copy, rename, snapshot)
- Agent attach
- Workspace initialization
- Configuration management
- Template files
- Basic documentation
- Testing framework

### P2 - Medium (Nice to have)
- Advanced agent features (autostart)
- Shell completions
- Colored output
- Integration tests
- Troubleshooting docs

### P3 - Low (Future)
- Web UI
- Remote hosting
- Additional guest OS
- Template marketplace

## Implementation Strategy

### Week 1: Foundation
- Phase 1: Documentation ✅
- Phase 2: Host setup scripts
- Phase 3: Template builders

### Week 2: Core Functionality
- Phase 4: VM lifecycle
- Phase 5: Networking
- Phase 6: Registry

### Week 3: Agent Integration
- Phase 7: Workspace management
- Phase 8: Agent management
- Phase 9: Configuration

### Week 4: Polish
- Phase 10: Main CLI
- Phase 11: Template files
- Phase 12: Testing
- Phase 13: Installation

### Week 5: Release
- Phase 14: Documentation
- Phase 15: Polish & refinement
- Release MVP

## Notes

- Use shell scripts (bash) for maximum portability
- All lib modules should be sourceable and testable
- Follow POSIX where possible, use bashisms only when needed
- Error handling: set -euo pipefail in all scripts
- Logging: Use consistent log functions from utils.sh
- Testing: Test each module independently before integration
- Documentation: Keep docs in sync with code
- Git: Commit frequently, meaningful messages

## Agents for Implementation

Delegate to codex and gemini agents:
- **Codex**: Shell scripts, template builders, CLI parsing
- **Gemini**: Documentation, configuration files, testing scripts

Both agents must read:
- docs/VISION.md
- docs/ARCHITECTURE.md
- docs/CLI-REFERENCE.md
- docs/RALPH-INTEGRATION.md
- This TODO.md

---

Last Updated: 2026-02-16
