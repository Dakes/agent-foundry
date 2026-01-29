# Agent Instructions

## Context
- Read the Markdown files from `context/` (which mirror this project directory) before touching code.
- Keep notes in `memory/` for decisions, progress, and learnings.

## Repositories
- All source code lives under `repos/` and is populated according to `git-config.json`.
- The CLI generates SSH host aliases such as `github.com-github-api` to ensure each repo uses the right deploy key.

## Workflow
- When running `foundry vm create example-dev --project example-project`, the VM is seeded with these files exactly as shown here.
- Respect the design doc's separation between functional configs (`git-config.json`) and contextual docs (`.md` files).
