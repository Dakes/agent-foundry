# Example Project

This directory shows how to declare a reusable workspace for Agent Foundry following the refactor from January 22, 2025. Everything that the CLI needs to configure a VM lives under `projects/example-project/`:

- `git-config.json` defines each repository and the deploy key that Gatekeeper should copy.
- Markdown files provide the project context agents read from `context/` on the VM.
- The `.ralph/` tree demonstrates how Ralph users can ship prompts, plans, and agent guidance alongside traditional context.
- The deploy key files illustrate the per-project SSH workflow that keeps private keys out of the golden template.

Copy this folder to create new workspaces or edit it to mirror your own infrastructure; the `foundry vm create ... --project example-project` command replays it with no surprises.
