# Getting Started with the Example Project

This folder is a **reference layout**, not something the CLI reads. A real
project lives in its volume root at
`~/.local/share/foundry/volumes/<project>/`; copy what you want from here into
one.

1. **Inspect the configuration**
   - `foundry.json` is the whole project config: agent, repos to clone,
     resources, watcher settings and network exceptions. It replaces the old
     `git-config.json` + `agents.json` pair.
   - `.kimi/` holds Kimi-specific configuration and task prompts, used when the
     agent is `kimi-ralph`.
   - `.ralph/` and `.ralphrc` do the same for the Ralph agents.

2. **Create the project**
   ```sh
   foundry init example-project
   cp -r overview.md getting-started.md .kimi .ralph .ralphrc \
       ~/.local/share/foundry/volumes/example-project/
   $EDITOR ~/.local/share/foundry/volumes/example-project/foundry.json
   ```

3. **Add a git key**
   ```sh
   cd ~/.local/share/foundry/volumes/example-project/.ssh
   ssh-keygen -t ed25519 -f id_agent -C "foundry-agent" -N ""
   $EDITOR config      # uncomment and edit a block; add id_agent.pub to your forge
   ```
   There are no deploy-key files in this folder any more: keys are per project,
   created by you, and never generated behind your back.

4. **Bring it up**
   ```sh
   foundry up example-project
   ```
   The clone runs inside the sandbox, so a bad key or a blocked forge fails
   here — before any agent starts. Then look in `repos/` for `github-api/` and
   `gitlab-ui/`; the volume root is a normal host directory, so you can open
   them directly.

5. **Edit and extend**
   - Add Markdown context files to the volume root to shape agent behavior;
     they are visible at the same path inside the sandbox.
   - Update `.repos` in `foundry.json` when you add repositories, then run
     `foundry up` again — it clones what is missing and leaves the rest alone.
   - Replace `.kimi/` with your preferred prompt, plan or agent instructions.
