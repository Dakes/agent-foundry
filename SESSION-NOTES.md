# Session Notes - 2026-01-28

## Problem
Ralph binary not being found when running `foundry agent start reowls ralph`, even though:
- Ralph IS installed in `/root/.local/bin/ralph` in the VM
- PATH IS configured correctly in `.bashrc` and `.profile`
- Running `foundry vm ssh reowls ralph` works fine

## Root Causes Discovered

### 1. SSH Non-Interactive Shell PATH Issue
- Non-interactive SSH sessions don't source `.bashrc` or `.profile`
- Fixed by making `_ssh_cmd` and `vm_ssh` use `bash -l -c` (login shell) to load profile files

### 2. SSH Key Permissions Issue (CRITICAL - NOT FULLY FIXED)
- When VM is created with doas/sudo, SSH keys are created as root-owned
- Regular user cannot access `/home/dakes/.local/share/foundry/vms/reowls/ssh/id_ed25519`
- This causes SSH commands from `_ssh_cmd` to fail silently with exit code 255
- **Temporary fix**: User manually chowned the keys
- **Permanent fix needed**: Make vm_create set proper ownership on SSH keys

### 3. Still Failing
Even after SSH key permissions fix, `foundry agent start reowls ralph` still reports "Ralph binary not found"
- Direct SSH test with same command succeeds (exit code 0)
- BUT: running via `doas foundry agent start` still fails
- Possible issue: `_ssh_cmd` may not be returning the correct exit code, or there's quoting issues

## Changes Made

### 1. Added neovim to golden template
**File**: `scripts/build-golden.sh:342`
```bash
# File Utilities
bat tree vim neovim nano tmux screen
```

### 2. Added system-wide PATH configuration
**File**: `scripts/build-golden.sh:389-400`
```bash
mkdir -p "$mount_dir/etc/profile.d"
cat > "$mount_dir/etc/profile.d/local-bin-path.sh" <<'EOF'
# Add ~/.local/bin to PATH for all sessions
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
EOF
```

### 3. Fixed vm_ssh to use login shell
**File**: `lib/vm.sh:748-751`
```bash
# Run command in login shell to source profile files
local quoted_cmd
printf -v quoted_cmd '%q ' "${cmd[@]}"
ssh -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
```

### 4. Fixed _ssh_cmd to use login shell
**File**: `lib/agent.sh:94-111`
```bash
# Run command in login shell
local quoted_cmd
printf -v quoted_cmd '%q ' "$@"
ssh -i "$ssh_key" $FOUNDRY_SSH_OPTS "${FOUNDRY_SSH_USER}@${vm_ip}" "bash -l -c ${quoted_cmd}"
```

### 5. Added -y flag to vm_create
**File**: `lib/vm.sh:232-288`
```bash
# Usage: vm_create <name> [-y|--yes] [--ssh-key <path>] [template]
# Added auto_yes flag to skip confirmation when overwriting VMs
```

**File**: `bin/foundry:354-408`
```bash
# Added -y flag handling in vm_create_cmd wrapper
```

## Current State

### Working:
- ✅ Ralph installed in VM at `/root/.local/bin/ralph`
- ✅ PATH configured in shell profiles
- ✅ `/etc/profile.d/local-bin-path.sh` adds `~/.local/bin` to PATH
- ✅ `foundry vm ssh reowls ralph` works
- ✅ Direct SSH test: `ssh ... "bash -l -c 'command -v ralph'"` succeeds (exit code 0)
- ✅ `foundry vm create -y` flag works to skip confirmation
- ✅ neovim added to golden template

### Still Broken:
- ❌ `foundry agent start reowls ralph` fails with "Ralph binary not found"
- ❌ SSH keys created as root, not accessible by regular user

## Debug Output Added (TEMPORARY)
**File**: `lib/agent.sh:98-111`
Added debug echo statements to trace _ssh_cmd execution. These should be removed once issue is resolved.

## Latest Status (End of Session)

