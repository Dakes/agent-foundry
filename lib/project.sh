#!/usr/bin/env bash
#
# Agent Foundry - Projects & Volume Roots
#
# A project is a directory on the host (its "volume root") that is mounted into
# a sandbox at the same absolute path, with HOME pointed at it. It holds the
# repos, the agent's config and memory, prompts, logs, and secrets.
#
# Because the volume root is a real host directory that persists independently
# of the sandbox, most of the old configuration surface is unnecessary: the
# filesystem carries the information. foundry.json exists only for what cannot
# be derived (agent variant, resources, watcher port) and every field is
# optional.
#
# Requires: jq, git
#

# ============================================================================
# PATHS
# ============================================================================

# Base directory holding all project volume roots.
# Usage: dir="$(project_volume_dir)"
project_volume_dir() {
    local host_home
    host_home="$(resolve_host_home)"

    printf '%s\n' "${FOUNDRY_VOLUME_DIR:-${host_home}/.local/share/foundry/volumes}"
}

# Shared, read-only context mounted into every sandbox.
# Usage: dir="$(project_shared_dir)"
project_shared_dir() {
    local host_home
    host_home="$(resolve_host_home)"

    printf '%s\n' "${FOUNDRY_SHARED_DIR:-${host_home}/.local/share/foundry/shared}"
}

# Volume root for one project.
# Usage: root="$(project_root "pocetude")"
project_root() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "project_root: project name required"
        return 1
    fi

    printf '%s/%s\n' "$(project_volume_dir)" "$name"
}

# Path to a project's config file.
# Usage: cfg="$(project_config_path "pocetude")"
project_config_path() {
    local name="$1"
    local root

    root="$(project_root "$name")" || return 1
    printf '%s/foundry.json\n' "$root"
}

# ============================================================================
# RESOLUTION
# ============================================================================

# Validate a project name (used as a directory and sandbox name component).
# Usage: project_validate_name "my-project" || exit 1
project_validate_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Project name required"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_error "Invalid project name: $name"
        log_error "Use letters, numbers, dots, hyphens and underscores; must start alphanumeric."
        return 1
    fi

    return 0
}

