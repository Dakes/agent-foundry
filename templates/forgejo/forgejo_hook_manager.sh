#!/usr/bin/env bash
#
# Forgejo webhook manager.
#
# Registers and unregisters repository webhooks on a Forgejo instance.
#

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/root/.config/forgejo-watcher}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.conf}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/hook-manager.log}"
HOOKS_FILE="${HOOKS_FILE:-$CONFIG_DIR/hooks.json}"

FORGEJO_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-}"
FORGEJO_TOKEN_FILE="${FORGEJO_TOKEN_FILE:-$CONFIG_DIR/token}"
FORGEJO_TOKEN="${FORGEJO_TOKEN:-}"
FORGEJO_ADMIN_TOKEN_FILE="${FORGEJO_ADMIN_TOKEN_FILE:-$CONFIG_DIR/admin-token}"
WATCHED_REPOS="${WATCHED_REPOS:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
WEBHOOK_SECRET_FILE="${WEBHOOK_SECRET_FILE:-$CONFIG_DIR/webhook-secret}"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    shift
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ============================================================================
# CONFIG
# ============================================================================

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        set +a
    fi

    if [[ -z "${FORGEJO_TOKEN:-}" && -f "$FORGEJO_TOKEN_FILE" ]]; then
        FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
    fi

    # Webhook management (register/unregister/list) requires repo admin.
    # Use a dedicated admin token if provided, otherwise fall back to the
    # regular token.
    if [[ -f "$FORGEJO_ADMIN_TOKEN_FILE" ]]; then
        FORGEJO_TOKEN=$(cat "$FORGEJO_ADMIN_TOKEN_FILE")
    fi

    if [[ -z "${WEBHOOK_SECRET:-}" && -f "$WEBHOOK_SECRET_FILE" ]]; then
        WEBHOOK_SECRET=$(cat "$WEBHOOK_SECRET_FILE")
    fi

    FORGEJO_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-}"
    WATCHED_REPOS="${WATCHED_REPOS:-}"
    WEBHOOK_URL="${WEBHOOK_URL:-}"
}

# ============================================================================
# API CLIENT
# ============================================================================

forgejo_api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    if [[ -z "$FORGEJO_INSTANCE_URL" ]]; then
        log_error "FORGEJO_INSTANCE_URL is not configured"
        return 1
    fi

    local url="${FORGEJO_INSTANCE_URL%/}/api/v1/${endpoint#/}"
    local curl_opts=( -s -S -L -w "\n%{http_code}" )

    curl_opts+=( -H "Accept: application/json" )
    curl_opts+=( -H "Content-Type: application/json" )

    if [[ -n "$FORGEJO_TOKEN" ]]; then
        curl_opts+=( -H "Authorization: token $FORGEJO_TOKEN" )
    fi

    if [[ "$method" != "GET" ]]; then
        curl_opts+=( -X "$method" )
    fi

    local response status body
    response=$(curl "${curl_opts[@]}" "$url" "$@" 2>&1) || {
        log_error "Forgejo API request failed: $url"
        return 1
    }

    status=$(printf '%s\n' "$response" | tail -n 1)
    body=$(printf '%s\n' "$response" | sed '$d')

    if [[ -z "$status" || ! "$status" =~ ^[0-9]+$ ]]; then
        log_error "Forgejo API returned invalid status for $url"
        printf '%s\n' "$body"
        return 1
    fi

    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
        if [[ "$status" == "403" ]]; then
            log_error "Forgejo API permission denied ($status) for $url. The token likely lacks admin access to this repository. If using a bot account, set admin_token_file in the project config. Response: $body"
        else
            log_error "Forgejo API error $status for $url: $body"
        fi
        return 1
    fi

    printf '%s\n' "$body"
}

forgejo_get()    { forgejo_api_call GET "$@"; }
forgejo_post()   { forgejo_api_call POST "$@" -d "@-"; }
forgejo_delete() { forgejo_api_call DELETE "$@"; }

split_repo() {
    local repo="$1"
    local owner part
    owner=$(printf '%s' "$repo" | cut -d'/' -f1)
    part=$(printf '%s' "$repo" | cut -d'/' -f2-)
    printf '%s %s' "$owner" "$part"
}

# ============================================================================
# HOOK STATE
# ============================================================================

ensure_hooks_file() {
    mkdir -p "$(dirname "$HOOKS_FILE")"
    if [[ ! -f "$HOOKS_FILE" ]]; then
        cat > "$HOOKS_FILE" <<'EOF'
{
  "version": "1.0",
  "hooks": {}
}
EOF
    fi
}

