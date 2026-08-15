#!/usr/bin/env bash
#
# Mark all currently open issues and PRs on watched Forgejo repositories as
# processed, so the watcher does not backfill historic events on first start.
#
# Intended to run inside the sandbox; see 'foundry watcher'.

set -uo pipefail

CONFIG_DIR="${CONFIG_DIR:-${HOME:?HOME is not set}/.config/forgejo-watcher}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.conf}"
PROCESSED_FILE="${PROCESSED_FILE:-$CONFIG_DIR/processed.json}"

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

if [[ -z "${FORGEJO_TOKEN:-}" && -f "$CONFIG_DIR/token" ]]; then
    FORGEJO_TOKEN=$(cat "$CONFIG_DIR/token")
fi

if [[ -z "${FORGEJO_INSTANCE_URL:-}" || -z "${WATCHED_REPOS:-}" ]]; then
    echo "FORGEJO_INSTANCE_URL or WATCHED_REPOS not configured" >&2
    exit 1
fi

ensure_processed_file_valid() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$PROCESSED_FILE" ]] || ! jq -e '.processed' "$PROCESSED_FILE" >/dev/null 2>&1; then
        cat > "$PROCESSED_FILE" <<'EOF'
{
  "version": "1.0",
  "processed": {},
  "last_poll": "1970-01-01T00:00:00Z"
}
EOF
    fi
}

api_get() {
    local endpoint="$1"
    local url
    url="${FORGEJO_INSTANCE_URL%/}/api/v1/${endpoint#/}"
    curl -s -S -L -H "Accept: application/json" \
         -H "Authorization: token $FORGEJO_TOKEN" \
         "$url" 2>/dev/null
}

split_repo() {
    local repo="$1"
    local owner part
    owner=$(printf '%s' "$repo" | cut -d'/' -f1)
    part=$(printf '%s' "$repo" | cut -d'/' -f2-)
    printf '%s %s' "$owner" "$part"
}

mark_item() {
    local temp_file="$1"
    local item_type="$2"
    local item_repo="$3"
    local item_number="$4"
    local processed_at="$5"

    local new_file
    new_file=$(mktemp)
    jq ".processed[\"${item_type}_${item_number}\"] = {\"type\":\"$item_type\",\"number\":$item_number,\"repo\":\"$item_repo\",\"processed_at\":\"$processed_at\",\"result\":\"marked\"}" "$temp_file" > "$new_file" && mv "$new_file" "$temp_file"
}

fetch_and_mark_paginated() {
    local owner="$1"
    local part="$2"
    local endpoint="$3"
    local item_type="$4"
    local repo="$5"
    local processed_at="$6"
    local temp_file="$7"

    local page=1
    local items

    while true; do
        items=$(api_get "repos/$owner/$part/$endpoint?state=open&page=$page&limit=50" | jq -c '.[]? | {number: .number, type: "'"$item_type"'"}' 2>/dev/null || true)
        [[ -z "$items" ]] && break

        local item
        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            local number itype
            number=$(echo "$item" | jq -r '.number')
            itype=$(echo "$item" | jq -r '.type')
            mark_item "$temp_file" "$itype" "$repo" "$number" "$processed_at"
        done <<< "$items"

        page=$((page + 1))
    done
}

process_repo() {
    local repo="$1"
    local processed_at="$2"
    local temp_file="$3"

    local owner part
    read -r owner part <<< "$(split_repo "$repo")"

    fetch_and_mark_paginated "$owner" "$part" "issues" "issue" "$repo" "$processed_at" "$temp_file"
    fetch_and_mark_paginated "$owner" "$part" "pulls" "pr" "$repo" "$processed_at" "$temp_file"
}

main() {
    ensure_processed_file_valid

    local temp_file
    temp_file=$(mktemp)
    cp "$PROCESSED_FILE" "$temp_file"

    local processed_at
    processed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local repo
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        process_repo "$repo" "$processed_at" "$temp_file"
    done < <(echo "$WATCHED_REPOS" | tr ',' '\n')

    mv "$temp_file" "$PROCESSED_FILE"
    echo "Marked open issues and PRs as processed"
}

main "$@"
