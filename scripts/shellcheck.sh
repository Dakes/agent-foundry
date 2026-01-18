#!/usr/bin/env bash
#
# Agent Foundry - ShellCheck Validation Script
#
# Runs shellcheck on all shell scripts in the repository
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if shellcheck is installed
if ! command -v shellcheck &>/dev/null; then
    echo -e "${RED}Error: shellcheck is not installed${NC}"
    echo ""
    echo "Install shellcheck:"
    echo "  Arch:   sudo pacman -S shellcheck"
    echo "  Ubuntu: sudo apt install shellcheck"
    echo "  macOS:  brew install shellcheck"
    echo "  NixOS:  Add 'shellcheck' to your packages"
    exit 1
fi

# Find all shell scripts
mapfile -t scripts < <(find . -type f \( -name "*.sh" -o -path "*/bin/*" \) \
    ! -path "*/.*" \
    ! -path "*/node_modules/*" \
    ! -path "*/vendor/*" \
    ! -name "*-release")

if [[ ${#scripts[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Warning: No shell scripts found${NC}"
    exit 0
fi

echo "Running shellcheck on ${#scripts[@]} files..."
echo ""

failed=0
passed=0

for script in "${scripts[@]}"; do
    if shellcheck "$script" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $script"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $script"
        shellcheck "$script" 2>&1 | head -20
        failed=$((failed + 1))
    fi
done

echo ""
echo "=========================================="
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "=========================================="

if [[ $failed -gt 0 ]]; then
    exit 1
fi

exit 0
