#!/usr/bin/env bash
#
# Agent Foundry - Verb Commands
#
# The project-centric CLI: init, up, down, status, logs, attach, shell, rm,
# doctor, policy, image.
#
# These replaced the old noun domains (vm, agent, workspace, network, template,
# host): everything they did is either folded into these verbs or gone
# entirely, because the sandbox model removed the need for it.
#
# 'up' is idempotent reconciliation: it makes reality match foundry.json.
# That property is what lets restart / sync / register-hooks / mark-all /
# enable-autostart disappear as separate commands.
#

# ============================================================================
# SHARED HELPERS
# ============================================================================

# Resolve project name, volume root and sandbox name in one step.
# Sets: FOUNDRY_PROJECT, FOUNDRY_ROOT, FOUNDRY_BOX
# Usage: _resolve_context "${1:-}" || return 1
_resolve_context() {
    local explicit="${1:-}"

    FOUNDRY_PROJECT="$(project_resolve "$explicit")" || return 1
    FOUNDRY_ROOT="$(project_root "$FOUNDRY_PROJECT")" || return 1
    FOUNDRY_BOX="$(sandbox_name_for "$FOUNDRY_PROJECT")" || return 1

    return 0
}

# Same, but require the project to already exist.
_resolve_existing() {
    _resolve_context "${1:-}" || return 1

    if [[ ! -d "$FOUNDRY_ROOT" ]]; then
        log_error "Project not found: $FOUNDRY_PROJECT"
        log_error "Expected volume root at: $FOUNDRY_ROOT"
        log_error "Create it with: foundry init $FOUNDRY_PROJECT"
        return 1
    fi

    return 0
}

# Resolve the image for a project.
#
# Every agent runs from the single ':base' image, which carries all of the
# CLIs. A project can still pin .image to something else.
_project_image() {
    local name="$1"

    local image
    image="$(project_get "$name" '.image' "")"

    if [[ -z "$image" ]]; then
        image="${FOUNDRY_IMAGE_REPO:-foundry-agent}:base"
    fi

    printf '%s\n' "$image"
}

# Memory limit for a project, in the units sbx expects ("8g", "1024m").
#
# The config carries DEFAULT_MEMORY as a bare number of megabytes, which is
# what Firecracker took; sbx -m needs an explicit unit, so a unitless value is
# read as MiB and suffixed. Empty means "let sbx decide" (50% of host memory).
_project_memory() {
    local name="$1"

    local memory
    memory="$(project_get "$name" '.resources.memory' "${DEFAULT_MEMORY:-}")"

    if [[ -z "$memory" ]]; then
        printf '\n'
        return 0
    fi

    if [[ "$memory" =~ ^[0-9]+$ ]]; then
        memory="${memory}m"
    fi

    printf '%s\n' "$memory"
}

# Apply the network rules this project's remotes need, and record them.
#
# Rules are scoped to the sandbox, and `sbx rm` takes a sandbox's scoped rules
# with it - so a project that is removed and re-created loses them silently.
# Both init and up call this, and both are idempotent.
project_apply_network_rules() {
    local name="$1" box="$2"

    local -a resources=()
    mapfile -t resources < <(project_policy_resources "$name")
    [[ ${#resources[@]} -gt 0 ]] || return 0

    log_info "Allowing ${#resources[@]} project network resource(s)"
    policy_apply_rules "$box" "${resources[@]}" || return 1

    # Record derived rules so every exception is reviewable in the config.
    local json_rules
    json_rules="$(printf '%s\n' "${resources[@]}" | jq -R . | jq -s .)"
    project_set "$name" '.network.allow' "$json_rules" || return 1
}

# Warn when the sandbox is older than the image on disk.
#
# A sandbox keeps the image it was created from: rebuilding a tag changes
# nothing for sandboxes that already exist, and `up` only starts them. That
# has now cost real debugging twice - once for nested Docker, once for a fixed
# webhook receiver - because everything looks correct while old code runs.
_warn_if_image_is_stale() {
    local name="$1" box="$2" root="$3"

    sandbox_is_running "$box" || return 0
    check_command docker || return 0

    local image built running
    image="$(_project_image "$name")"

    built="$(docker run --rm --entrypoint cat "$image" /etc/foundry-image-id 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$built" ]] || return 0

    running="$(sandbox_exec "$box" "$root" cat /etc/foundry-image-id 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$running" ]] || return 0

    [[ "$built" == "$running" ]] && return 0

    log_warn "This sandbox runs an older image than ${image}"
    log_warn "  sandbox: ${running}"
    log_warn "  on disk: ${built}"
    log_warn "  A sandbox keeps the image it was created from, so a rebuild"
    log_warn "  alone changes nothing. Pick it up with:"
    log_warn "    foundry rm ${name} && foundry init ${name}"
    return 0
}

# ============================================================================
# init
# ============================================================================

