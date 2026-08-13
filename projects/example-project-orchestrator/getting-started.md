# Getting Started with the Ralph Orchestrator Example Project

This folder is a **reference layout**, not something the CLI reads. A real
project lives in its volume root at
`~/.local/share/foundry/volumes/<project>/`.

1. **Inspect the configuration**
   - `foundry.json` sets `"agent": "ralph-orchestrator"`, which also selects
     the `foundry-agent:ralph-orchestrator` image.
   - `ralph.yml` configures Ralph Orchestrator's loop behavior.
   - `PROMPT.md` is the default task prompt file (`event_loop.prompt_file`).

2. **Build the image for this variant**
   ```sh
   foundry image build ralph-orchestrator
   ```

3. **Create the project and copy the files in**
   ```sh
   foundry init example-project-orchestrator
   cp -r overview.md PROMPT.md ralph.yml .ralph \
       ~/.local/share/foundry/volumes/example-project-orchestrator/
   $EDITOR ~/.local/share/foundry/volumes/example-project-orchestrator/foundry.json
   ```

4. **Start the agent**
   ```sh
   foundry up example-project-orchestrator
   foundry logs -f example-project-orchestrator
   ```

5. **After local edits**
   ```sh
   foundry up example-project-orchestrator
   ```
   There is no sync step: the volume root is mounted live, so edits to
   `.ralph/`, `ralph.yml` and `PROMPT.md` are visible inside the sandbox
   immediately. `up` only restarts what is not already running.