store_hook_id() {
    local repo="$1"
    local hook_id="$2"
    ensure_hooks_file
    local temp
    temp=$(mktemp)
    jq ".hooks.\"$repo\" = $hook_id" "$HOOKS_FILE" > "$temp"
    mv "$temp" "$HOOKS_FILE"
}

remove_hook_id() {
    local repo="$1"
    ensure_hooks_file
    local temp
    temp=$(mktemp)
    jq "del(.hooks.\"$repo\")" "$HOOKS_FILE" > "$temp"
    mv "$temp" "$HOOKS_FILE"
}

get_hook_id() {
    local repo="$1"
    ensure_hooks_file
    jq -r ".hooks.\"$repo\" // empty" "$HOOKS_FILE"
}

# ============================================================================
# COMMANDS
# ============================================================================

find_existing_hook() {
    local owner="$1"
    local part="$2"
    local webhook_url="$3"

    local hooks
    hooks=$(forgejo_get "repos/$owner/$part/hooks?limit=50") || return 1
    printf '%s\n' "$hooks" | jq -r \
        --arg url "$webhook_url" \
        '.[] | select(.config.url == $url) | .id' | head -1
}

cmd_register() {
    load_config

    if [[ -z "$WATCHED_REPOS" ]]; then
        log_error "No watched repositories configured"
        return 1
    fi

    if [[ -z "$WEBHOOK_URL" ]]; then
        log_error "WEBHOOK_URL is not configured"
        return 1
    fi

    local config_secret="$WEBHOOK_SECRET"
    local failed=0

    local repo
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue

        local owner part
        read -r owner part <<< "$(split_repo "$repo")"

        local existing_id
        existing_id=$(find_existing_hook "$owner" "$part" "$WEBHOOK_URL") || {
            log_error "Failed to list hooks for $repo"
            failed=1
            continue
        }

        if [[ -n "$existing_id" ]]; then
            log_info "Webhook already exists for $repo (id=$existing_id), skipping"
            store_hook_id "$repo" "$existing_id"
            continue
        fi

        log_info "Registering webhook for $repo"

        local payload
        payload=$(jq -n \
            --arg type "forgejo" \
            --arg url "$WEBHOOK_URL" \
            --arg secret "$config_secret" \
            '{
                type: $type,
                config: {
                    url: $url,
                    content_type: "json",
                    secret: $secret
                },
                events: [
                    "issues",
                    "pull_request",
                    "issue_comment",
                    "pull_request_review_comment",
                    "workflow_run"
                ],
                active: true
            }')

        local response
        response=$(printf '%s\n' "$payload" | forgejo_post "repos/$owner/$part/hooks") || {
            log_error "Failed to register webhook for $repo"
            failed=1
            continue
        }

        local hook_id
        hook_id=$(printf '%s\n' "$response" | jq -r '.id // empty')
        if [[ -n "$hook_id" ]]; then
            store_hook_id "$repo" "$hook_id"
            log_info "Registered webhook $hook_id for $repo"
        else
            log_warn "Webhook registered but no ID returned for $repo"
        fi
    done < <(echo "$WATCHED_REPOS" | tr ',' '\n')

    if [[ "$failed" -ne 0 ]]; then
        log_error "One or more webhooks could not be registered"
        return 1
    fi
}

cmd_unregister() {
    load_config

    ensure_hooks_file

    local repos
    repos=$(jq -r '.hooks | keys[]' "$HOOKS_FILE" 2>/dev/null || true)

    if [[ -z "$repos" ]]; then
        log_warn "No recorded webhooks to unregister"
        return 0
    fi

    local failed=0
    local repo
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue

        local hook_id
        hook_id=$(get_hook_id "$repo")
        if [[ -z "$hook_id" ]]; then
            continue
        fi

        log_info "Unregistering webhook $hook_id for $repo"

        local owner part
        read -r owner part <<< "$(split_repo "$repo")"

        if forgejo_delete "repos/$owner/$part/hooks/$hook_id" >/dev/null 2>&1; then
            remove_hook_id "$repo"
            log_info "Unregistered webhook for $repo"
        else
            log_error "Failed to unregister webhook for $repo"
            failed=1
        fi
    done <<< "$repos"

    if [[ "$failed" -ne 0 ]]; then
        log_error "One or more webhooks could not be unregistered"
        return 1
    fi
}

cmd_list() {
    load_config
    ensure_hooks_file
    jq '.' "$HOOKS_FILE"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local action="${1:-register}"

    case "$action" in
        register)
            cmd_register
            ;;
        unregister)
            cmd_unregister
            ;;
        list)
            cmd_list
            ;;
        *)
            echo "Usage: $0 {register|unregister|list}"
            exit 1
            ;;
    esac
}

main "$@"
