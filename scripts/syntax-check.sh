#!/usr/bin/env bash
#
# Agent Foundry - Bash Syntax Validation Script
#
# Runs `bash -n` on all shell scripts in the repository.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

mapfile -t scripts < <(find . -type f \( -name "*.sh" -o -path "*/bin/*" \) \
    ! -path "*/.*" \
    ! -path "*/node_modules/*" \
    ! -path "*/vendor/*" \
    ! -name "*-release")

failed=0
passed=0

for script in "${scripts[@]}"; do
    if bash -n "$script" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $script"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $script"
        bash -n "$script" 2>&1 | head -10 || true
        failed=$((failed + 1))
    fi
done

echo ""
echo "=========================================="
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "=========================================="

[[ $failed -eq 0 ]] || exit 1
