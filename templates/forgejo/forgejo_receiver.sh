#!/usr/bin/env bash
#
# Forgejo webhook receiver.
#
# Listens on a TCP port, accepts Forgejo webhook POST requests, verifies the
# HMAC-SHA256 signature, and writes validated events to a queue directory.
#
# Can be launched standalone or from forgejo_watcher.sh.
#

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${HOME:?HOME is not set}/.config/forgejo-watcher}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.conf}"
QUEUE_DIR="${QUEUE_DIR:-$CONFIG_DIR/queue}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/receiver.log}"
PID_FILE="${PID_FILE:-$CONFIG_DIR/receiver.pid}"

LISTEN_PORT="${LISTEN_PORT:-8080}"
LISTEN_INTERFACE="${LISTEN_INTERFACE:-0.0.0.0}"
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
log_debug() { log "DEBUG" "$@"; }

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

    if [[ -z "${WEBHOOK_SECRET:-}" && -f "$WEBHOOK_SECRET_FILE" ]]; then
        WEBHOOK_SECRET=$(cat "$WEBHOOK_SECRET_FILE")
    fi

    LISTEN_PORT="${LISTEN_PORT:-8080}"
    LISTEN_INTERFACE="${LISTEN_INTERFACE:-0.0.0.0}"
    QUEUE_DIR="${QUEUE_DIR:-$CONFIG_DIR/queue}"
}

# ============================================================================
# QUEUE
# ============================================================================

queue_event() {
    local event_file
    event_file="$QUEUE_DIR/event-$(date +%s%N)-$RANDOM.json"
    mkdir -p "$QUEUE_DIR"
    cat > "$event_file"
    log_info "Queued event: $event_file"
}

# ============================================================================
# REQUEST PARSING
# ============================================================================

# Read a single HTTP request from stdin, parse headers and body, verify
# signature, and queue the event if valid.
handle_request() {
    local request_line header_name header_value
    local content_length=0
    local event_type=""
    local signature=""

    # Read request line
    if ! IFS= read -r request_line; then
        log_debug "No request line received"
        http_response 400 "Bad Request"
        return
    fi

    request_line="${request_line%$'\r'}"

    # We only accept POST /webhook
    if [[ ! "$request_line" =~ ^POST\ /webhook(\?.*)?\ HTTP/1\.[01]$ ]]; then
        log_debug "Rejecting request line: $request_line"
        http_response 404 "Not Found"
        return
    fi

    # Read headers
    while IFS= read -r header_line; do
        header_line="${header_line%$'\r'}"
        [[ -z "$header_line" ]] && break

        header_name=$(printf '%s' "$header_line" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
        header_value=$(printf '%s' "$header_line" | cut -d':' -f2- | sed 's/^ *//')

        case "$header_name" in
            x-forgejo-event|x-gitea-event|x-github-event)
                event_type="$header_value"
                ;;
            x-hub-signature-256)
                signature="$header_value"
                ;;
            x-gitea-signature|x-gogs-signature)
                if [[ -z "$signature" && -n "$header_value" ]]; then
                    signature="sha256=$header_value"
                fi
                ;;
            content-length)
                content_length="$header_value"
                ;;
        esac
    done

    # Read body
    local body=""
    if [[ "$content_length" =~ ^[0-9]+$ ]] && [[ "$content_length" -gt 0 ]]; then
        body=$(head -c "$content_length")
    fi

    log_debug "Received $event_type event (len=$content_length)"

    if [[ -z "$event_type" ]]; then
        log_warn "Missing event type header"
        http_response 400 "Bad Request"
        return
    fi

    # Verify signature if a secret is configured
    if [[ -n "$WEBHOOK_SECRET" ]]; then
        if [[ -z "$signature" ]]; then
            log_warn "Webhook signature missing but secret is configured"
            http_response 401 "Unauthorized"
            return
        fi

        local expected
        expected="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $NF}')"
        if [[ "$signature" != "$expected" ]]; then
            log_warn "Invalid webhook signature"
            http_response 401 "Unauthorized"
            return
        fi
    fi

    # Normalize and queue event
    local event_payload payload_json
    payload_json=$(printf '%s' "$body" | jq -s '.[0]? // {}')
    event_payload=$(jq -n \
        --arg event_type "$event_type" \
        --arg received_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson payload "$payload_json" \
        '{event_type: $event_type, received_at: $received_at, payload: $payload}')

    printf '%s\n' "$event_payload" | queue_event

    http_response 200 "OK"
}

http_response() {
    local code="$1"
    local message="$2"
    printf 'HTTP/1.1 %s %s\r\n' "$code" "$message"
    printf 'Content-Type: text/plain\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s\n' "$message"
}

# ============================================================================
# SERVER BACKENDS
# ============================================================================

run_socat_server() {
    log_info "Starting Forgejo receiver on $LISTEN_INTERFACE:$LISTEN_PORT (socat)"
    printf '%s\n' "$$" > "$PID_FILE"

    socat "TCP4-LISTEN:$LISTEN_PORT,bind=$LISTEN_INTERFACE,reuseaddr,fork" \
        EXEC:"$0 handle-request" 2>>"$LOG_FILE" || {
        log_error "socat server exited with error"
        return 1
    }
}

start_server() {
    load_config

    # config.conf names the port RECEIVER_PORT, because that is what it is
    # called in foundry.json and in the published port mapping. Without this
    # the receiver silently kept its own default and listened on 8080, so
    # every webhook was refused on the port the forge had been told to use.
    LISTEN_PORT="${RECEIVER_PORT:-$LISTEN_PORT}"
    LISTEN_INTERFACE="${RECEIVER_INTERFACE:-$LISTEN_INTERFACE}"

    mkdir -p "$QUEUE_DIR"

    if ! command -v socat >/dev/null 2>&1; then
        log_error "socat is required for the Forgejo webhook receiver"
        return 1
    fi

    run_socat_server
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local action="${1:-start}"

    case "$action" in
        start)
            start_server
            ;;
        handle-request)
            handle_request
            ;;
        stop)
            if [[ -f "$PID_FILE" ]]; then
                local pid
                pid=$(cat "$PID_FILE")
                if kill "$pid" 2>/dev/null; then
                    log_info "Stopped receiver (pid $pid)"
                fi
                rm -f "$PID_FILE"
            fi
            ;;
        *)
            echo "Usage: $0 {start|stop|handle-request}"
            exit 1
            ;;
    esac
}

main "$@"
