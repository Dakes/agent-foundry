#!/usr/bin/env bash
#
# Agent Foundry - Release Build Script
#
# Creates a self-extracting archive containing the entire Agent Foundry project.
# The resulting binary can be installed anywhere and executed without external dependencies.
#
# Usage:
#   ./scripts/build-release.sh              # Build to bin/foundry-release
#   ./scripts/build-release.sh --output /path/to/foundry  # Custom output path
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION=$(cat "${PROJECT_ROOT}/VERSION" | tr -d '[:space:]')
OUTPUT_BIN="${1:-bin/foundry-release}"
TEMP_DIR=$(mktemp -d)

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "🏗️  Building Agent Foundry v${VERSION} release..."
echo ""

# ============================================================================
# 1. Create the Stub (Executable Header)
# ============================================================================
# This is the code that runs when the user executes the binary.
# It extracts the payload to a temp directory and runs bin/foundry.

echo "📝 Creating executable stub..."
cat > "${TEMP_DIR}/stub.sh" << 'STUB_EOF'
#!/usr/bin/env bash
set -e

# Create a temporary directory for extraction
EXTRACT_DIR=$(mktemp -d /tmp/foundry.XXXXXX)

# Cleanup on exit
cleanup() {
    rm -rf "$EXTRACT_DIR"
}
trap cleanup EXIT

# Find the start of the binary payload (line number where tarball begins)
PAYLOAD_START=$(awk '/^__PAYLOAD_BEGINS__/ {print NR + 1; exit 0; }' "$0")

if [[ -z "$PAYLOAD_START" ]]; then
    echo "Error: Corrupted bundle - payload marker not found" >&2
    exit 1
fi

# Extract the payload
# tail: reads from this file starting at PAYLOAD_START
# tar: extracts it into the temp directory
tail -n +$PAYLOAD_START "$0" | tar xz -C "$EXTRACT_DIR" 2>/dev/null

if [[ ! -f "$EXTRACT_DIR/bin/foundry" ]]; then
    echo "Error: Bundle extraction failed - bin/foundry not found" >&2
    exit 1
fi

# Run the actual CLI with FOUNDRY_BASE_DIR set to the extracted location
# All arguments ("$@") are forwarded to the internal foundry script
FOUNDRY_BASE_DIR="$EXTRACT_DIR" "$EXTRACT_DIR/bin/foundry" "$@"

exit $?

# The marker that separates executable script from tarball payload
__PAYLOAD_BEGINS__
STUB_EOF

# ============================================================================
# 2. Create the Payload (Project files as tarball)
# ============================================================================
echo "📦 Packing project files..."

cd "$PROJECT_ROOT"

tar -czf "${TEMP_DIR}/payload.tar.gz" \
    --exclude='.git' \
    --exclude='tests' \
    --exclude='bin/foundry-release' \
    --exclude='bin/*-release' \
    --exclude='*.lock' \
    --exclude='.DS_Store' \
    --exclude='.gitignore' \
    --exclude='node_modules' \
    --exclude='.claude' \
    . || {
        echo "Error: Failed to create payload tarball" >&2
        exit 1
    }

PAYLOAD_SIZE=$(du -h "${TEMP_DIR}/payload.tar.gz" | cut -f1)
echo "   Payload size: $PAYLOAD_SIZE"

# ============================================================================
# 3. Fuse Stub and Payload
# ============================================================================
echo "🔨 Fusing stub and payload..."

cat "${TEMP_DIR}/stub.sh" "${TEMP_DIR}/payload.tar.gz" > "$OUTPUT_BIN"
chmod +x "$OUTPUT_BIN"

TOTAL_SIZE=$(du -h "$OUTPUT_BIN" | cut -f1)

echo ""
echo "✅ Build complete!"
echo "   Output:  $OUTPUT_BIN"
echo "   Size:    $TOTAL_SIZE"
echo ""
echo "Test it:"
echo "   ./$OUTPUT_BIN --version"
echo "   ./$OUTPUT_BIN --help"
echo ""
echo "Install it:"
echo "   ./install.sh --release ./$OUTPUT_BIN"