cmd_init() {
    local name="${1:-}"
    shift || true

    local no_clone=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-clone)
                no_clone=true
                ;;
            *)
                log_error "Unknown option for 'foundry init': $1"
                return 1
                ;;
        esac
        shift
    done

    # A name is required here - there is nothing to infer from yet.
    if [[ -z "$name" ]]; then
        if ! name="$(project_infer_name)" || [[ -z "$name" ]]; then
            log_error "Usage: foundry init <project> [--no-clone]"
            return 1
        fi
    fi

    project_validate_name "$name" || return 1
    sandbox_require || return 1
    sandbox_check_login || return 1

    local root box
    root="$(project_root "$name")"
    box="$(sandbox_name_for "$name")"

    # 1. Volume root (idempotent).
    project_scaffold "$name" || return 1

    # 2. Validate config before anything expensive happens.
    project_validate_config "$name" || return 1

    # 3. Host-wide network baseline. Project rules come after the sandbox
    #    exists: they are scoped to it, and sbx rejects a scoped rule naming a
    #    sandbox it cannot find. Ordering them the other way looked safer and
    #    simply meant the rules were never added, which surfaced later as
    #    "Could not resolve hostname" during the clone.
    policy_baseline || return 1

    # 4. Create the sandbox.
    local image cpus memory shared
    image="$(_project_image "$name")"
    cpus="$(project_get "$name" '.resources.cpus' "${DEFAULT_CPUS:-}")"
    memory="$(_project_memory "$name")"
    shared="$(project_shared_dir)"

    local -a specs=()
    mapfile -t specs < <(project_publish_specs "$name")

    sandbox_create "$box" "$image" "$cpus" "$memory" "$root" "$shared" "${specs[@]}" || return 1
    sandbox_start "$box" || return 1

    # The agent's home is a symlink at the volume root. ssh needs it before the
    # clone: it reads ~/.ssh from the passwd entry, not from HOME.
    sandbox_link_home "$box" "$root" || return 1

    # 5. Network rules for this project's remotes, now that there is a sandbox
    #    to scope them to. Before the clone, which is what needs them.
    #
    #    The resolver check comes first: the baseline ran before any sandbox
    #    existed and may have denied the range the resolver is in, which
    #    disables DNS entirely and cannot be undone by an allow rule.
    policy_unblock_resolvers "$box" || true
    project_apply_network_rules "$name" "$box" || return 1

    # 6. Clone declared repositories inside the sandbox. This is the first real
    #    exercise of the SSH key and the network policy, and it happens before
    #    any agent runs.
    if [[ "$no_clone" == "true" ]]; then
        log_info "Skipping clone (--no-clone)"
    else
        project_fix_ssh_perms "$root"

        local repo_count
        repo_count="$(project_get_array "$name" '.repos[].url' | grep -c . || true)"

        if [[ "$repo_count" -gt 0 ]] && ! project_has_ssh_key "$root"; then
            log_warn "No SSH key found in ${root}/.ssh"
            log_warn "If your remotes use SSH, add a key there first - see the"
            log_warn "commented setup instructions in ${root}/.ssh/config"
        fi

        project_clone_repos "$name" "$box" "$root" || return 1
    fi

    _project_seed_fj_auth "$name" "$root" || return 1

    log_info "Project '${name}' initialized"
    echo ""
    echo "  Volume root : $root"
    echo "  Sandbox     : $box"
    echo "  Config      : ${root}/foundry.json"
    echo ""
    # Only advise what is actually still missing. foundry.json is init's input,
    # not its output, so telling someone who just cloned from it to go and edit
    # it - and to set up the ssh key the clone plainly already used - reads as
    # boilerplate and teaches people to skip the whole block.
    local -a next=()

    if [[ "$(project_get_array "$name" '.repos[].url' | grep -c . || true)" -eq 0 ]]; then
        next+=("  \$EDITOR ${root}/foundry.json     # add repos, then 'up' clones them")
        if ! project_has_ssh_key "$root"; then
            next+=("  ${root}/.ssh/                    # add a key for SSH remotes")
        fi
    fi

    next+=("  foundry up ${name}")

    echo "Next:"
    printf '%s\n' "${next[@]}"

    return 0
}

# ============================================================================
# up
# ============================================================================

