#!/usr/bin/env bash
#
# Agent Foundry - Network Policy
#
# Replaces lib/network.sh (TAP devices, IP pool, NAT). Docker Sandboxes has no
# per-box IP and no host-managed network; what Foundry manages instead is the
# egress policy enforced by the host-side proxy.
#
# Foundry's stance:
#   - Full internet egress (the 'open' preset), because a deny-by-default
#     allowlist for a general-purpose coding agent is unmaintainable.
#   - The LAN, the host, and link-local space stay denied. sbx already blocks
#     private ranges by default; Foundry adds explicit deny rules so the
#     posture survives a preset change and cannot be widened by a kit.
#   - Per-project holes are derived from the project's git remotes and written
#     back to the project config, so every exception is reviewable in a diff.
#
# Note: UDP and ICMP are blocked at the network layer and cannot be unblocked
# by policy. Non-HTTP TCP (e.g. git over SSH on :22) can be allowed per host.
#
# Requires: sbx
#

# ============================================================================
# CONSTANTS
# ============================================================================

# Private, loopback and link-local space that must never be reachable from a
# sandbox. IPv4 and IPv6.
FOUNDRY_PRIVATE_RANGES=(
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "127.0.0.0/8"
    "fc00::/7"
    "fe80::/10"
)

# ============================================================================
# BASELINE
# ============================================================================

