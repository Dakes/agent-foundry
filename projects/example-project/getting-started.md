# Getting Started with the Example Project

1. **Inspect the configuration files**
   - `git-config.json` lists the repositories Agent Foundry will clone and the deploy key each repo uses.
   - `agents.json` must include at most one autonomous agent (`frankbria/ralph-claude-code`, `mikeyobrien/ralph-orchestrator`, or `kimi-cli`).
   - `.kimi/` contains Kimi-specific configuration and task prompts that are automatically copied into each workspace if you run `kimi-ralph`.

2. **Generate a VM**
   ```sh
   foundry vm create example-dev --project example-project
   ```
   The CLI validates the project folder, copies `overview.md` + `getting-started.md` into `context/`, copies `.kimi/`, and injects `deploy-key-example` into `/root/.ssh/` along with the SSH config described in the design doc.

3. **Verify repositories**
   - Once the VM boots, look inside `/work/example-dev/repos/` for `github-api/` and `gitlab-ui/`.
   - Both clones use host aliases (`github.com-github-api`, `gitlab.com-gitlab-ui`) so each repo signs in with the deploy key declared in this folder.

4. **Edit and extend**
   - Add new Markdown context files (outside `.kimi/`) to shape agent behavior; they appear under `context/` in the workspace.
   - Update `git-config.json` whenever you add repositories or branches so the CLI knows what to clone.
   - Replace `.kimi/` contents with your preferred Kimi prompt, plan, or agent instructions.
