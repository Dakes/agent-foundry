# Agent Foundry - Implementation TODO

## Project Status

🚧 **Docker Sandbox migration** — the core is implemented; watchers are not.

The previous roadmap tracked the Firecracker backend (host setup, golden image
pipeline, TAP networking, VM lifecycle, SSH transport). That backend and its
tasks were removed with the migration; why and how now live in
`docs/ARCHITECTURE.md`, `docs/VISION.md` and `docs/CLI-REFERENCE.md`, which are
maintained against the code.

## Done

- [x] `lib/sandbox.sh` — the `sbx` wrapper (create/start/stop/rm/exec/publish/
      snapshot), image import into the sandbox runtime
- [x] `lib/policy.sh` — baseline (allow-all + private-range denies), rule
      derivation from git remotes, policy matrix, idempotent re-application
- [x] `lib/project.sh` — volume root scaffold, `foundry.json`, `.ssh` seeding
      and permissions, in-box cloning
- [x] `lib/agent-sandbox.sh` — agent sessions over `sbx exec` instead of SSH
- [x] `lib/commands.sh` — the verb layer (init, up, down, status, logs, attach,
      shell, rm, doctor, policy, image, config)
- [x] `docker/foundry-agent.Dockerfile` — replaces the golden-image pipeline;
      agent user matches the host UID/GID so mounted files stay editable
- [x] Remove the Firecracker backend (libs, scripts, docs, CLI domains)

## Next

### Watchers on the sandbox transport
- [ ] Port `templates/gh-watcher/` to run inside a sandbox (no SSH, no VM IP)
- [ ] Port `templates/forgejo/` receiver + hook manager
- [ ] Derive the webhook URL from the published port instead of the VM IP
- [ ] Start/stop the watcher from `foundry up` / `foundry down`
- [ ] Ship `fj` (forgejo-cli) in the agent image — the golden image used to
      provide it
- [ ] Drop the "not implemented yet" warning from `cmd_up` and the banners from
      the watcher docs

### Autostart
- [ ] Honor `.autostart` in `foundry.json` via a systemd user unit
- [ ] `templates/systemd/` unit that runs `foundry up` for flagged projects

### Testing
- [ ] Unit tests for policy derivation and `foundry.json` access
- [ ] Integration test: `init` → `up` → `status` → `down` → `rm` on a scratch
      project
- [ ] CI that builds the agent image

### Polish
- [ ] `foundry status` reports a sandbox as stopped right after a successful
      `exec` (sbx updates status lazily)
- [ ] Per-project `sbx` policy scoping — rules are global today except where a
      sandbox is passed explicitly
- [ ] Revisit `projects/example-*` — they still use the old `git-config.json` /
      `agents.json` layout, replaced by `foundry.json`

## Future Enhancements

- [ ] Additional agents: add to `lib/agent-registry.sh` plus an install step in
      the Dockerfile
- [ ] Shared context directory conventions (`~/.local/share/foundry/shared/`)
- [ ] Snapshot/restore a configured sandbox as a reusable template
- [ ] Multi-host: run sandboxes on a remote docker host
