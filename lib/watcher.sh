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

# Where the watcher lives inside the sandbox.
WATCHER_DIR="${WATCHER_DIR:-/opt/foundry/forgejo}"
WATCHER_SCRIPT="${WATCHER_DIR}/forgejo_watcher.sh"
WATCHER_HOOK_MANAGER="${WATCHER_DIR}/forgejo_hook_manager.sh"

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
#
# Public: doctor reports on it too, and duplicating the resolution there would
# let the two drift.
watcher_token_path() {
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
    if ! token_path="$(watcher_token_path "$name" "$root")" || [[ ! -r "$token_path" ]]; then
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
        # Which account we are. The watcher must ignore events it authored -
        # its own replies contain the trigger keyword - and it refuses to run
        # without this, so resolve it here where a failure is visible.
        local bot
        bot="$(project_get "$name" '.watcher.user' "")"
        if [[ -z "$bot" ]]; then
            bot="$(curl -fsS --max-time 10 \
                -H "Authorization: token $(cat "$token_path")" \
                "${instance%/}/api/v1/user" 2>/dev/null | jq -r '.login // empty')"
        fi
        [[ -n "$bot" ]] && echo "WATCHER_BOT_USER=\"${bot}\""
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
        # Opt in to acting on a backlog. Off by default: a watcher that comes
        # up to a queue cannot tell old work from new, and doing all of it at
        # once is never what was wanted.
        local backlog
        backlog="$(project_get "$name" '.watcher.process_backlog' "")"
        [[ "$backlog" == "true" ]] && echo "WATCHER_PROCESS_BACKLOG=true"
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

# Host-side supervisor: the process that keeps the watcher alive.
#
# sbx stops a sandbox about a minute after the last exec returns, and what
# runs *inside* does not count as activity - a detached tmux session holds
# nothing open. A watcher waiting for webhooks is idle by definition, so
# starting it and letting go meant the sandbox stopped underneath it and the
# forge got "connection refused" from a project that looked up.
#
# A foreground exec does hold the sandbox open, so the watcher runs as one,
# supervised from the host: the loop also restarts the watcher if it exits and
# restarts the sandbox if something stopped it.
_watcher_supervisor_pid_file() {
    printf '%s/supervisor.pid\n' "$(watcher_config_dir "$1")"
}

_watcher_supervisor_log() {
    printf '%s/supervisor.log\n' "$(watcher_config_dir "$1")"
}

# Write the supervisor script, with everything it needs baked in: it runs
# detached from any shell and cannot source Foundry's libraries.
_watcher_write_supervisor() {
    local box="$1" root="$2"
    local dir script
    dir="$(watcher_config_dir "$root")"
    script="${dir}/supervisor.sh"

    cat > "$script" <<SUPERVISOR
#!/usr/bin/env bash
# Generated by foundry - do not edit; 'foundry up' overwrites it.
#
# Holds the sandbox open by keeping one exec in the foreground, and restarts
# the watcher if it exits. Both matter: sbx stops an idle sandbox, and a
# watcher that dies takes the receiver with it.
set -u

box="${box}"
log="${dir}/supervisor.log"
sbx_bin="${SBX_BIN}"
user="$(sandbox_user)"
home="$(sandbox_home)"

log_line() { printf '[%s] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" >> "\$log"; }

# Write our own pid: whether setsid forks depends on whether the caller was
# a process-group leader, so the pid the caller recorded is not reliable.
printf '%s\n' "\$\$" > "${dir}/supervisor.pid"
trap 'rm -f "${dir}/supervisor.pid"' EXIT

log_line "supervisor started (pid \$\$)"

# A watcher that cannot start must not be restarted forever: back off, and
# give up rather than hiding a broken config behind an endless loop.
failures=0
while true; do
    "\$sbx_bin" start "\$box" >/dev/null 2>&1

    started=\$(date +%s)
    "\$sbx_bin" exec -u "\$user" -e "HOME=\${home}" -w "\$home" "\$box" \\
        /opt/foundry/forgejo/forgejo_watcher.sh start >> "\$log" 2>&1
    rc=\$?
    ran=\$(( \$(date +%s) - started ))

    if [[ "\$ran" -ge 60 ]]; then
        failures=0
    else
        failures=\$(( failures + 1 ))
    fi

    log_line "watcher exited (rc=\${rc}) after \${ran}s; failures=\${failures}"

    if [[ "\$failures" -ge 5 ]]; then
        log_line "giving up after 5 quick failures - fix the config and run 'foundry up'"
        exit 1
    fi

    sleep 10
done
SUPERVISOR

    chmod 700 "$script"
    printf '%s\n' "$script"
}

# Is the watcher running? The supervisor is the thing that must be alive: if
# it is gone, the sandbox will idle out even when the watcher is up right now.
#
# "A live pid" is not enough. The pid file sits in the volume root and outlives
# a hard kill, a reboot and the sandbox itself, so the recorded number is
# eventually reused by an unrelated process - and then `up` believes the
# watcher is running, skips starting it, and reports success while nothing
# listens. The process must actually be our supervisor.
watcher_is_running() {
    local box="$1" root="$2"

    local pid_file pid script
    pid_file="$(_watcher_supervisor_pid_file "$root")"
    [[ -f "$pid_file" ]] || return 1

    pid="$(cat "$pid_file" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    script="$(watcher_config_dir "$root")/supervisor.sh"
    if [[ -r "/proc/${pid}/cmdline" ]]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -qF "$script"
        return $?
    fi

    # No /proc to check against: a live pid is the best signal available.
    return 0
}

# Is the watcher actually serving? The supervisor can be alive while the thing
# the forge talks to is not - the sandbox was stopped, or the watcher is
# looping on a bad config - and from outside those look identical to healthy.
watcher_is_serving() {
    local box="$1" root="$2"

    watcher_is_running "$box" "$root" || return 1
    sandbox_is_running "$box" || return 1
    sandbox_exec "$box" "$root" \
        tmux has-session -t forgejo-receiver >/dev/null 2>&1
}

# Start the watcher (which starts the receiver itself).
# Usage: watcher_start <project> <box> <root>
watcher_start() {
    local name="$1" box="$2" root="$3"

    watcher_is_configured "$name" || return 0
    watcher_write_config "$name" "$root" || return 1

    # Reconcile on what is actually serving, not on what has a process. 'up'
    # exists to make reality match the config, and a supervisor that is alive
    # while nothing listens is the one state that most looks like success.
    if watcher_is_serving "$box" "$root"; then
        log_info "Watcher already running"
        return 0
    fi

    if watcher_is_running "$box" "$root"; then
        log_warn "Watcher supervisor is up but the receiver is not; restarting"
        watcher_stop "$box" "$root"
    elif [[ -f "$(_watcher_supervisor_pid_file "$root")" ]]; then
        # A pid file with no supervisor behind it: left by a hard kill or a
        # reboot. Clear it, or the next check inherits the same confusion.
        log_debug "Clearing stale supervisor pid file"
        rm -f "$(_watcher_supervisor_pid_file "$root")"
    fi

    # The watcher ships in the image. An image built before it did leaves tmux
    # starting a script that is not there: the session dies instantly and the
    # log the failure would be in is never created, so the only symptom is a
    # dead session and a path that does not exist.
    if ! sandbox_exec "$box" "$root" \
        test -x "$WATCHER_SCRIPT" 2>/dev/null; then
        log_error "This sandbox's image has no watcher (${WATCHER_SCRIPT} is missing)"
        log_error "  It predates watcher support. Rebuild and re-create:"
        log_error "    foundry image build"
        log_error "    foundry rm ${name} && foundry init ${name}"
        return 1
    fi

    # tmux keeps the loop alive after this exec returns; the watcher starts the
    # receiver in a second session once its config validates.
    local script pid_file
    script="$(_watcher_write_supervisor "$box" "$root")"
    pid_file="$(_watcher_supervisor_pid_file "$root")"

    # setsid detaches it from this shell and from the terminal, so it survives
    # the command finishing, the terminal closing and the user logging out.
    rm -f "$pid_file"
    setsid nohup "$script" >/dev/null 2>&1 &
    # The supervisor writes the authoritative pid itself; this is the fallback
    # for the moment before it gets there.
    printf '%s\n' "$!" > "$pid_file"

    # The watcher exits on a bad config, and the supervisor would restart it
    # in a loop - so a moment's wait is the difference between "started" and a
    # silent failure the user finds hours later.
    # The receiver is the proof: the watcher only starts it after the config
    # validates, and it is the part the forge actually talks to. Poll rather
    # than sleeping a fixed time - starting the sandbox, loading the config
    # and binding the port take longer on a loaded host than on this one.
    local waited=0 ready=false
    while [[ "$waited" -lt 25 ]]; do
        if watcher_is_serving "$box" "$root"; then
            ready=true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [[ "$ready" != "true" ]]; then
        watcher_stop "$box" "$root"
        log_error "Watcher did not come up within ${waited}s"

        # Show the logs rather than re-running the watcher to see what it
        # says: when it works, running it in the foreground blocks for as
        # long as the loop lives, and it prints nothing anyway - everything
        # goes to these files. The supervisor's log is first because it
        # records failures that happen before the watcher can log at all.
        local dir log line
        dir="$(watcher_config_dir "$root")"
        for log in "${dir}/supervisor.log" "${dir}/watcher.log"; do
            [[ -f "$log" ]] || continue
            log_error "  --- $(basename "$log"):"
            while IFS= read -r line; do
                log_error "      ${line}"
            done < <(tail -n 5 "$log")
        done

        if [[ ! -f "${dir}/supervisor.log" ]]; then
            log_error "  The supervisor wrote no log at all: it could not start."
            log_error "  Check that ${dir}/supervisor.sh exists and is executable."
        fi
        return 1
    fi

    local port
    port="$(project_get "$name" '.watcher.receiver_port' "")"
    log_info "Watcher running; receiver listening on port ${port}"
    return 0
}

# Stop the watcher: the host supervisor first, then what runs inside.
#
# Order matters. Killing the inside first only makes the supervisor restart
# it, because restarting is exactly its job.
watcher_stop() {
    local box="$1" root="$2"

    local pid_file pid
    pid_file="$(_watcher_supervisor_pid_file "$root")"
    if [[ -f "$pid_file" ]]; then
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            # The supervisor is its own session leader, so the negative pid
            # takes the exec it is holding with it.
            kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            # Still there after TERM: take the group down hard, falling back
            # to the bare pid the same way the TERM above does.
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "-${pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    fi

    sandbox_is_running "$box" || return 0
    sandbox_exec "$box" "$root" \
        "$WATCHER_SCRIPT" stop >/dev/null 2>&1 || true
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
        "$WATCHER_HOOK_MANAGER" "$action"
}
