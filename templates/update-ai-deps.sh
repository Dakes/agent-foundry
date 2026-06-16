#!/usr/bin/env bash
#
# Update AI Dependencies
#
# Updates all AI agent dependencies:
# - Claude Code CLI (@anthropic-ai/claude-code)
# - Gemini CLI (@google/gemini-cli)
# - OpenAI Codex CLI (@openai/codex)
# - Kimi Code CLI (kimi-cli)
# - Ralph agent (ralph-claude-code or ralph-orchestrator)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

detect_ralph_variant() {
    if [[ -f /opt/foundry/ralph-agent-type ]]; then
        tr -d '[:space:]' < /opt/foundry/ralph-agent-type
        return 0
    fi

    if [[ -d /opt/ralph ]]; then
        echo "ralph-claude-code"
        return 0
    fi

    if command -v ralph >/dev/null 2>&1; then
        local version
        version=$(ralph --version 2>/dev/null | head -n 1 || true)
        if echo "$version" | grep -qi "orchestrator"; then
            echo "ralph-orchestrator"
            return 0
        fi
    fi

    return 1
}

load_nvm() {
    export NVM_DIR="/root/.nvm"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
}

update_npm_cli() {
    local description="$1"
    local package="$2"
    local binary="$3"

    log_info "Updating ${description}..."
    npm update -g "$package"
    local bin_path
    bin_path="$(command -v "$binary")"
    install -d /usr/local/bin
    ln -sf "$bin_path" "/usr/local/bin/$binary"
    log_success "${description} updated"
    echo ""
}

remove_conflicting_ralph_artifacts() {
    rm -rf /opt/ralph
    rm -f /root/.local/bin/ralph /usr/local/bin/ralph
    npm uninstall -g @ralph-orchestrator/ralph-cli >/dev/null 2>&1 || true
}

main() {
    log_info "=== Starting AI Dependency Updates ==="
    echo ""

    load_nvm
    update_npm_cli "Claude Code CLI" "@anthropic-ai/claude-code" "claude"
    update_npm_cli "Gemini CLI" "@google/gemini-cli" "gemini"
    update_npm_cli "OpenAI Codex CLI" "@openai/codex" "codex"

    # Update Kimi Code CLI
    log_info "Updating Kimi Code CLI..."
    if command -v uv >/dev/null 2>&1; then
        uv tool upgrade kimi-cli
        install -d /usr/local/bin
        ln -sf "$(command -v kimi)" /usr/local/bin/kimi
        log_success "Kimi Code CLI updated"
    else
        log_error "uv not found; skipping Kimi Code CLI update"
    fi
    echo ""

    # Update Ralph agent
    log_info "Updating Ralph agent..."
    local ralph_variant
    ralph_variant=$(detect_ralph_variant || true)
    case "$ralph_variant" in
        ralph-claude-code)
            if [[ -d /opt/ralph ]]; then
                git -C /opt/ralph pull
                /opt/ralph/install.sh
                if command -v ralph >/dev/null 2>&1; then
                    install -d /usr/local/bin
                    ln -sf "$(command -v ralph)" /usr/local/bin/ralph
                fi
                log_success "Ralph agent updated (ralph-claude-code)"
            else
                log_error "Ralph variant is ralph-claude-code but /opt/ralph is missing"
            fi
            ;;
        ralph-orchestrator)
            remove_conflicting_ralph_artifacts
            npm update -g @ralph-orchestrator/ralph-cli
            install -d /usr/local/bin
            ln -sf "$(command -v ralph)" /usr/local/bin/ralph
            log_success "Ralph agent updated (ralph-orchestrator)"
            ;;
        *)
            log_error "No supported Ralph variant detected, skipping Ralph update"
            ;;
    esac
    echo ""

    log_success "=== All updates completed ==="
}

main "$@"
