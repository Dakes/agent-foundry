#!/usr/bin/env bash
#
# Run an agent CLI with sbx's placeholder credentials removed.
#
# sbx exports ANTHROPIC_API_KEY=proxy-managed into every sandbox. It is a
# placeholder for a credential its own proxy injects, and it only injects for
# sandboxes it created for one of its built-in agents. Foundry's sandboxes are
# created as 'shell' - the image is Foundry's own - so nothing ever replaces
# the placeholder.
#
# An API key beats an interactive login in every one of these CLIs, so the
# placeholder wins over the account the user signed into, and the run dies with
# "Invalid API key · Fix external API key" - baffling to someone who never set
# a key and did log in.
#
# Only the placeholder is removed. A real key, set deliberately, still applies.
#
# Usage: run-agent.sh <binary> [args...]

set -uo pipefail

for _var in ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY OPENAI_API_KEY; do
    if [[ "${!_var:-}" == "proxy-managed" ]]; then
        unset "$_var"
    fi
done
unset _var

exec "$@"