# Is the global network policy already initialized?
#
# `sbx policy init` is a one-time operation: it fails once a global policy
# exists. There is no query for "initialized", so this reads the rule list -
# an initialized host always has at least one global local-policy rule.
policy_is_initialized() {
    local json
    if ! json="$("$SBX_BIN" policy ls --json 2>/dev/null)"; then
        return 1
    fi

    printf '%s' "$json" | jq -e '
        (.rules // [])
        | map(select((.scope // "") == "global"))
        | length > 0
    ' >/dev/null 2>&1
}

# Does a deny rule for this exact resource already exist?
#
# Adding the same rule twice creates two rules, so the baseline - which runs on
# every init and every `doctor --fix` - would otherwise accumulate duplicates.
policy_has_deny() {
    local resource="$1"

    local json
    if ! json="$("$SBX_BIN" policy ls --json 2>/dev/null)"; then
        return 1
    fi

    printf '%s' "$json" | jq -e --arg r "$resource" '
        (.rules // [])
        | map(select((.decision // "") == "deny"))
        | map(.resources // [])
        | flatten
        | any(. == $r)
    ' >/dev/null 2>&1
}

# Does an allow rule for this resource already exist?
#
# sbx normalizes a bare host to host:443 when it stores the rule, so a rule
# written as "github.com" comes back as "github.com:443"; both spellings count
# as a match.
policy_has_allow() {
    local resource="$1"

    local json
    if ! json="$("$SBX_BIN" policy ls --json 2>/dev/null)"; then
        return 1
    fi

    printf '%s' "$json" | jq -e --arg r "$resource" '
        (.rules // [])
        | map(select((.decision // "") == "allow"))
        | map(.resources // [])
        | flatten
        | any(. == $r or . == ($r + ":443"))
    ' >/dev/null 2>&1
}

# Addresses the sandbox needs in order to resolve names at all.
#
# Docker Sandboxes hands the container a resolver on the container network -
# 172.17.0.2 and a ULA v6 address on a default install. Both sit inside ranges
# this baseline denies, and sbx resolves a conflict in favour of the deny, so
# no allow rule can win it back. Denying them turns every lookup into
# "Temporary failure in name resolution", which reads like broken DNS rather
# than a policy Foundry applied on purpose.
#
# Usage: policy_resolver_addresses [sandbox]
policy_resolver_addresses() {
    local sandbox="${1:-}"
    [[ -n "$sandbox" ]] || return 0

    "$SBX_BIN" exec "$sandbox" cat /etc/resolv.conf 2>/dev/null \
        | awk '$1 == "nameserver" { print $2 }'
}

# Does this CIDR cover any of the sandbox's resolvers?
#
# Only the coarse case is handled: an address inside the range's prefix. That
# covers every default the baseline ships, and a wrong answer here fails safe -
# the range is denied, and the operator sees the same DNS failure with a
# message naming the cause.
policy_range_covers_resolver() {
    local range="$1"
    shift

    local addr prefix
    for addr in "$@"; do
        [[ -n "$addr" ]] || continue
        case "$range" in
            10.0.0.0/8)        [[ "$addr" == 10.* ]] && return 0 ;;
            172.16.0.0/12)     [[ "$addr" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0 ;;
            192.168.0.0/16)    [[ "$addr" == 192.168.* ]] && return 0 ;;
            169.254.0.0/16)    [[ "$addr" == 169.254.* ]] && return 0 ;;
            127.0.0.0/8)       [[ "$addr" == 127.* ]] && return 0 ;;
            fc00::/7)          [[ "$addr" == f[cd]* ]] && return 0 ;;
            fe80::/10)         [[ "$addr" == fe80:* ]] && return 0 ;;
            *)                 prefix="${range%%/*}"
                               [[ "$addr" == "$prefix" ]] && return 0 ;;
        esac
    done

    return 1
}

# Remove any deny rule that covers the sandbox's resolver.
#
# The baseline runs before the sandbox exists, so it cannot see the resolver
# and denies the range the resolver turns out to be in. This repairs that once
# there is a sandbox to ask, and fixes a host that is already in that state -
# the symptom is every lookup failing with "Temporary failure in name
# resolution", including for hosts that have an explicit allow rule.
#
# Usage: policy_unblock_resolvers <sandbox>
policy_unblock_resolvers() {
    local sandbox="$1"
    [[ -n "$sandbox" ]] || return 0

    local -a resolvers=()
    mapfile -t resolvers < <(policy_resolver_addresses "$sandbox" 2>/dev/null || true)
    [[ ${#resolvers[@]} -gt 0 ]] || return 0

    local json
    json="$("$SBX_BIN" policy ls --json 2>/dev/null)" || return 0

    local removed=0 rule_id resource
    while IFS=$'\t' read -r rule_id resource; do
        [[ -n "$rule_id" && -n "$resource" ]] || continue
        policy_range_covers_resolver "$resource" "${resolvers[@]}" || continue

        log_warn "Removing deny rule for ${resource}: it covers the sandbox resolver"
        log_warn "  DNS cannot work while it stands, and deny beats allow."
        if _sbx_checked "removing deny rule '$resource'" \
            policy rm network --id "$rule_id"; then
            removed=$((removed + 1))
        fi
    done < <(printf '%s' "$json" | jq -r '
        .rules[]?
        | select((.decision // "") == "deny")
        | select((.editable // true) == true)
        | . as $r
        | ($r.resources // [])[]
        | [$r.id, .]
        | @tsv')

    [[ "$removed" -gt 0 ]] && log_info "Unblocked DNS: removed ${removed} rule(s)"
    return 0
}

# Apply Foundry's host-wide network baseline.
#
# Usage: policy_baseline [--reset]
#
# The global preset can only be set once (`sbx policy init`). When the host is
# already initialized the existing preset is kept and only the private-range
# deny rules are reconciled; --reset wipes the policy store first, which stops
# every running sandbox, so it is never implied.
# Usage: policy_baseline [--reset] [sandbox]
#
# The sandbox is optional and used only to read its resolver; without one the
# baseline denies every private range, which is correct until a sandbox exists.
policy_baseline() {
    local reset=false
    if [[ "${1:-}" == "--reset" ]]; then
        reset=true
        shift
    fi

    log_info "Applying Foundry network baseline (open internet, closed LAN)"

    if [[ "$reset" == "true" ]]; then
        log_warn "Resetting the sbx policy store - running sandboxes will be stopped"
        if ! _sbx_checked "resetting the policy store" policy reset --force; then
            return 1
        fi
    fi

    if policy_is_initialized; then
        log_info "Global network policy already initialized - keeping the current preset"
        log_debug "Use 'foundry policy baseline --reset' to re-initialize as allow-all"
    elif ! _sbx_checked "initializing the global network policy" \
        policy init allow-all; then
        return 1
    fi

    # Skip any range the sandbox's own resolver sits in. Without this the
    # baseline silently disables DNS for every sandbox on the host.
    local -a resolvers=()
    mapfile -t resolvers < <(policy_resolver_addresses "${1:-}" 2>/dev/null || true)

    local range
    for range in "${FOUNDRY_PRIVATE_RANGES[@]}"; do
        if [[ ${#resolvers[@]} -gt 0 ]] && \
           policy_range_covers_resolver "$range" "${resolvers[@]}"; then
            log_warn "Not denying ${range}: the sandbox resolver lives there"
            log_warn "  Denying it would break DNS for every sandbox, and sbx"
            log_warn "  resolves deny over allow, so no rule could undo it."
            continue
        fi

        if policy_has_deny "$range"; then
            log_debug "Private range already denied: $range"
            continue
        fi

        log_debug "Denying private range: $range"
        if ! _sbx_checked "denying private range '$range'" \
            policy deny network "$range"; then
            return 1
        fi
    done

    log_info "Baseline applied: internet reachable, private ranges denied"
    return 0
}

# ============================================================================
# RULES
# ============================================================================

# Allow one network resource (hostname, host:port, IP, or CIDR).
# Usage: policy_allow "forge.example.com:22" [sandbox]
policy_allow() {
    local resource="$1"
    local sandbox="${2:-}"

    if [[ -z "$resource" ]]; then
        log_error "policy_allow: resource required"
        return 1
    fi

    if policy_has_allow "$resource"; then
        log_debug "Network resource already allowed: $resource"
        return 0
    fi

    local -a args=(policy allow network)
    if [[ -n "$sandbox" ]]; then
        args+=(--sandbox "$sandbox")
    fi
    args+=("$resource")

    log_debug "Allowing network resource: $resource${sandbox:+ (sandbox: $sandbox)}"
    _sbx_checked "allowing network access to '$resource'" "${args[@]}" || return 1

    return 0
}

# Deny one network resource.
# Usage: policy_deny "ads.example.com" [sandbox]
policy_deny() {
    local resource="$1"
    local sandbox="${2:-}"

    if [[ -z "$resource" ]]; then
        log_error "policy_deny: resource required"
        return 1
    fi

    local -a args=(policy deny network)
    if [[ -n "$sandbox" ]]; then
        args+=(--sandbox "$sandbox")
    fi
    args+=("$resource")

    _sbx_checked "denying network access to '$resource'" "${args[@]}" || return 1

    return 0
}

# List active rules (raw sbx output).
# Usage: policy_list [sandbox]
policy_list() {
    local sandbox="${1:-}"

    if [[ -n "$sandbox" ]]; then
        "$SBX_BIN" policy ls "$sandbox"
    else
        "$SBX_BIN" policy ls
    fi
}

# Would the current policy allow this target?
# Returns 0 when allowed, 1 when denied or indeterminate.
# Usage: policy_check "api.anthropic.com" [sandbox] && ...
policy_check() {
    local target="$1"
    local sandbox="${2:-}"

    local -a args=(policy check network)
    if [[ -n "$sandbox" ]]; then
        args+=(--sandbox "$sandbox")
    fi
    args+=("$target")

    local output
    if ! output="$("$SBX_BIN" "${args[@]}" 2>&1)"; then
        log_debug "policy check failed for $target: $output"
        return 1
    fi

    # Output is "Allowed: <target>" or "Denied: <target>".
    printf '%s' "$output" | grep -qi '^allowed'
}

# ============================================================================
# DERIVATION FROM GIT REMOTES
# ============================================================================

# Turn a git remote URL into a network policy resource.
#
#   git@host:org/repo.git        -> host:22    (raw TCP, needs an explicit rule)
#   ssh://git@host:2222/org/repo -> host:2222
#   https://host/org/repo.git    -> host       (evaluated against :443)
#
# A port-qualified rule is emitted together with the bare host, because the
# sandbox resolver answers only for hosts that have a rule and a "host:2222"
# rule does not satisfy it. Without the bare host, git fails with "Could not
# resolve hostname" - which reads like broken DNS rather than a denied host,
# and sends you looking in the wrong place entirely.
#
# Prints nothing for URLs with no network component (local paths).
# Usage: resource="$(policy_resource_for_remote "$url")"
policy_resource_for_remote() {
    local url="$1"

    [[ -z "$url" ]] && return 0

    case "$url" in
        ssh://*)
            # ssh://[user@]host[:port]/path
            local hostport="${url#ssh://}"
            hostport="${hostport%%/*}"
            hostport="${hostport##*@}"
            if [[ "$hostport" == *:* ]]; then
                printf '%s\n' "$hostport"
                # The resolver needs the bare host too, or the name never
                # resolves and the port rule is never reached.
                printf '%s\n' "${hostport%%:*}"
            else
                printf '%s:22\n' "$hostport"
                printf '%s\n' "$hostport"
            fi
            ;;
        *://*)
            # http(s)://[user@]host[:port]/path
            # Keep an explicit port: sbx evaluates a bare host against :443, so
            # dropping it would allow the wrong port for a self-hosted forge.
            local rest="${url#*://}"
            rest="${rest%%/*}"
            rest="${rest##*@}"
            printf '%s\n' "$rest"
            # Same resolver requirement as the ssh forms.
            [[ "$rest" == *:* ]] && printf '%s\n' "${rest%%:*}"
            ;;
        *@*:*)
            # scp-style: user@host:org/repo.git
            local hostpart="${url#*@}"
            hostpart="${hostpart%%:*}"
            printf '%s:22\n' "$hostpart"
            printf '%s\n' "$hostpart"
            ;;
        *)
            # Local path or unrecognized - nothing to allow.
            return 0
            ;;
    esac
}

# Is this resource inside private/LAN space?
# Used to warn loudly when a project punches a hole in the LAN denial.
# Usage: policy_is_private "192.168.1.50:3000" && log_warn ...
policy_is_private() {
    local resource="$1"
    local host="${resource%%:*}"

    case "$host" in
        10.*|127.*|169.254.*|192.168.*)
            return 0
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)
            return 0
            ;;
        localhost)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Apply a set of allow rules, warning about any that open the LAN.
# Usage: policy_apply_rules <sandbox> <resource> [resource...]
policy_apply_rules() {
    local sandbox="$1"
    shift

    local resource
    for resource in "$@"; do
        [[ -z "$resource" ]] && continue

        if policy_is_private "$resource"; then
            log_warn "Opening LAN access to ${resource} for sandbox ${sandbox}"
            log_warn "  This punches a hole in Foundry's private-range denial."
            log_warn "  It is recorded in the project config - review it there."
        fi

        policy_allow "$resource" "$sandbox" || return 1
    done

    return 0
}

# ============================================================================
# VERIFICATION
# ============================================================================

# Run the policy matrix: internet reachable, LAN and metadata denied, plus any
# project-specific resources that must be allowed.
#
# Usage: policy_check_matrix [sandbox] [required_resource...]
# Returns 0 when every expectation holds, 1 otherwise.
policy_check_matrix() {
    local sandbox="${1:-}"
    shift || true

    local failures=0

    # Must be reachable: the agent cannot work without these.
    local target
    for target in "api.anthropic.com" "github.com"; do
        if policy_check "$target" "$sandbox"; then
            log_info "  allow  $target"
        else
            log_error "  DENIED $target (expected to be allowed)"
            failures=$((failures + 1))
        fi
    done

    # Must be denied: LAN, host, and cloud metadata.
    for target in "192.168.1.1" "10.0.0.1" "172.16.0.1" "169.254.169.254"; do
        if policy_check "$target" "$sandbox"; then
            log_error "  ALLOWED $target (expected to be denied)"
            failures=$((failures + 1))
        else
            log_info "  deny   $target"
        fi
    done

    # Project-specific resources (git forges, self-hosted services).
    for target in "$@"; do
        [[ -z "$target" ]] && continue
        if policy_check "$target" "$sandbox"; then
            log_info "  allow  $target"
        else
            log_error "  DENIED $target (required by project config)"
            failures=$((failures + 1))
        fi
    done

    if [[ $failures -gt 0 ]]; then
        log_error "Network policy check failed: $failures problem(s)"
        return 1
    fi

    return 0
}
