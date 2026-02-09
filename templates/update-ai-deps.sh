#!/usr/bin/env bash
#
# Update AI Dependencies
#
# Updates all AI agent dependencies:
# - Claude Code CLI (@anthropic-ai/claude-code)
# - Gemini CLI (gemini-cli)
# - OpenAI CLI (openai)
# - Ralph agent (ralph-claude-code)
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

main() {
    log_info "=== Starting AI Dependency Updates ==="
    echo ""

    # Update Claude Code CLI
    log_info "Updating Claude Code CLI..."
    export NVM_DIR="/root/.nvm"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
    npm update -g @anthropic-ai/claude-code
    log_success "Claude Code CLI updated"
    echo ""

    # Update Gemini CLI
    log_info "Updating Gemini CLI..."
    python3 -m pip install --upgrade gemini-cli
    log_success "Gemini CLI updated"
    echo ""

    # Update OpenAI CLI
    log_info "Updating OpenAI CLI..."
    python3 -m pip install --upgrade openai
    log_success "OpenAI CLI updated"
    echo ""

    # Update Ralph agent
    log_info "Updating Ralph agent..."
    if [[ -d /opt/ralph ]]; then
        git -C /opt/ralph pull
        /opt/ralph/install.sh
        log_success "Ralph agent updated"
    else
        log_error "Ralph not found at /opt/ralph, skipping"
    fi
    echo ""

    log_success "=== All updates completed ==="
}

main "$@"