cmd_up() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local no_agent=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-agent)
                no_agent=true
                ;;
            *)
                log_error "Unknown option for 'foundry up': $1"
                return 1
                ;;
        esac
        shift
    done

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    project_validate_config "$FOUNDRY_PROJECT" || return 1

    # 1. Box running.
    if ! sandbox_exists "$FOUNDRY_BOX"; then
        log_error "Sandbox does not exist for project '$FOUNDRY_PROJECT'"
        log_error "Run: foundry init $FOUNDRY_PROJECT"
        return 1
    fi

    sandbox_start "$FOUNDRY_BOX" || return 1
    sandbox_link_home "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1

    _warn_if_image_is_stale "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT"

    # 2. Ports. Mappings persist for the sandbox's lifetime, so this
    #    reconciles instead of republishing: a second up would otherwise fail
    #    with 409, and a changed port would leave the old one behind.
    local -a specs=()
    mapfile -t specs < <(project_publish_specs "$FOUNDRY_PROJECT")

    # Reconcile rather than publish: mappings outlive a restart, so a second
    # `up` would otherwise fail with "already published", and a changed port
    # would leave the old one behind.
    sandbox_sync_ports "$FOUNDRY_BOX" "${specs[@]:-}" || return 1

    # 3. Network rules. Re-applied every up: they are scoped to the sandbox and
    #    do not survive its removal, so a re-created box starts with none.
    policy_unblock_resolvers "$FOUNDRY_BOX" || true
    project_apply_network_rules "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" || return 1

    # 5. Repos: clone anything declared but missing.
    project_fix_ssh_perms "$FOUNDRY_ROOT"
    project_clone_repos "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1

    # Repositories that appeared just now need their own trust entry: a goal
    # agent works inside the checkout, and trust is keyed per directory.
    _project_seed_trust "$FOUNDRY_ROOT" || return 1
    _project_seed_fj_auth "$FOUNDRY_PROJECT" "$FOUNDRY_ROOT" || return 1

    # 6. Agent.
    if [[ "$no_agent" == "true" ]]; then
        log_info "Skipping agent start (--no-agent)"
    else
        foundry_agent_start "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1
    fi

    # 7. Watcher. A configured watcher is meant to be listening whenever the
    #    project is up: a forge that gets a connection refused does not retry
    #    later, so a watcher that must be started by hand silently drops work.
    local watcher_kind
    watcher_kind="$(project_get "$FOUNDRY_PROJECT" '.watcher.kind' "")"
    if [[ -n "$watcher_kind" ]] && ! watcher_is_configured "$FOUNDRY_PROJECT"; then
        log_warn "Watcher kind '${watcher_kind}' is not supported; only 'forgejo' is."
    elif watcher_is_configured "$FOUNDRY_PROJECT"; then
        watcher_start "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1
    fi

    log_info "Project '${FOUNDRY_PROJECT}' is up"
    return 0
}

# ============================================================================
# down
# ============================================================================

cmd_down() {
    local name="${1:-}"

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    watcher_stop "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || true
    foundry_agent_stop "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || true
    sandbox_stop "$FOUNDRY_BOX" || return 1

    log_info "Project '${FOUNDRY_PROJECT}' is down"
    return 0
}

# ============================================================================
# status
# ============================================================================

_status_one() {
    local name="$1"

    local root box state agent
    root="$(project_root "$name")"
    box="$(sandbox_name_for "$name")"
    state="$(sandbox_state "$box")"
    agent="$(project_get "$name" '.agent' "${FOUNDRY_DEFAULT_AGENT:-claude}")"

    local agent_state="stopped"
    if [[ "$state" == "running" ]] && foundry_agent_running "$box" "$root" "$agent"; then
        agent_state="running"
    fi

    printf '%-20s %-10s %-18s %-10s %s\n' \
        "$name" "$state" "$agent" "$agent_state" "$root"
}

