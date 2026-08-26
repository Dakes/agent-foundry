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
- [x] Port `templates/forgejo/` receiver, watcher and hook manager
- [x] Start/stop the watcher from `foundry up` / `foundry down`
- [x] Ship `fj` (forgejo-cli) in the agent image
- [x] Drop the "not implemented yet" warning and the doc banners
- [ ] End-to-end test against a real forge event (only the config path is
      covered by tests so far)
- [x] `mark-all` implemented, and a startup cutoff means a restart never acts
      on a backlog

### Autostart
- [ ] Honor `.autostart` in `foundry.json` via a systemd user unit. **The
      field is seeded into every new project and read by nothing**, so it
      currently promises something Foundry does not do - either implement it
      or drop it from `_project_seed_config`.
- [ ] `templates/systemd/` unit that runs `foundry up` for flagged projects

### Fleet
- [x] `claude-fleet` agent type, routed per request by the `fleet` keyword
- [x] Gate as a `Stop` / `SubagentStop` hook; failures return as work orders
- [x] Lane, protected-path and git guards; `fleet-land` as the only route to a
      commit
- [x] Editable role briefs and skills materialised into the volume root
- [ ] **Verify whether `PreToolUse` deny is honoured under
      `--dangerously-skip-permissions`.** `docs/FLEET.md` documents the layered
      fallback that holds either way, but layer 1 is unverified. A 20-minute
      spike: a hook that denies `Write`, a headless run as a non-root user, and
      see whether the file appears.
- [ ] End-to-end fleet run against a real forge event
- [ ] A worked JSON-gate example under `docs/` that a project can copy

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


## Language: where Python would earn its place

Bash is right for most of this and wrong for two parts. This is not a rewrite
plan — the shell code works and has real coverage — it is a list of the places
that have actually cost debugging time, and a rule for new code.

### Port these when they next need real work

- **`lib/project.sh` and `lib/policy.sh` — config and data.** Every read of
  `foundry.json` shells out to `jq`, a dozen subprocesses per command, with
  filters written as strings that nothing type-checks. Two shipped bugs came
  from exactly that: `policy_has_allow` matched a *filesystem* `**` rule
  against a network resource (so `doctor` reported "Open" on a default-deny
  host, and rule dedup could skip a real rule), and the derived-resource list
  silently omitted the bare host that DNS needs. Both are trivial to get right
  with parsed structures and a test that can assert on them.

- **`scripts/test-prompt-lib.sh` — the test harness.** 94 hand-rolled
  assertions. The suite has broken repeatedly on shell mechanics rather than on
  the code under test: `read` dropping a final line with no trailing newline, a
  sourced adapter's `set -e` killing the caller, a heredoc inside `|| { … }`
  failing to parse. `pytest` catches that class before it reaches a run.

### Keep in bash

- **`lib/sandbox.sh`** — a thin wrapper over `sbx`: argument arrays, exit
  codes, stderr passthrough. Python would add a subprocess layer and gain
  nothing.
- **`bin/foundry`** — argument dispatch.
- **Everything under `templates/`** — it runs *inside* the sandbox, where the
  only guarantee is a shell and the tools baked into the image.

### Rule for new code

Prefer Python when the work is mostly parsing, comparing or transforming
structured data, or when it needs tests with more than string matching. Prefer
bash when it is process orchestration, or when it runs inside a sandbox.

A hybrid reads worse than either pure option; put the typed language where the
typed data is and accept that.

## Future Enhancements

- [ ] Additional agents: add to `lib/agent-registry.sh` plus an install step in
      the Dockerfile
- [ ] Shared context directory conventions (`~/.local/share/foundry/shared/`)
- [ ] Snapshot/restore a configured sandbox as a reusable template
- [ ] Multi-host: run sandboxes on a remote docker host
