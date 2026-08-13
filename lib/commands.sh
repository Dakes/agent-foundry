#!/usr/bin/env bash
#
# Agent Foundry - Verb Commands
#
# The project-centric CLI: init, up, down, status, logs, attach, shell, rm,
# doctor, policy, image.
#
# The old noun domains (vm, agent, workspace, network, template, host) are
# deprecated and remain only for one release. Everything they did is either
# folded into these verbs or gone entirely because the sandbox model removed
# the need for it.
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
_project_image() {
    local name="$1"
    local agent

    agent="$(project_get "$name" '.agent' "${FOUNDRY_DEFAULT_AGENT:-ralph}")"

    local image
    image="$(project_get "$name" '.image' "")"

    if [[ -z "$image" ]]; then
        image="${FOUNDRY_IMAGE_REPO:-foundry-agent}:${agent}"
    fi

    printf '%s\n' "$image"
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
    sandbox_check_kvm || return 1
    sandbox_check_login || return 1

    local root box
    root="$(project_root "$name")"
    box="$(sandbox_name_for "$name")"

    # 1. Volume root (idempotent).
    project_scaffold "$name" || return 1

    # 2. Validate config before anything expensive happens.
    project_validate_config "$name" || return 1

    # 3. Network policy: baseline, then the rules this project's remotes need.
    #    Applied BEFORE the box is created so the first clone can succeed.
    policy_baseline || return 1

    local -a resources=()
    mapfile -t resources < <(project_policy_resources "$name")

    if [[ ${#resources[@]} -gt 0 ]]; then
        log_info "Allowing ${#resources[@]} project network resource(s)"
        policy_apply_rules "$box" "${resources[@]}" || return 1

        # Record derived rules so every exception is reviewable in the config.
        local json_rules
        json_rules="$(printf '%s\n' "${resources[@]}" | jq -R . | jq -s .)"
        project_set "$name" '.network.allow' "$json_rules" || return 1
    fi

    # 4. Create the sandbox.
    local image cpus memory shared
    image="$(_project_image "$name")"
    cpus="$(project_get "$name" '.resources.cpus' "${DEFAULT_CPUS:-}")"
    memory="$(project_get "$name" '.resources.memory' "${DEFAULT_MEMORY_SPEC:-}")"
    shared="$(project_shared_dir)"

    local -a specs=()
    mapfile -t specs < <(project_publish_specs "$name")

    sandbox_create "$box" "$image" "$cpus" "$memory" "$root" "$shared" "${specs[@]}" || return 1
    sandbox_start "$box" || return 1

    # 5. Clone declared repositories inside the sandbox. This is the first real
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

    log_info "Project '${name}' initialized"
    echo ""
    echo "  Volume root : $root"
    echo "  Sandbox     : $box"
    echo "  Config      : ${root}/foundry.json"
    echo ""
    echo "Next:"
    echo "  \$EDITOR ${root}/foundry.json     # agent, repos, watcher"
    echo "  \$EDITOR ${root}/.ssh/config      # git keys (manual, see comments)"
    echo "  foundry up ${name}"

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

    # 2. Ports. Mappings do not survive a restart, so they are re-applied on
    #    every up. Without this a watcher comes back deaf after a restart.
    local -a specs=()
    mapfile -t specs < <(project_publish_specs "$FOUNDRY_PROJECT")

    if [[ ${#specs[@]} -gt 0 ]]; then
        log_info "Publishing ${#specs[@]} port mapping(s)"
        sandbox_publish "$FOUNDRY_BOX" "${specs[@]}" || return 1
    fi

    # 3. Repos: clone anything declared but missing.
    project_fix_ssh_perms "$FOUNDRY_ROOT"
    project_clone_repos "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1

    # 4. Agent.
    if [[ "$no_agent" == "true" ]]; then
        log_info "Skipping agent start (--no-agent)"
    else
        foundry_agent_start "$FOUNDRY_PROJECT" "$FOUNDRY_BOX" "$FOUNDRY_ROOT" || return 1
    fi

    # 5. Watchers are not wired into the sandbox transport yet (Phase 4).
    local watcher_kind
    watcher_kind="$(project_get "$FOUNDRY_PROJECT" '.watcher.kind' "")"
    if [[ -n "$watcher_kind" ]]; then
        log_warn "Watcher '${watcher_kind}' is configured but not started:"
        log_warn "  watcher support on the sandbox transport is not implemented yet."
        log_warn "  The receiver port is published, so the forge can reach it once it is."
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
    agent="$(project_get "$name" '.agent' "${FOUNDRY_DEFAULT_AGENT:-ralph}")"

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
        echo "Agent   : $(project_get "$FOUNDRY_PROJECT" '.agent' "${FOUNDRY_DEFAULT_AGENT:-ralph}")"
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

    if ! sandbox_is_running "$FOUNDRY_BOX"; then
        log_error "Sandbox is not running: $FOUNDRY_BOX"
        log_error "Start it with: foundry up $FOUNDRY_PROJECT"
        return 1
    fi

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

    if ! sandbox_is_running "$FOUNDRY_BOX"; then
        log_error "Sandbox is not running: $FOUNDRY_BOX"
        return 1
    fi

    local agent session
    agent="$(project_get "$FOUNDRY_PROJECT" '.agent' "${FOUNDRY_DEFAULT_AGENT:-ralph}")"
    session="$(agent_session_name "$agent")"

    if ! foundry_agent_running "$FOUNDRY_BOX" "$FOUNDRY_ROOT" "$agent"; then
        log_error "No running agent session '$session' in $FOUNDRY_BOX"
        log_error "Start it with: foundry up $FOUNDRY_PROJECT"
        return 1
    fi

    log_info "Attaching to '$session' (detach with Ctrl-b d)"
    sandbox_exec_tty "$FOUNDRY_BOX" "$FOUNDRY_ROOT" tmux attach -t "$session"
}

cmd_logs() {
    local name="${1:-}"
    [[ "$name" == -* ]] && name=""
    [[ -n "$name" ]] && shift

    local follow=false
    local watcher=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow)
                follow=true
                ;;
            --watcher)
                watcher=true
                ;;
            *)
                log_error "Unknown option for 'foundry logs': $1"
                return 1
                ;;
        esac
        shift
    done

    _resolve_existing "$name" || return 1

    # Logs are files in the volume root: read them on the host, no exec needed.
    local log_file
    if [[ "$watcher" == "true" ]]; then
        log_file="$(find "$FOUNDRY_ROOT/logs" -maxdepth 1 -name '*watcher*.log' 2>/dev/null | head -1)"
    else
        local agent
        agent="$(project_get "$FOUNDRY_PROJECT" '.agent' "${FOUNDRY_DEFAULT_AGENT:-ralph}")"
        log_file="$(agent_log_file "$agent" "$FOUNDRY_ROOT" 2>/dev/null || true)"
    fi

    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        log_error "No log file found${log_file:+: $log_file}"
        log_error "Looked under: ${FOUNDRY_ROOT}/logs"
        return 1
    fi

    if [[ "$follow" == "true" ]]; then
        tail -f "$log_file"
    else
        tail -n 200 "$log_file"
    fi
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

    if check_kvm; then
        echo "  ok     KVM available"
    else
        echo "  FAIL   KVM unavailable or /dev/kvm not accessible"
        echo "         sudo usermod -aG kvm \$USER && newgrp kvm"
        failures=$((failures + 1))
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
        port="$(project_get "$name" '.watcher.port' "")"
        if [[ -n "$port" && "$port" != "0" ]] && check_command "$SBX_BIN"; then
            if sandbox_is_running "$box" && sandbox_port_published "$box" "$port"; then
                echo "  ok     watcher port $port published"
            else
                echo "  FAIL   watcher port $port is NOT published"
                echo "         port mappings do not survive a restart - run: foundry up $name"
                failures=$((failures + 1))
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
            policy_baseline
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
            echo "Actions: baseline, allow, deny, check, ls" >&2
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
            local variant="${1:-ralph}"

            if [[ ! -f "$dockerfile" ]]; then
                log_error "Dockerfile not found: $dockerfile"
                return 1
            fi
            if ! check_command docker; then
                log_error "docker is required to build the agent image"
                return 1
            fi

            log_info "Building ${repo}:${variant}"
            docker build \
                -f "$dockerfile" \
                --build-arg "RALPH_VARIANT=${variant}" \
                -t "${repo}:${variant}" \
                "${FOUNDRY_BASE}"
            ;;
        push)
            local variant="${1:-ralph}"
            if ! check_command docker; then
                log_error "docker is required to push the agent image"
                return 1
            fi
            docker push "${repo}:${variant}"
            ;;
        *)
            log_error "Unknown image action: ${action:-<none>}"
            echo "Actions: build [variant], push [variant]" >&2
            return 1
            ;;
    esac
}
