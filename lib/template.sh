#!/usr/bin/env bash
#
# Agent Foundry - Template Management
#
# Functions for managing VM templates
#

set -euo pipefail

# Source utils for logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    # shellcheck source=lib/utils.sh
    source "${SCRIPT_DIR}/utils.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

FOUNDRY_BASE="${FOUNDRY_BASE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FOUNDRY_DATA_DIR="${FOUNDRY_DATA_DIR:-${HOME}/.local/share/foundry}"
FOUNDRY_VMS_DIR="${FOUNDRY_DATA_DIR}/vms"
FOUNDRY_TEMPLATES_DIR="${FOUNDRY_VMS_DIR}/templates"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

_format_size() {
    local bytes="$1"

    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0B"
        return 0
    fi

    if check_command numfmt; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        echo "${bytes}B"
    fi
}

_template_filename() {
    local name="$1"

    if [[ "$name" == *.ext4 ]]; then
        echo "$name"
        return 0
    fi

    if [[ "$name" == *.* ]]; then
        echo "$name"
        return 0
    fi

    echo "${name}.ext4"
}

# List templates
template_list() {
    log_info "Available templates:"
    echo ""

    if [[ ! -d "$FOUNDRY_TEMPLATES_DIR" ]]; then
        log_warn "Templates directory not found: $FOUNDRY_TEMPLATES_DIR"
        return 0
    fi

    local templates=()
    while IFS= read -r -d '' template; do
        templates+=("$template")
    done < <(find "$FOUNDRY_TEMPLATES_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "  No templates found"
        return 0
    fi

    printf "  %-32s %10s\n" "NAME" "SIZE"
    printf "  %-32s %10s\n" "----" "----"

    local template name size_bytes size
    for template in "${templates[@]}"; do
        name="$(basename "$template")"
        size_bytes=$(stat -c %s "$template" 2>/dev/null || stat -f %z "$template" 2>/dev/null || wc -c < "$template" 2>/dev/null || echo "0")
        size=$(_format_size "$size_bytes")
        printf "  %-32s %10s\n" "$name" "$size"
    done

    return 0
}

# Build template
template_build() {
    local template_type="${1:-}"
    shift || true

    if [[ -z "$template_type" ]]; then
        log_error "Template type required (base|golden)"
        return 1
    fi

    local script_path=""
    case "$template_type" in
        base)
            script_path="${FOUNDRY_BASE}/scripts/build-arch-base.sh"
            ;;
        golden)
            script_path="${FOUNDRY_BASE}/scripts/build-golden.sh"
            ;;
        *)
            log_error "Invalid template type: $template_type (valid: base, golden)"
            return 1
            ;;
    esac

    if [[ ! -x "$script_path" ]]; then
        log_error "Template build script not found or not executable: $script_path"
        return 1
    fi

    log_info "Building ${template_type} template..."
    "$script_path" "$@"
}

# Delete template
template_delete() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Template name required"
        return 1
    fi

    local path
    path=$(template_path "$name") || return 1

    if [[ ! -f "$path" ]]; then
        log_error "Template not found: $path"
        return 1
    fi

    if ! confirm "Delete template '$name'?"; then
        log_info "Delete cancelled"
        return 0
    fi

    if rm -f "$path"; then
        log_info "Template deleted: $path"
        return 0
    fi

    log_error "Failed to delete template: $path"
    return 1
}

# Check if template exists
template_exists() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Template name required"
        return 1
    fi

    local path
    path=$(template_path "$name") || return 1

    [[ -f "$path" ]]
}

# Get template path
template_path() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Template name required"
        return 1
    fi

    local filename
    filename=$(_template_filename "$name")

    echo "${FOUNDRY_TEMPLATES_DIR}/${filename}"
}
