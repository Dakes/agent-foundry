#!/usr/bin/env bash
#
# Agent Foundry - Network Setup Wrapper
#
# Wrapper script to initialize host networking.
# Calls network_init from lib/network.sh.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source network library
if [[ -f "${PROJECT_ROOT}/lib/network.sh" ]]; then
    # shellcheck source=lib/network.sh
    source "${PROJECT_ROOT}/lib/network.sh"
else
    echo "Error: lib/network.sh not found" >&2
    exit 1
fi

# Run initialization
if ! network_init; then
    echo "Error: Network initialization failed" >&2
    exit 1
fi

exit 0
