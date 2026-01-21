# Package Management Design

## Default Package Set

The base VM template includes essential tools for AI agent development:

### Core System
- Ubuntu 22.04 base system
- Linux kernel (from Firecracker)

### Development Essentials
- `build-essential` - Build tools (gcc, make, etc.)
- `git` - Version control
- `openssh-server` - SSH server
- `vim` - Text editor
- `nano` - Simple editor

### Shell & Utilities
- `bash` - Shell (4.0+)
- `tmux` - Terminal multiplexer
- `screen` - Alternative multiplexer
- `jq` - JSON processor
- `curl` - HTTP client
- `wget` - File downloader

### Language Runtimes
- `nodejs` - Node.js + npm
- `python3` - Python 3
- `python3-pip` - Python package manager

### Container & Virtualization
- `docker.io` - Container runtime

### AI Development Tools
*Installed via npm/pip during template customization:*
- Claude Code CLI (`npm install -g @anthropic/claude`)
- Gemini CLI (installation method TBD)
- OpenAI CLI (installation method TBD)

### Agent Framework
*Installed from source:*
- ralph-claude-code (cloned to `/opt/ralph`)

## Custom Package Configuration

Users can add packages via configuration file.

### Config Location

```
~/.config/foundry/packages.txt
```

Or per-template:
```
~/.config/foundry/templates/my-template/packages.txt
```

### packages.txt Format

Simple line-delimited list:
```txt
# Additional packages for my agent VMs
# Comments start with #

# Database tools
postgresql
redis

# Cloud CLIs
aws-cli
kubectl

# Language tools
go
rustup

# My favorite tools
ripgrep
fd
bat
htop
ncdu

# Specific versions (if needed)
# python=3.11
```

### Usage

**Option 1: Build template with custom packages**
```bash
foundry template build golden --packages ~/.config/foundry/packages.txt
```

**Option 2: Install into existing VM**
```bash
foundry vm install my-project --packages custom-packages.txt
```

**Option 3: Global default**
Place `packages.txt` in `~/.config/foundry/` and it's automatically used for all templates.

## Template Build Process

1. Create base image (default packages)
2. Download Ubuntu rootfs from Firecracker S3
3. Read `packages.txt` if exists
4. Install additional packages via `chroot` with `apt-get`
5. Configure networking, SSH, etc.
6. Install AI CLIs (npm/pip)
7. Clone ralph-claude-code
8. Finalize and snapshot

## Package Categories (Reference)

Users can reference these in their packages.txt:

### Web Development
```txt
# Frontend
nodejs-lts-iron
typescript
yarn
pnpm

# Backend
postgresql
redis
nginx
```

### Systems Programming
```txt
rust
cargo
go
cmake
clang
lldb
```

### Data Science
```txt
python-numpy
python-pandas
python-scikit-learn
jupyter-notebook
```

### DevOps
```txt
ansible
terraform
kubectl
helm
docker-compose
```

## Example Configurations

### Full-Stack Web Developer
```txt
# ~/.config/foundry/packages.txt
postgresql
redis
nginx
docker-compose
```

### Rust Systems Programmer
```txt
rustup
cargo
clang
lldb
valgrind
```

### Python Data Scientist
```txt
python-numpy
python-pandas
python-matplotlib
jupyter-notebook
```

### Cloud-Native Developer
```txt
kubectl
helm
aws-cli
terraform
```

## AUR Support (Future)

For packages not in official repos, users can:
1. Install yay/paru in VM manually
2. Snapshot customized template
3. OR: Framework could support AUR via yay

```txt
# packages.txt with AUR support (future)
AUR:visual-studio-code-bin
AUR:google-cloud-sdk
```

## Implementation Strategy

**Phase 1: Basic (MVP)**
- Default package set hardcoded in build script
- Simple packages.txt support (official repos only)

**Phase 2: Advanced**
- Multiple package lists (base + custom + workspace-specific)
- AUR support via yay
- Package validation before build

**Phase 3: Templates**
- Pre-built template variants (web, rust, python, etc.)
- Community-contributed package lists
- Template marketplace concept

## Benefits

1. **Sensible defaults** - Works out of the box
2. **Customizable** - Add tools you always need
3. **Reproducible** - packages.txt in version control
4. **Shareable** - Team can share package lists
5. **Lightweight base** - Only install what you need
6. **Template variants** - Different setups for different projects
