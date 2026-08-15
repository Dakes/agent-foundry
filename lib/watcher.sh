#!/usr/bin/env bash
#
# Forgejo watcher lifecycle.
#
# The watcher itself lives in the image at /opt/foundry/forgejo and runs
# inside the sandbox. This module is the host half: it translates foundry.json
# into the shell config the watcher reads, places the secrets beside it, and
# starts, stops and inspects the two tmux sessions the watcher uses.
#
# Split of responsibility: everything derivable from foundry.json is written
# here on every 'up', so the config file is a generated artifact and editing it
# by hand is pointless. The watcher's own state - processed events, retries,
# the queue - is never touched from the host.

# Directory the watcher reads, expressed as a host path into the volume root.
# Inside the sandbox the same directory is ~/.config/forgejo-watcher, because
# the agent's home is that volume root.
watcher_config_dir() {
    printf '%s\n' "${1}/.config/forgejo-watcher"
}

# True when the project declares a Forgejo watcher.
# Usage: watcher_is_configured <project>
watcher_is_configured() {
    [[ "$(project_get "$1" '.watcher.kind' "")" == "forgejo" ]]
}

# Resolve the project's Forgejo token file to a host path.
_watcher_token_path() {
    local name="$1" root="$2"
    local token_file
    token_file="$(project_get "$name" '.watcher.token_file' "")"
    [[ -n "$token_file" ]] || return 1
    [[ "$token_file" == /* ]] && { printf '%s\n' "$token_file"; return 0; }
    printf '%s\n' "${root}/${token_file}"
}

# The URL Forgejo should POST to.
#
# The receiver listens inside the sandbox on the receiver port, which Foundry
# publishes to the host; the forge then has to reach that host. Only the
# operator knows under which name, so .watcher.public_url is required for
# webhook registration - it is the one part of the wiring that cannot be
# derived.
watcher_public_url() {
    local name="$1"
    local url port
    url="$(project_get "$name" '.watcher.public_url' "")"
    [[ -n "$url" ]] || return 1

    url="${url%/}"

    # No scheme means http: the receiver speaks plain HTTP, and anything in
    # front of it doing TLS is named explicitly.
    [[ "$url" == *://* ]] || url="http://${url}"

    # The path is fixed: the receiver answers POST /webhook and nothing else,
    # so a URL without it registers a hook that Forgejo will report as
    # delivered and the receiver will refuse.
    local rest="${url#*://}"
    if [[ "$rest" != */* ]]; then
        # A bare host gets the receiver port appended, so the common case
        # needs no port arithmetic from the user.
        if [[ "$rest" != *:[0-9]* ]]; then
            port="$(project_get "$name" '.watcher.receiver_port' "")"
            [[ -n "$port" ]] && url="${url}:${port}"
        fi
        url="${url}/webhook"
    fi

    printf '%s\n' "$url"
}

