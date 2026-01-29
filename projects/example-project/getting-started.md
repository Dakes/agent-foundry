# Getting Started with the Example Project

1. **Inspect the configuration files**
   - `git-config.json` lists the repositories Agent Foundry will clone and the deploy key each repo uses.
   - `.ralph/` contains prompt, plan, and agent instructions that are automatically copied into each workspace if you run Ralph.

2. **Generate a VM**
   ```sh
   foundry vm create example-dev --project example-project
   ```
   The CLI validates the project folder, copies `overview.md` + `getting-started.md` into `context/`, copies `.ralph/`, and injects `deploy-key-example` into `/root/.ssh/` along with the SSH config described in the design doc.

3. **Verify repositories**
   - Once the VM boots, look inside `/work/example-dev/repos/` for `github-api/` and `gitlab-ui/`.
   - Both clones use host aliases (`github.com-github-api`, `gitlab.com-gitlab-ui`) so each repo signs in with the deploy key declared in this folder.

4. **Edit and extend**
   - Add new Markdown context files (outside `.ralph/`) to shape agent behavior; they appear under `context/` in the workspace.
   - Update `git-config.json` whenever you add repositories or branches so the CLI knows what to clone.
   - Replace `.ralph/` contents with your preferred Ralph prompt, plan, or agent instructions.