# Infer the project from the current working directory.
# Prints the project name, or nothing when the cwd is not inside a volume root.
# Usage: name="$(project_infer_name)"
project_infer_name() {
    local volume_dir
    volume_dir="$(project_volume_dir)"

    local cwd
    cwd="$(pwd -P 2>/dev/null || pwd)"

    # Inside a volume root: <volume_dir>/<project>[/...]
    if [[ "$cwd" == "$volume_dir"/* ]]; then
        local rest="${cwd#"$volume_dir"/}"
        printf '%s\n' "${rest%%/*}"
        return 0
    fi

    # A foundry.json in the cwd (or an ancestor) also identifies a project.
    local dir="$cwd"
    while [[ "$dir" != "/" && -n "$dir" ]]; do
        if [[ -f "$dir/foundry.json" ]]; then
            local name
            name="$(jq -r '.name // empty' "$dir/foundry.json" 2>/dev/null)"
            if [[ -n "$name" ]]; then
                printf '%s\n' "$name"
                return 0
            fi
        fi
        dir="$(dirname "$dir")"
    done

    return 1
}

# Resolve the project for a command: explicit argument, else inferred from cwd.
# Usage: project="$(project_resolve "${1:-}")" || exit 1
project_resolve() {
    local explicit="${1:-}"

    if [[ -n "$explicit" ]]; then
        project_validate_name "$explicit" || return 1
        printf '%s\n' "$explicit"
        return 0
    fi

    local inferred
    if inferred="$(project_infer_name)" && [[ -n "$inferred" ]]; then
        log_debug "Inferred project from working directory: $inferred"
        printf '%s\n' "$inferred"
        return 0
    fi

    log_error "No project given and none could be inferred from the current directory"
    log_error "Pass a name, or run from inside $(project_volume_dir)/<project>"
    return 1
}

# Does the project's volume root exist?
# Usage: project_exists "pocetude" && ...
project_exists() {
    local name="$1"
    local root

    root="$(project_root "$name")" || return 1
    [[ -d "$root" ]]
}

# List all projects, one per line.
# Usage: project_list
project_list() {
    local volume_dir
    volume_dir="$(project_volume_dir)"

    [[ -d "$volume_dir" ]] || return 0

    local entry
    for entry in "$volume_dir"/*; do
        [[ -d "$entry" ]] || continue
        basename "$entry"
    done
}

# ============================================================================
# CONFIG ACCESS
# ============================================================================

# Read a value from foundry.json with a fallback.
# Usage: agent="$(project_get "pocetude" '.agent' "ralph")"
project_get() {
    local name="$1"
    local query="$2"
    local fallback="${3:-}"

    local cfg
    cfg="$(project_config_path "$name")" || return 1

    if [[ ! -f "$cfg" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi

    local value
    value="$(jq -r "${query} // empty" "$cfg" 2>/dev/null)"

    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s\n' "$fallback"
    else
        printf '%s\n' "$value"
    fi

    return 0
}

# Read an array from foundry.json, one element per line.
# Usage: mapfile -t repos < <(project_get_array "pocetude" '.repos[].url')
project_get_array() {
    local name="$1"
    local query="$2"

    local cfg
    cfg="$(project_config_path "$name")" || return 1

    [[ -f "$cfg" ]] || return 0

    jq -r "${query} // empty" "$cfg" 2>/dev/null || true
}

# Write a value into foundry.json (creating the file if needed).
# Usage: project_set "pocetude" '.watcher.port' '9101'
project_set() {
    local name="$1"
    local query="$2"
    local value="$3"

    local cfg
    cfg="$(project_config_path "$name")" || return 1

    if [[ ! -f "$cfg" ]]; then
        printf '{\n  "name": "%s"\n}\n' "$name" > "$cfg"
    fi

    local tmp
    tmp="$(mktemp)"

    if ! jq --argjson v "$value" "${query} = \$v" "$cfg" > "$tmp" 2>/dev/null; then
        # Not valid JSON - treat as a string.
        if ! jq --arg v "$value" "${query} = \$v" "$cfg" > "$tmp"; then
            log_error "Failed to update project config: $cfg"
            rm -f "$tmp"
            return 1
        fi
    fi

    mv "$tmp" "$cfg"
    return 0
}

# Validate the project config early, before anything is created (AGENTS.md:
# a command that will obviously fail should fail immediately).
# Usage: project_validate_config "pocetude" || exit 1
project_validate_config() {
    local name="$1"

    local cfg
    cfg="$(project_config_path "$name")" || return 1

    # No config at all is valid - every field has a default.
    [[ -f "$cfg" ]] || return 0

    if ! jq empty "$cfg" 2>/dev/null; then
        log_error "Project config is not valid JSON: $cfg"
        return 1
    fi

    # Referenced token files must exist and be non-empty.
    local root
    root="$(project_root "$name")"

    local token_file
    token_file="$(project_get "$name" '.watcher.token_file' "")"
    if [[ -n "$token_file" ]]; then
        local resolved="$token_file"
        [[ "$resolved" != /* ]] && resolved="${root}/${token_file}"

        if [[ ! -f "$resolved" ]]; then
            log_error "Watcher token file not found: $resolved"
            log_error "Referenced by .watcher.token_file in $cfg"
            return 1
        fi
        if [[ ! -s "$resolved" ]]; then
            log_error "Watcher token file is empty: $resolved"
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# SCAFFOLDING
# ============================================================================

# Seed a .ssh/config with commented examples.
#
# Foundry does not manage SSH keys. Agents authenticate to git with a key the
# user drops in here by hand - typically a dedicated deploy key or a separate
# agent account, which is exactly what host SSH agent forwarding cannot
# provide. The file is seeded with commented entries so the shape is obvious.
_project_seed_ssh_config() {
    local ssh_dir="$1"
    local config="${ssh_dir}/config"

    [[ -f "$config" ]] && return 0

    cat > "$config" <<'EOF'
# Agent Foundry - SSH configuration for this project's agent
#
# The first connection to a forge has no known_hosts entry, and a headless git
# cannot answer the "continue connecting?" prompt - it just fails. accept-new
# records an unknown host on first contact and still refuses a *changed* key,
# which is the protection that matters once the entry exists.
StrictHostKeyChecking accept-new
UserKnownHostsFile ~/.ssh/known_hosts

#
# This directory is the agent's ~/.ssh inside the sandbox. Keys placed here
# are used by git for clones, fetches and pushes.
#
# SETUP (manual, once per project):
#   1. Generate a key for this project's agent identity:
#        ssh-keygen -t ed25519 -f <this-dir>/id_agent -C "foundry-agent"
#   2. Add the PUBLIC key (id_agent.pub) to the git account or repository
#      you want the agent to use - a deploy key, or a dedicated agent account.
#   3. Uncomment and edit one of the blocks below.
#   4. Run 'foundry up'. The first clone happens inside the sandbox, so a
#      wrong key or an unreachable host fails there, before any agent starts.
#
# Note: the sandbox reaches git over the network only where policy allows it.
# Foundry derives those rules from your repo URLs; git over SSH needs port 22
# on the forge host, which 'foundry up' allows automatically.

# --- GitHub -----------------------------------------------------------------
# Host github.com
#     User git
#     IdentityFile ~/.ssh/id_agent
#     IdentitiesOnly yes

# --- Self-hosted Forgejo / Gitea --------------------------------------------
# Host forge.example.com
#     User git
#     Port 22
#     IdentityFile ~/.ssh/id_agent
#     IdentitiesOnly yes

# --- Same host, separate agent account --------------------------------------
# Host github-agent
#     HostName github.com
#     User git
#     IdentityFile ~/.ssh/id_agent
#     IdentitiesOnly yes
# Then use: git@github-agent:org/repo.git
EOF

    chmod 600 "$config"
    return 0
}

# Seed a minimal foundry.json. Every field is optional; this is a starting
# point, not a required schema.
_project_seed_config() {
    local name="$1"
    local cfg="$2"

    [[ -f "$cfg" ]] && return 0

    local agent="${FOUNDRY_DEFAULT_AGENT:-claude}"

    cat > "$cfg" <<EOF
{
  "name": "${name}",
  "agent": "${agent}",
  "autostart": false,
  "repos": [],
  "network": {
    "allow": [],
    "deny": []
  }
}
EOF

    return 0
}

# Point every agent CLI's native memory file at the project's AGENT.md.
#
# Each CLI loads a user-level instructions file from HOME, which inside the
# sandbox is the volume root. Symlinking them all at one file means there is a
# single place to write standing instructions - the ones that apply across
# every repository in this project and that a per-repo AGENTS.md cannot carry -
# and each agent picks it up natively, with no prompt plumbing from us.
_project_link_agent_md() {
    local root="$1"
    local target

    for target in ".claude/CLAUDE.md" ".gemini/GEMINI.md" ".codex/AGENTS.md"; do
        mkdir -p "${root}/$(dirname "$target")"
        # Leave a real file alone: it is the user's, and clobbering notes with
        # a symlink would lose them silently.
        if [[ -e "${root}/${target}" && ! -L "${root}/${target}" ]]; then
            log_debug "Not linking ${target}: a real file is already there"
            continue
        fi
        ln -sfn "../AGENT.md" "${root}/${target}"
    done
}

# Pre-accept the workspace trust prompt for the agents that gate on it.
#
# Claude refuses to run /goal in an untrusted workspace, and the dialog cannot
# be answered headlessly - a fresh sandbox has never seen it. Codex refuses a
# directory that is not a trusted git repo, which the start script handles with
# --skip-git-repo-check.
_project_seed_trust() {
    local root="$1"
    local cfg="${root}/.claude.json"
    local dir tmp

    # Trust is keyed per directory, and the agent works in the repository, not
    # in the volume root - the launcher changes into it before starting. So
    # every repository needs its own entry, or the run stops at the dialog it
    # cannot answer. Repos appear after the first clone, so this re-runs on
    # every `up` and adds whatever is there now.
    local -a paths=("$root")
    for dir in "$root"/repos/*/; do
        [[ -d "$dir" ]] || continue
        paths+=("${dir%/}")
    done

    if [[ ! -f "$cfg" ]]; then
        printf '{"projects":{}}\n' > "$cfg"
        chmod 600 "$cfg"
    fi

    for dir in "${paths[@]}"; do
        # Never overwrite an existing entry: the user may have revoked trust
        # deliberately, and this runs on every up.
        if jq -e --arg d "$dir" '.projects[$d] != null' "$cfg" >/dev/null 2>&1; then
            continue
        fi

        tmp="$(mktemp)"
        if ! jq --arg d "$dir" '.projects[$d] = {
                hasTrustDialogAccepted: true,
                hasCompletedProjectOnboarding: true
            }' "$cfg" > "$tmp"; then
            log_error "Failed to seed workspace trust for: $dir"
            rm -f "$tmp"
            return 1
        fi
        mv "$tmp" "$cfg"
    done

    chmod 600 "$cfg"
}

# Create (or complete) a project's volume root.
# Idempotent: safe to re-run on an existing project.
# Usage: project_scaffold "pocetude"
project_scaffold() {
    local name="$1"

    project_validate_name "$name" || return 1

    local root
    root="$(project_root "$name")" || return 1

    log_info "Scaffolding volume root: $root"

    local dir
    for dir in \
        "$root" \
        "$root/repos" \
        "$root/logs" \
        "$root/secrets" \
        "$root/.ralph" \
        "$root/.claude" \
        "$root/.codex" \
        "$root/.gemini" \
        "$root/.config" \
        "$root/.config/gh"
    do
        mkdir -p "$dir" || {
            log_error "Failed to create directory: $dir"
            return 1
        }
    done

    # SSH material is user-managed; permissions must be right or ssh refuses it.
    mkdir -p "$root/.ssh"
    chmod 700 "$root/.ssh"
    _project_seed_ssh_config "$root/.ssh"

    # Secrets directory should not be world-readable.
    chmod 700 "$root/secrets"

    _project_seed_config "$name" "$root/foundry.json"

    if [[ ! -f "$root/AGENT.md" ]]; then
        cat > "$root/AGENT.md" <<EOF
# ${name}

Context for the agent working in this project.

- Repositories live in \`repos/\`.
- Agent memory and plans live in \`.ralph/\`.
- This whole directory is the agent's home inside the sandbox, and it is a
  real directory on the host: everything the agent writes here persists.
EOF
    fi

    # After AGENT.md exists, so the links are never left dangling.
    _project_link_agent_md "$root"
    _project_seed_trust "$root" || return 1

    # The volume root must be on local storage. sbx reaches workspaces through
    # a filesystem passthrough, so network-backed storage makes every read
    # cross the network.
    project_check_filesystem "$name" || return 1

    return 0
}

# Reject volume roots on network-attached or cloud-synced storage.
# Usage: project_check_filesystem "pocetude" || return 1
project_check_filesystem() {
    local name="$1"

    local root
    root="$(project_root "$name")" || return 1

    local fstype=""
    if command -v stat >/dev/null 2>&1; then
        fstype="$(stat -f -c '%T' "$root" 2>/dev/null || true)"
    fi

    case "$fstype" in
        nfs*|smb*|cifs*|fuseblk|fuse.sshfs|fuse.rclone)
            log_error "Volume root is on network-attached storage ($fstype): $root"
            log_error "Sandboxes access workspaces through a filesystem passthrough;"
            log_error "every read and write would cross the network. Use local storage."
            return 1
            ;;
    esac

    return 0
}

# ============================================================================
# REPOSITORIES
# ============================================================================

# Print every git remote URL the project should have access to: the URLs
# declared in foundry.json plus the remotes of anything already cloned.
# Usage: mapfile -t urls < <(project_remote_urls "pocetude")
project_remote_urls() {
    local name="$1"

    project_get_array "$name" '.repos[].url'

    local root
    root="$(project_root "$name")" || return 0

    [[ -d "$root/repos" ]] || return 0

    local repo
    for repo in "$root/repos"/*; do
        [[ -d "$repo/.git" ]] || continue
        git -C "$repo" remote -v 2>/dev/null \
            | awk '{print $2}' \
            | sort -u || true
    done
}

# Network policy resources derived from the project's git remotes.
# Usage: mapfile -t resources < <(project_policy_resources "pocetude")
project_policy_resources() {
    local name="$1"

    {
        local url
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            policy_resource_for_remote "$url"
        done < <(project_remote_urls "$name")

        # Explicit extras from config.
        project_get_array "$name" '.network.allow[]'
    } | sort -u
}

# Clone any declared repository that is not present yet.
#
# Cloning happens INSIDE the sandbox, deliberately: it exercises the SSH key,
# the ssh config, and the network policy on the same path the agent will use.
# A bad key or a blocked forge fails here, before any agent starts.
#
# Usage: project_clone_repos "pocetude" "$box" "$root"
project_clone_repos() {
    local name="$1"
    local box="$2"
    local root="$3"

    local count=0
    local index=0

    local url
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue

        local branch dir
        branch="$(project_get "$name" ".repos[${index}].branch" "")"
        dir="$(project_get "$name" ".repos[${index}].dir" "")"
        index=$((index + 1))

        if [[ -z "$dir" ]]; then
            dir="$(basename "$url")"
            dir="${dir%.git}"
        fi

        if [[ -d "${root}/repos/${dir}/.git" ]]; then
            log_debug "Repository already cloned: $dir"
            continue
        fi

        log_info "Cloning ${url} -> repos/${dir} (inside the sandbox)"

        local -a clone_cmd=(git clone)
        if [[ -n "$branch" ]]; then
            clone_cmd+=(--branch "$branch")
        fi
        clone_cmd+=("$url" "repos/${dir}")

        if ! sandbox_exec "$box" "$root" \
            env GIT_TERMINAL_PROMPT=0 "${clone_cmd[@]}"; then
            log_error "Clone failed inside the sandbox: $url"
            log_error "Read the git error above first - it names the cause:"
            log_error "  'Could not resolve hostname'  -> network policy, not DNS."
            log_error "     The sandbox resolves only hosts it is allowed to reach."
            log_error "     Fix: foundry policy allow <host> && foundry policy allow <host>:<port>"
            log_error "  'Host key verification failed' -> no known_hosts entry."
            log_error "     Fix: foundry up re-adds the accept-new setting to .ssh/config"
            log_error "  'Permission denied (publickey)' -> the key is wrong or missing."
            log_error "     Check ${root}/.ssh and that the public key is on the forge."
            log_error "  'Repository not found' / 'couldn't find remote ref' -> wrong URL or branch."
            return 1
        fi

        count=$((count + 1))
    done < <(project_get_array "$name" '.repos[].url')

    if [[ $count -gt 0 ]]; then
        log_info "Cloned ${count} repository/repositories"
    fi

    return 0
}

# Fix permissions on SSH material before it is used inside the sandbox.
# ssh refuses to use keys that are group- or world-readable.
# Usage: project_fix_ssh_perms "$root"
project_fix_ssh_perms() {
    local root="$1"
    local ssh_dir="${root}/.ssh"

    [[ -d "$ssh_dir" ]] || return 0

    chmod 700 "$ssh_dir" 2>/dev/null || true

    # Projects scaffolded before this setting existed have a config that
    # cannot complete a first connection: headless git has no way to accept an
    # unknown host key, so the clone fails with "Host key verification failed".
    local cfg="${ssh_dir}/config"
    if [[ -f "$cfg" ]] && ! grep -qi '^[[:space:]]*StrictHostKeyChecking' "$cfg"; then
        log_info "Adding host-key policy to ${cfg}"
        local tmp
        tmp="$(mktemp)"
        {
            printf '# Added by Agent Foundry: a headless git cannot answer the\n'
            printf '# "continue connecting?" prompt, so an unknown host is accepted on\n'
            printf '# first contact. A *changed* key is still refused.\n'
            printf 'StrictHostKeyChecking accept-new\n'
            printf 'UserKnownHostsFile ~/.ssh/known_hosts\n\n'
            cat "$cfg"
        } > "$tmp" && mv "$tmp" "$cfg"
        chmod 600 "$cfg"
    fi

    local file
    for file in "$ssh_dir"/*; do
        [[ -f "$file" ]] || continue
        case "$file" in
            *.pub|*/known_hosts)
                chmod 644 "$file" 2>/dev/null || true
                ;;
            *)
                chmod 600 "$file" 2>/dev/null || true
                ;;
        esac
    done

    return 0
}

# Does the project have any usable SSH key material?
# Usage: project_has_ssh_key "$root" || log_warn "..."
project_has_ssh_key() {
    local root="$1"
    local ssh_dir="${root}/.ssh"

    [[ -d "$ssh_dir" ]] || return 1

    local file
    for file in "$ssh_dir"/*; do
        [[ -f "$file" ]] || continue
        case "$file" in
            */config|*.pub|*/known_hosts)
                continue
                ;;
        esac
        return 0
    done

    return 1
}

# ============================================================================
# PORTS
# ============================================================================

# Publish specs for a project, derived from its watcher config.
# Watcher receivers must be reachable from the forge, so they bind 0.0.0.0
# rather than the loopback default.
# Usage: mapfile -t specs < <(project_publish_specs "pocetude")
project_publish_specs() {
    local name="$1"

    local port
    port="$(project_get "$name" '.watcher.port' "")"

    if [[ -n "$port" && "$port" != "0" ]]; then
        printf '0.0.0.0:%s:%s\n' "$port" "$port"
    fi

    # Additional user-declared ports, passed through verbatim.
    project_get_array "$name" '.ports[]'
}
