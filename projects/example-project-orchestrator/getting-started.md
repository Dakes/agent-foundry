# Getting Started with the Ralph Orchestrator Example Project

1. **Inspect the configuration files**
   - `agents.json` selects `mikeyobrien/ralph-orchestrator` as the Ralph variant for this image.
   - `ralph.yml` configures Ralph Orchestrator's loop behavior.
   - `PROMPT.md` is the default task prompt file (`event_loop.prompt_file`).

2. **Create and initialize a VM from this project**
   ```sh
   foundry vm create example-orchestrator-dev --project example-project-orchestrator
   ```

3. **Start the orchestrator agent**
   ```sh
   foundry agent start example-orchestrator-dev ralph-orchestrator
   foundry agent logs example-orchestrator-dev --follow
   ```

4. **Sync updates after local edits**
   ```sh
   foundry workspace sync example-orchestrator-dev example-project-orchestrator
   ```
   This syncs `.ralph/`, `ralph.yml`, `PROMPT.md`, and other top-level markdown docs.