# Generate config.conf and the secrets beside it.
#
# The webhook secret is generated once and kept: it is shared with Forgejo at
# registration time, and regenerating it on every 'up' would silently
# invalidate every hook already registered.
#
# Usage: watcher_write_config <project> <root>
watcher_write_config() {
    local name="$1" root="$2"

    watcher_is_configured "$name" || return 0

    local dir
    dir="$(watcher_config_dir "$root")"
    mkdir -p "${dir}/queue"
    chmod 700 "$dir"

    local instance port keyword agent
    instance="$(project_get "$name" '.watcher.instance_url' "")"
    port="$(project_get "$name" '.watcher.receiver_port' "")"
    keyword="$(project_get "$name" '.watcher.trigger_keyword' "")"
    agent="$(project_get "$name" '.agent' "")"

    if [[ -z "$instance" || -z "$port" || -z "$keyword" ]]; then
        log_error "Watcher config incomplete in ${root}/foundry.json"
        log_error "  .watcher needs instance_url, receiver_port and trigger_keyword"
        return 1
    fi

    # The watcher drives an autonomous loop; an interactive agent has no
    # adapter and would fail inside the sandbox, where nobody can answer it.
    case "$agent" in
        *-goal) ;;
        "")
            log_error "No .agent set in ${root}/foundry.json"
            return 1
            ;;
        *)
            log_error "Agent '${agent}' cannot be driven by a watcher"
            log_error "  Use a goal agent: claude-goal, codex-goal or agy-goal."
            return 1
            ;;
    esac

    local token_path
    if ! token_path="$(_watcher_token_path "$name" "$root")" || [[ ! -r "$token_path" ]]; then
        log_error "Forgejo token not readable: ${token_path:-<.watcher.token_file unset>}"
        return 1
    fi

    # Secrets stay in their own files: config.conf is regenerated on every up
    # and is the thing most likely to be pasted into a bug report.
    local secret_file="${dir}/webhook-secret"
    if [[ ! -s "$secret_file" ]]; then
        ( umask 077; openssl rand -hex 32 > "$secret_file" ) 2>/dev/null \
            || ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$secret_file" )
        log_debug "Generated webhook secret"
    fi
    chmod 600 "$secret_file"

    local -a repos=()
    mapfile -t repos < <(project_get_array "$name" '.watcher.watched_repos[]')
    if [[ ${#repos[@]} -eq 0 ]]; then
        log_error "No .watcher.watched_repos in ${root}/foundry.json"
        return 1
    fi

    local display
    display="$(agent_display_name "$agent" 2>/dev/null || printf '%s' "$agent")"

    local box_dir="\$HOME/.config/forgejo-watcher"
    local tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    {
        echo "# Generated by foundry from foundry.json - edits are overwritten."
        echo "# Regenerate with: foundry up ${name}"
        echo ""
        echo "WATCHER_ENABLED=true"
        echo "FORGEJO_INSTANCE_URL=\"${instance%/}\""
        echo "WATCHED_REPOS=\"$(printf '%s' "${repos[*]}")\""
        echo "TRIGGER_KEYWORD=\"${keyword}\""
        echo "RECEIVER_PORT=\"${port}\""
        echo "RECEIVER_INTERFACE=\"0.0.0.0\""
        echo "AGENT_TYPE=\"${agent}\""
        echo "AGENT_DISPLAY_NAME=\"${display}\""
        echo "FORGEJO_TOKEN_FILE=\"${box_dir}/token\""
        echo "WEBHOOK_SECRET_FILE=\"${box_dir}/webhook-secret\""
        local public
        if public="$(watcher_public_url "$name")"; then
            echo "WEBHOOK_URL=\"${public}\""
        fi
        local timeout
        timeout="$(project_get "$name" '.watcher.agent_timeout' "")"
        [[ -n "$timeout" ]] && echo "AGENT_TIMEOUT=\"${timeout}\""
        local dry
        dry="$(project_get "$name" '.watcher.dry_run' "")"
        [[ "$dry" == "true" ]] && echo "DRY_RUN=true"
    } > "$tmp"
    mv "$tmp" "${dir}/config.conf"
    chmod 600 "${dir}/config.conf"

    # The watcher reads the token from its own directory: the sandbox path of
    # secrets/ is a project convention, and copying keeps the watcher's inputs
    # in one place.
    if ! cmp -s "$token_path" "${dir}/token"; then
        ( umask 077; cat "$token_path" > "${dir}/token" )
    fi
    chmod 600 "${dir}/token"

    log_debug "Wrote watcher config: ${dir}/config.conf"
    return 0
}

# Is the watcher loop running inside the sandbox?
watcher_is_running() {
    local box="$1" root="$2"
    sandbox_exec "$box" "$root" tmux has-session -t forgejo-watcher >/dev/null 2>&1
}

# Start the watcher (which starts the receiver itself).
# Usage: watcher_start <project> <box> <root>
watcher_start() {
    local name="$1" box="$2" root="$3"

    watcher_is_configured "$name" || return 0
    watcher_write_config "$name" "$root" || return 1

    if watcher_is_running "$box" "$root"; then
        log_info "Watcher already running"
        return 0
    fi

    # tmux keeps the loop alive after this exec returns; the watcher starts the
    # receiver in a second session once its config validates.
    if ! sandbox_exec "$box" "$root" \
        tmux new-session -d -s forgejo-watcher \
        "/opt/foundry/forgejo/forgejo_watcher.sh start"; then
        log_error "Could not start the watcher session"
        return 1
    fi

    # The watcher exits on a bad config, and tmux reports that as a session
    # that is simply gone - so a moment's wait is the difference between
    # "started" and a silent failure the user finds hours later.
    sleep 2
    if ! watcher_is_running "$box" "$root"; then
        log_error "Watcher exited immediately after starting"
        log_error "  Check ${root}/.config/forgejo-watcher/watcher.log"
        return 1
    fi

    local port
    port="$(project_get "$name" '.watcher.receiver_port' "")"
    log_info "Watcher running; receiver listening on port ${port}"
    return 0
}

# Stop the watcher and its receiver.
watcher_stop() {
    local box="$1" root="$2"

    sandbox_is_running "$box" || return 0
    sandbox_exec "$box" "$root" \
        /opt/foundry/forgejo/forgejo_watcher.sh stop >/dev/null 2>&1 || true
    return 0
}

# Register or unregister the webhooks on the Forgejo side.
# Usage: watcher_hooks <project> <box> <root> <register|unregister|list>
watcher_hooks() {
    local name="$1" box="$2" root="$3" action="$4"

    if ! watcher_is_configured "$name"; then
        log_error "No Forgejo watcher configured for '${name}'"
        return 1
    fi

    if [[ "$action" == "register" ]] && ! watcher_public_url "$name" >/dev/null; then
        log_error "Set .watcher.public_url in ${root}/foundry.json first"
        log_error "  It is the address Forgejo POSTs to - the host running"
        log_error "  Foundry, as the forge sees it. On the same machine that is"
        log_error "  \"http://localhost\"; the receiver port is appended for you."
        return 1
    fi

    watcher_write_config "$name" "$root" || return 1

    sandbox_exec "$box" "$root" \
        /opt/foundry/forgejo/forgejo_hook_manager.sh "$action"
}