cmd_status() {
    local name="${1:-}"

    sandbox_require || return 1

    if [[ -z "$name" ]] && ! name="$(project_infer_name)"; then
        name=""
    fi

    if [[ -n "$name" ]]; then
        _resolve_existing "$name" || return 1

        echo "Project : $FOUNDRY_PROJECT"
        echo "Root    : $FOUNDRY_ROOT"
        echo "Sandbox : $FOUNDRY_BOX ($(sandbox_state "$FOUNDRY_BOX"))"
        echo "Agent   : $(project_get "$FOUNDRY_PROJECT" '.agent' "${FOUNDRY_DEFAULT_AGENT:-claude}")"
        echo ""

        echo "Repositories:"
        local repo found=false
        for repo in "$FOUNDRY_ROOT"/repos/*; do
            [[ -d "$repo/.git" ]] || continue
            found=true
            printf '  %-24s %s\n' \
                "$(basename "$repo")" \
                "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        done
        [[ "$found" == "false" ]] && echo "  (none cloned)"
        echo ""

        if sandbox_is_running "$FOUNDRY_BOX"; then
            echo "Published ports:"
            local ports
            ports="$(sandbox_ports "$FOUNDRY_BOX")"
            if [[ -n "$ports" ]]; then
                printf '%s\n' "$ports" | sed 's/^/  /'
            else
                echo "  (none)"
            fi
            echo ""
        fi

        # The watcher is the thing most likely to be quietly not running: it
        # takes no action to break, and the symptom is silence on the forge.
        if watcher_is_configured "$FOUNDRY_PROJECT"; then
            echo "Watcher:"
            local w_state="stopped"
            if sandbox_is_running "$FOUNDRY_BOX" \
                && watcher_is_running "$FOUNDRY_BOX" "$FOUNDRY_ROOT"; then
                w_state="running"
            fi
            printf '  %-12s %s\n' "state" "$w_state"
            printf '  %-12s %s\n' "instance" \
                "$(project_get "$FOUNDRY_PROJECT" '.watcher.instance_url' '?')"
            printf '  %-12s %s\n' "trigger" \
                "$(project_get "$FOUNDRY_PROJECT" '.watcher.trigger_keyword' '?')"
            printf '  %-12s %s\n' "receiver" \
                "port $(project_get "$FOUNDRY_PROJECT" '.watcher.receiver_port' '?')"
            local public
            if public="$(watcher_public_url "$FOUNDRY_PROJECT")"; then
                printf '  %-12s %s\n' "webhook" "$public"
            else
                printf '  %-12s %s\n' "webhook" \
                    "(set .watcher.public_url to register hooks)"
            fi
            echo ""
        fi

        echo "Network rules for this sandbox:"
        policy_list "$FOUNDRY_BOX" 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

        return 0
    fi

    # No project: table of everything.
    printf '%-20s %-10s %-18s %-10s %s\n' "PROJECT" "SANDBOX" "AGENT" "STATE" "ROOT"

    local any=false
    local project
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        any=true
        _status_one "$project"
    done < <(project_list)

    if [[ "$any" == "false" ]]; then
        echo "(no projects - create one with 'foundry init <name>')"
    fi

    return 0
}

# ============================================================================
# shell / attach / logs
# ============================================================================

cmd_shell() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local use_ssh=false
    if [[ "${1:-}" == "--ssh" ]]; then
        use_ssh=true
        shift
    fi

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    # A sandbox stops itself after a short idle period, so refusing here would
    # send the user to `foundry up` - which also clones and starts an agent -
    # when all they asked for is a shell. sbx exec starts a stopped sandbox by
    # itself; do the same explicitly so the ssh path behaves identically.
    if ! sandbox_is_running "$FOUNDRY_BOX"; then
        log_info "Sandbox is stopped; starting it"
        sandbox_start "$FOUNDRY_BOX" || return 1
    fi
    sandbox_link_home "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1

    if [[ "$use_ssh" == "true" ]]; then
        if ! check_command ssh; then
            log_error "ssh is not installed"
            return 1
        fi
        log_debug "Connecting via ssh ${FOUNDRY_BOX}.sbx"
        ssh "${FOUNDRY_BOX}.sbx" "$@"
        return $?
    fi

    if [[ $# -gt 0 ]]; then
        sandbox_exec_tty "$FOUNDRY_BOX" "$FOUNDRY_ROOT" "$@"
    else
        sandbox_exec_tty "$FOUNDRY_BOX" "$FOUNDRY_ROOT" bash
    fi
}

cmd_attach() {
    local name="${1:-}"

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    # Attaching to a stopped box is not an error either: starting it is what
    # the user wants, and the agent-session check below is the real gate.
    if ! sandbox_is_running "$FOUNDRY_BOX"; then
        log_info "Sandbox is stopped; starting it"
        sandbox_start "$FOUNDRY_BOX" || return 1
    fi

    local agent session work_session
    agent="$(project_get "$FOUNDRY_PROJECT" '.agent' "${FOUNDRY_DEFAULT_AGENT:-claude}")"
    session="$(agent_session_name "$agent")"
    work_session="$(agent_watcher_session_name)"

    # A watcher-driven run lives in its own session, so during exactly the
    # work an autonomous project exists to do, the agent session is empty and
    # attaching to it would report "no running agent". Prefer the live run.
    if sandbox_exec "$FOUNDRY_BOX" "$FOUNDRY_ROOT" \
        tmux has-session -t "$work_session" >/dev/null 2>&1; then
        session="$work_session"
        log_info "Attaching to the watcher's run '$session' (detach with Ctrl-b d)"
        sandbox_exec_tty "$FOUNDRY_BOX" "$FOUNDRY_ROOT" tmux attach -t "$session"
        return $?
    fi

    if ! foundry_agent_running "$FOUNDRY_BOX" "$FOUNDRY_ROOT" "$agent"; then
        log_error "No running agent session in $FOUNDRY_BOX"
        log_error "  Looked for '$session' and '$work_session'."
        if watcher_is_configured "$FOUNDRY_PROJECT"; then
            log_error "  A goal agent only runs while it has work: comment on an"
            log_error "  issue to start one, or watch 'foundry logs -f'."
        else
            log_error "  Start it with: foundry up $FOUNDRY_PROJECT"
        fi
        return 1
    fi

    log_info "Attaching to '$session' (detach with Ctrl-b d)"
    sandbox_exec_tty "$FOUNDRY_BOX" "$FOUNDRY_ROOT" tmux attach -t "$session"
}

# Every log a project writes, as "label<TAB>path" lines.
#
# A watcher-driven run spreads itself over three files - the watcher decides,
# the receiver takes the request, the agent does the work - so following one
# of them shows a third of the story. They are listed in the order a request
# passes through them.
_logs_sources() {
    local name="$1" root="$2" which="$3"

    local agent agent_log
    agent="$(project_get "$name" '.agent' "${FOUNDRY_DEFAULT_AGENT:-claude}")"
    agent_log="$(agent_log_file "$agent" "$root" 2>/dev/null || true)"

    local wdir="${root}/.config/forgejo-watcher"

    case "$which" in
        receiver|all)
            printf 'receiver\t%s\n' "${wdir}/receiver.log"
            ;;&
        watcher|all)
            printf 'watcher\t%s\n' "${wdir}/watcher.log"
            # The supervisor's own log: it records the sandbox being restarted
            # and the watcher being restarted, neither of which the watcher
            # can log itself because it is the thing that died.
            printf 'supervisor\t%s\n' "${wdir}/supervisor.log"
            ;;&
        agent|all)
            # The run the watcher starts logs here; a manually started agent
            # logs to its own file. Both are "the agent" to the reader.
            printf 'agent\t%s\n' "${root}/logs/agent-watcher.log"
            [[ -n "$agent_log" ]] && printf 'agent\t%s\n' "$agent_log"
            ;;
    esac
}

cmd_logs() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local follow=false
    local which="all"
    local lines=200

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow)   follow=true ;;
            --watcher)     which="watcher" ;;
            --receiver)    which="receiver" ;;
            --agent)       which="agent" ;;
            -n)
                shift
                if [[ ! "${1:-}" =~ ^[0-9]+$ ]]; then
                    log_error "-n needs a number of lines"
                    return 1
                fi
                lines="$1"
                ;;
            *)
                log_error "Unknown option for 'foundry logs': $1"
                echo "Options: -f, -n <lines>, --agent, --watcher, --receiver" >&2
                return 1
                ;;
        esac
        shift
    done

    _resolve_existing "$name" || return 1

    # Logs are files in the volume root: read them on the host, no exec needed.
    local -a labels=() paths=()
    local label path
    while IFS=$'\t' read -r label path; do
        [[ -n "$path" ]] || continue
        labels+=("$label")
        paths+=("$path")
    done < <(_logs_sources "$FOUNDRY_PROJECT" "$FOUNDRY_ROOT" "$which")

    # Only complain when nothing exists at all: a project without a watcher
    # legitimately has no watcher log, and a fresh one has no agent log yet.
    local -a present=() present_labels=()
    local i
    for i in "${!paths[@]}"; do
        if [[ -f "${paths[$i]}" ]]; then
            present+=("${paths[$i]}")
            present_labels+=("${labels[$i]}")
        fi
    done

    if [[ ${#present[@]} -eq 0 ]]; then
        if [[ "$follow" != "true" ]]; then
            log_error "No logs yet for '${FOUNDRY_PROJECT}'"
            log_error "  Looked for: $(printf '%s ' "${paths[@]}")"
            return 1
        fi
        log_warn "No logs yet; waiting for them to appear"
    fi

    if [[ "$follow" != "true" ]]; then
        for i in "${!present[@]}"; do
            # One source needs no prefix; several do, or the reader cannot
            # tell the watcher's decision from the agent's output.
            if [[ ${#present[@]} -eq 1 ]]; then
                tail -n "$lines" "${present[$i]}"
            else
                printf '\n=== %s (%s)\n' "${present_labels[$i]}" "${present[$i]}"
                tail -n "$lines" "${present[$i]}"
            fi
        done
        return 0
    fi

    # Follow every source at once, each line tagged with where it came from.
    # tail -F rather than -f: the watcher and agent logs are created when work
    # first arrives, and a follow started before that should pick them up
    # rather than sit silent forever.
    local -a pids=()
    # Ctrl-C must take the tails with it; without this they survive the
    # command and keep writing into the next prompt.
    # shellcheck disable=SC2154  # _p is the trap's own loop variable
    trap 'for _p in "${pids[@]}"; do kill "$_p" 2>/dev/null; done' INT TERM EXIT

    for i in "${!paths[@]}"; do
        tail -n "$lines" -F "${paths[$i]}" 2>/dev/null \
            | sed -u "s/^/[${labels[$i]}] /" &
        pids+=("$!")
    done

    wait
}

# ============================================================================
# rm
# ============================================================================

cmd_rm() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local purge=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-volume)
                purge=true
                ;;
            --keep-volume)
                purge=false
                ;;
            -y|--yes)
                AUTO_ACCEPT=true
                ;;
            *)
                log_error "Unknown option for 'foundry rm': $1"
                return 1
                ;;
        esac
        shift
    done

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    if ! confirm "Remove sandbox '${FOUNDRY_BOX}'?"; then
        log_info "Aborted"
        return 0
    fi

    # Before the sandbox goes: unregistering needs it, so advice printed
    # afterwards could never be acted on.
    if watcher_is_configured "$FOUNDRY_PROJECT"; then
        log_warn "Webhooks on the forge still point at this project's receiver."
        log_warn "  They keep failing until 'foundry init ${FOUNDRY_PROJECT}' brings it back."
        log_warn "  To remove them instead, do it now, while the sandbox exists:"
        log_warn "    foundry watcher unregister ${FOUNDRY_PROJECT}"
    fi

    watcher_stop "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || true
    foundry_agent_stop "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || true
    sandbox_rm "$FOUNDRY_BOX" || return 1


    if [[ "$purge" == "true" ]]; then
        log_warn "This deletes the volume root and everything in it:"
        log_warn "  $FOUNDRY_ROOT"
        log_warn "  (repositories, agent memory, keys, logs)"
        if confirm "Delete the volume root as well?"; then
            rm -rf "$FOUNDRY_ROOT"
            log_info "Volume root deleted"
        else
            log_info "Volume root kept: $FOUNDRY_ROOT"
        fi
    else
        log_info "Volume root kept: $FOUNDRY_ROOT"
    fi

    return 0
}

# ============================================================================
# doctor
# ============================================================================

cmd_doctor() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local fix=false
    if [[ "${1:-}" == "--fix" ]]; then
        fix=true
    fi

    local failures=0

    echo "Host:"

    if check_command "$SBX_BIN"; then
        echo "  ok     sbx installed ($("$SBX_BIN" version 2>/dev/null | head -1 || echo 'version unknown'))"
    else
        echo "  FAIL   sbx not installed"
        echo "         curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh"
        echo "         sudo apt-get install docker-sbx"
        failures=$((failures + 1))
    fi

    if check_command jq; then
        echo "  ok     jq installed"
    else
        echo "  FAIL   jq not installed"
        failures=$((failures + 1))
    fi

    # A denied resolver disables DNS for every sandbox on the host, and no
    # allow rule can undo it, so doctor names it rather than leaving the
    # operator to read "Temporary failure in name resolution" as broken DNS.
    if [[ -n "$name" ]] && project_exists "$name" && check_command "$SBX_BIN"; then
        local dns_box
        dns_box="$(sandbox_name_for "$name")"
        if sandbox_is_running "$dns_box"; then
            local -a dns_res=()
            mapfile -t dns_res < <(policy_resolver_addresses "$dns_box" 2>/dev/null || true)
            local blocked=0 dns_range
            for dns_range in "${FOUNDRY_PRIVATE_RANGES[@]}"; do
                [[ ${#dns_res[@]} -gt 0 ]] || break
                if policy_has_deny "$dns_range" && \
                   policy_range_covers_resolver "$dns_range" "${dns_res[@]}"; then
                    echo "  FAIL   ${dns_range} is denied but holds the sandbox resolver"
                    echo "         DNS cannot work; run 'foundry up' to repair"
                    blocked=$((blocked + 1))
                fi
            done
            [[ "$blocked" -eq 0 ]] && echo "  ok     sandbox resolver reachable"
        fi
    fi

    # Advisory: sandboxes are containers on Linux and do not need KVM. Only
    # a VM-backed Docker setup does, so this is never counted as a failure.
    if check_kvm; then
        echo "  ok     KVM available"
    else
        echo "  info   KVM unavailable (not required for container sandboxes)"
    fi

    if [[ $failures -eq 0 ]]; then
        if sandbox_check_login 2>/dev/null; then
            echo "  ok     signed in to Docker"
        else
            echo "  FAIL   not signed in - run: sbx login"
            failures=$((failures + 1))
        fi
    fi

    echo ""
    echo "Network policy:"

    # Which preset is installed. sbx asks this once, interactively, and there
    # is no flag to script it - so a host can sit on a default-deny preset
    # without anyone having chosen it, and every unlisted host then fails to
    # resolve rather than reporting a denial.
    if check_command "$SBX_BIN"; then
        if ! policy_is_initialized; then
            echo "  FAIL   no network policy chosen yet"
            echo "         Run by hand:  sbx policy reset   (choose 1. Open)"
            failures=$((failures + 1))
        elif policy_has_allow "**"; then
            echo "  ok     preset allows full egress (Open)"
        else
            echo "  warn   preset is default-deny (Balanced or Locked Down)"
            echo "         A host must be allowed before it will even resolve."
            echo "         Project remotes are handled; allow anything else with:"
            echo "           foundry policy allow <host>"
            echo "         For Foundry's documented posture: sbx policy reset -> 1. Open"
        fi
    fi

    # Resolve a project if one is available; its rules join the matrix.
    if [[ -z "$name" ]]; then
        name="$(project_infer_name 2>/dev/null || true)"
    fi

    local box=""
    local -a resources=()
    if [[ -n "$name" ]] && project_exists "$name"; then
        box="$(sandbox_name_for "$name")"
        mapfile -t resources < <(project_policy_resources "$name")
    fi

    # Without a usable sbx there is nothing to ask; reporting every target as
    # denied would be a lie, so say the checks were skipped instead.
    if ! check_command "$SBX_BIN"; then
        echo "  skipped - sbx is not installed, policy cannot be evaluated"
    else
        if [[ "$fix" == "true" ]]; then
            policy_baseline || failures=$((failures + 1))
        fi

        policy_check_matrix "$box" "${resources[@]}" || failures=$((failures + 1))
    fi

    if [[ -n "$name" ]] && project_exists "$name"; then
        local root
        root="$(project_root "$name")"

        echo ""
        echo "Project '${name}':"

        if project_check_filesystem "$name" 2>/dev/null; then
            echo "  ok     volume root on local storage"
        else
            echo "  FAIL   volume root on network storage"
            failures=$((failures + 1))
        fi

        if project_has_ssh_key "$root"; then
            echo "  ok     SSH key present in .ssh"
        else
            echo "  warn   no SSH key in ${root}/.ssh (needed for SSH git remotes)"
        fi

        if [[ "$fix" == "true" ]]; then
            project_fix_ssh_perms "$root"
            echo "  ok     .ssh permissions normalized"
        fi

        # Watcher ports must actually be published, or the forge cannot reach us.
        local port
        port="$(project_receiver_port "$name")"
        if [[ -n "$port" && "$port" != "0" ]] && check_command "$SBX_BIN"; then
            if sandbox_is_running "$box" && sandbox_port_published "$box" "$port"; then
                echo "  ok     receiver port $port published (forge -> sandbox)"
            else
                echo "  FAIL   receiver port $port is NOT published"
                echo "         publish it with: foundry up $name"
                failures=$((failures + 1))
            fi
        fi

        # The rest of the watcher's wiring. Each of these has failed in a way
        # that produced silence on the forge rather than an error anywhere.
        if watcher_is_configured "$name"; then
            local agent_type
            agent_type="$(project_get "$name" '.agent' "")"
            if [[ "$agent_type" == *-goal ]]; then
                echo "  ok     agent '${agent_type}' can be driven by a watcher"
            else
                echo "  FAIL   agent '${agent_type}' cannot be driven by a watcher"
                echo "         use claude-goal, codex-goal or agy-goal"
                failures=$((failures + 1))
            fi

            local tok
            tok="$(watcher_token_path "$name" "$root" 2>/dev/null || true)"
            if [[ -n "$tok" && -s "$tok" ]]; then
                echo "  ok     Forgejo token present"
            else
                echo "  FAIL   Forgejo token missing or empty (${tok:-.watcher.token_file unset})"
                failures=$((failures + 1))
            fi

            if watcher_public_url "$name" >/dev/null 2>&1; then
                echo "  ok     webhook URL: $(watcher_public_url "$name")"
            else
                echo "  warn   no .watcher.public_url; hooks must be added by hand"
            fi

            if sandbox_is_running "$box"; then
                if sandbox_exec "$box" "$root" test -x "$WATCHER_SCRIPT" 2>/dev/null; then
                    echo "  ok     watcher present in the image"
                    if sandbox_exec "$box" "$root" \
                        sh -c 'command -v socat >/dev/null' 2>/dev/null; then
                        echo "  ok     socat present (the receiver needs it)"
                    else
                        echo "  FAIL   socat missing from the image; the receiver cannot listen"
                        echo "         rebuild it with: foundry image build"
                        failures=$((failures + 1))
                    fi
                else
                    echo "  FAIL   the image predates watcher support"
                    echo "         foundry image build, then foundry rm $name && foundry init $name"
                    failures=$((failures + 1))
                fi

                if watcher_is_running "$box" "$root"; then
                    echo "  ok     watcher running"
                else
                    echo "  warn   watcher not running (foundry up $name)"
                fi
            fi
        fi
    fi

    echo ""
    if [[ $failures -gt 0 ]]; then
        log_error "doctor found $failures problem(s)"
        return 1
    fi

    log_info "All checks passed"
    return 0
}

# ============================================================================
# policy / image
# ============================================================================

cmd_policy() {
    local action="${1:-ls}"
    shift || true

    sandbox_require || return 1

    case "$action" in
        baseline)
            if [[ -n "${1:-}" && "${1:-}" != "--reset" ]]; then
                log_error "Usage: foundry policy baseline [--reset]"
                return 1
            fi
            policy_baseline "${1:-}"
            ;;
        allow)
            [[ -z "${1:-}" ]] && { log_error "Usage: foundry policy allow <resource> [project]"; return 1; }
            local sandbox=""
            [[ -n "${2:-}" ]] && sandbox="$(sandbox_name_for "$2")"
            policy_allow "$1" "$sandbox"
            ;;
        deny)
            [[ -z "${1:-}" ]] && { log_error "Usage: foundry policy deny <resource> [project]"; return 1; }
            local sandbox=""
            [[ -n "${2:-}" ]] && sandbox="$(sandbox_name_for "$2")"
            policy_deny "$1" "$sandbox"
            ;;
        check)
            [[ -z "${1:-}" ]] && { log_error "Usage: foundry policy check <target> [project]"; return 1; }
            local sandbox=""
            [[ -n "${2:-}" ]] && sandbox="$(sandbox_name_for "$2")"
            if policy_check "$1" "$sandbox"; then
                echo "Allowed: $1"
            else
                echo "Denied: $1"
                return 1
            fi
            ;;
        ls|list)
            local sandbox=""
            [[ -n "${1:-}" ]] && sandbox="$(sandbox_name_for "$1")"
            policy_list "$sandbox"
            ;;
        *)
            log_error "Unknown policy action: $action"
            echo "Actions: baseline [--reset], allow, deny, check, ls" >&2
            return 1
            ;;
    esac
}

cmd_image() {
    local action="${1:-}"
    shift || true

    local dockerfile="${FOUNDRY_BASE}/docker/foundry-agent.Dockerfile"
    local repo="${FOUNDRY_IMAGE_REPO:-foundry-agent}"

    case "$action" in
        build)
            # One image serves every agent: each CLI's goal loop is a feature
            # of the CLI, not a separate runner to bake in. The tag is fixed
            # so nothing has to guess which image a project wants.
            local tag="base"

            if [[ $# -gt 0 ]]; then
                log_error "'foundry image build' takes no arguments"
                echo "There is one image now: ${repo}:base, which carries every agent CLI." >&2
                return 1
            fi

            if [[ ! -f "$dockerfile" ]]; then
                log_error "Dockerfile not found: $dockerfile"
                return 1
            fi
            if ! check_command docker; then
                log_error "docker is required to build the agent image"
                return 1
            fi

            # The image's agent user must have the host user's UID/GID: the
            # volume root is a bind mount, so any mismatch shows up as files
            # the host user cannot edit (or the agent cannot write).
            local uid gid
            uid="$(resolve_host_uid)"
            gid="$(resolve_host_gid)"

            # Stamped into the image so 'up' can tell a sandbox running an
            # older build from one running this one.
            local image_id
            image_id="$(date -u +%Y%m%d%H%M%S)-$(git -C "$FOUNDRY_BASE" rev-parse --short HEAD 2>/dev/null || echo local)"

            log_info "Building ${repo}:${tag} (agent uid ${uid}:${gid})"
            docker build \
                -f "$dockerfile" \
                --build-arg "FOUNDRY_IMAGE_ID=${image_id}" \
                --build-arg "AGENT_UID=${uid}" \
                --build-arg "AGENT_GID=${gid}" \
                -t "${repo}:${tag}" \
                "${FOUNDRY_BASE}" || return 1

            # The sandbox runtime has its own image store. Without this step
            # `sbx create -t` tries to *pull* the tag and fails with 403,
            # because a locally built image is invisible to it.
            sandbox_load_image "${repo}:${tag}" || return 1
            ;;
        push)
            local variant="${1:-base}"
            if ! check_command docker; then
                log_error "docker is required to push the agent image"
                return 1
            fi
            docker push "${repo}:${variant}"
            ;;
        *)
            log_error "Unknown image action: ${action:-<none>}"
            echo "Actions: build, push [tag]" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# watcher
# ============================================================================

cmd_watcher() {
    local action="${1:-status}"
    shift || true
    local name="${1:-}"

    _resolve_existing "$name" || return 1
    sandbox_require || return 1

    case "$action" in
        start)
            sandbox_is_running "$FOUNDRY_BOX" || {
                log_error "Sandbox is not running: foundry up ${FOUNDRY_PROJECT}"
                return 1
            }
            watcher_start "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT"
            ;;
        stop)
            watcher_stop "$FOUNDRY_BOX" "$FOUNDRY_ROOT"
            log_info "Watcher stopped"
            ;;
        restart)
            watcher_stop "$FOUNDRY_BOX" "$FOUNDRY_ROOT"
            watcher_start "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT"
            ;;
        status)
            if ! watcher_is_configured "$FOUNDRY_PROJECT"; then
                echo "No Forgejo watcher configured for '${FOUNDRY_PROJECT}'"
                return 0
            fi
            if ! sandbox_is_running "$FOUNDRY_BOX"; then
                echo "Watcher: stopped (sandbox is not running)"
                return 0
            fi
            sandbox_exec "$FOUNDRY_BOX" "$FOUNDRY_ROOT" \
                "$WATCHER_SCRIPT" status
            ;;
        logs)
            local log="${FOUNDRY_ROOT}/.config/forgejo-watcher/watcher.log"
            [[ -f "$log" ]] || { log_error "No watcher log yet: $log"; return 1; }
            tail -n "${FOUNDRY_LOG_LINES:-50}" -f "$log"
            ;;
        secret)
            # The value the forge's webhook "Secret" field must contain. It is
            # not the API token, and pasting the token there produces a
            # perfectly well-formed signature that can never match.
            local secret_file
            secret_file="$(watcher_config_dir "$FOUNDRY_ROOT")/webhook-secret"
            if [[ ! -s "$secret_file" ]]; then
                log_error "No webhook secret yet: run 'foundry up ${FOUNDRY_PROJECT}'"
                return 1
            fi
            cat "$secret_file"
            ;;
        register|unregister|list)
            sandbox_is_running "$FOUNDRY_BOX" || {
                log_error "Sandbox is not running: foundry up ${FOUNDRY_PROJECT}"
                return 1
            }
            watcher_hooks "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" "$action"
            ;;
        *)
            log_error "Unknown watcher action: $action"
            echo "Actions: start, stop, restart, status, logs, secret," >&2
            echo "         register, unregister, list (Forgejo webhooks)" >&2
            return 1
            ;;
    esac
}