### What We Fixed:
1. **Improved error messages in _start_ralph** - Now distinguishes between:
   - SSH connectivity failure (shows actual SSH error)
   - Ralph binary not found (shows command output)
   - Workspace directory missing

2. **Simplified _ssh_cmd** - Changed from `printf -v quoted_cmd '%q '` approach to simple `bash -l -c "$*"`

### Current Issue:
**Agent start still hangs** at "Checking for ralph binary in VM..." The command execution itself freezes.

Debug output shows:
```
[DEBUG] SSH connectivity confirmed: SSH OK
[DEBUG] Checking for ralph binary in VM...
<hangs here>
```

The line that hangs:
```bash
ralph_check_output=$(_ssh_cmd "$vm_name" "command -v ralph" 2>&1)
```

### Why This is Confusing:
- `doas foundry vm ssh reowls "command -v ralph"` works perfectly (returns /root/.local/bin/ralph)
- Both vm_ssh and _ssh_cmd now use `bash -l -c "$*"`
- SSH connectivity test in _start_ralph succeeds
- But the ralph check immediately after hangs

## TODOs for Next Session

### CRITICAL - Fix the Hang:
1. **Compare vm_ssh and _ssh_cmd execution paths**
   - vm_ssh goes through bin/foundry → cmd_vm → vm_ssh
   - _ssh_cmd is called from agent.sh → _start_ralph → _ssh_cmd
   - Are there environment differences?

2. **Add strace/debugging** - Run with `set -x` to see exact SSH command being executed
   ```bash
   # In lib/agent.sh _ssh_cmd, temporarily add:
   set -x
   ssh -i "$ssh_key" ... bash -l -c "$*"
   set +x
   ```

3. **Test if it's a stdin/stdout issue** - The hang might be SSH waiting for input
   - Try adding `</dev/null` to ssh command
   - Try running in non-interactive mode explicitly

4. **Check if registry access is the issue** - The debug shows registry_get being called multiple times
   - Maybe file locking?
   - Try caching vm_ip and ssh_key at the start of _start_ralph

### Important (SSH Permissions):
1. **Fix SSH key ownership in vm_create** - Make keys readable by the actual user, not just root
   - Get actual user with `resolve_host_home()` or `$SUDO_USER`/`$DOAS_USER`
   - Use `chown` after creating SSH keys
   - Set permissions: private key 600, public key 644, directory 700
   - **File to modify**: `lib/vm.sh:_generate_vm_ssh_key()` around line 103-159

### Nice to Have:
1. Remove debug statements from `lib/agent.sh` once issue is resolved
2. Update documentation about `-y` flag
3. Test neovim in rebuilt golden template

## Testing Commands

```bash
# Rebuild golden template
doas foundry template build golden

# Create VM with -y flag
doas foundry vm create reowls -y --project reowls

# Start VM
doas foundry vm start reowls

# Test ralph directly
doas foundry vm ssh reowls ralph --version

# Test agent start
doas foundry agent start reowls ralph

# Manual SSH test (bypass foundry)
ssh_key="$(jq -r '.vms.reowls.ssh_key' ~/.config/foundry/vms.json)"
vm_ip="$(jq -r '.vms.reowls.ip' ~/.config/foundry/vms.json)"
ssh -i "$ssh_key" -o StrictHostKeyChecking=no "root@${vm_ip}" "bash -l -c 'command -v ralph'"
```

## Key Files Modified
- `scripts/build-golden.sh` - Added neovim, system-wide PATH config
- `lib/vm.sh` - Added -y flag, fixed vm_ssh to use login shell
- `lib/agent.sh` - Fixed _ssh_cmd to use login shell, added debug output
- `bin/foundry` - Added -y flag parsing in vm_create_cmd

## Installation
After any changes, reinstall with:
```bash
./install.sh --prefix ~/.local --no-setup -y
```

## Notes
- `foundry` binary is a self-extracting bundle, not a script
- Changes to lib/ files require rebuilding with install.sh
- Use `--verbose` flag for debug output: `doas foundry --verbose agent start reowls ralph`
