# CLI Simplification: 58 subcommands → 13

Status: design, decide before Phase 1
Date: 2026-08-13
Depends on: [implementation plan](./2026-08-13-docker-sandbox-implementation-plan.md)

The Docker Sandboxes rework removes the *reasons* most of the current commands
exist. This document takes that to its conclusion: a project-centric CLI where
the common path is three verbs and nothing takes a `<vm>` argument.

---

## 1. Why the surface got big

Today's 58 subcommands across 7 domains are not gratuitous — each one exists
because Foundry manages four things that don't know about each other:

| Domain | Count | Exists because… |
|---|---|---|
| `vm` | 13 | Firecracker has no lifecycle CLI of its own |
| `agent` (+2 watchers) | 26 | the agent lives *inside* the VM, reachable only via SSH |
| `workspace` | 6 | files must be **copied into** the VM and re-synced when they change |
| `template` | 3 | images must be built from scratch locally |
| `network` | 3 | TAP devices and an IP pool are Foundry's to manage |
| `host` | 2 | firecracker/kernel/rootfs provisioning |
| `config` | 4 | — |

After the migration, four of those reasons evaporate:

- **`workspace` (6 commands) → 0.** The volume root *is* the workspace, live-
  mounted, "changes in either direction are instant with no sync process
  involved". `workspace sync` has nothing to sync. `workspace edit` is `$EDITOR`
  on a host path. There is no copy-in step to command.
- **`network` (3) → 0.** No TAP, no IP pool. Replaced by policy, which is
  generated from project config, not hand-managed.
- **`template` (3) → 1 (CI-only).** One Dockerfile; `sbx template save` covers
  ad-hoc snapshots.
- **`vm` vs `agent` split → gone.** A project, its box, and its agent are now
  1:1:1. Splitting them into two domains made users run two commands to
  express one intention.

And one ergonomic unlock: because the volume root is a real host directory,
**the current working directory identifies the project** — the same trick `sbx`
itself uses. Nearly every `<vm>` argument disappears.

---

## 2. Target surface

### The 90% path — three verbs

```console
$ foundry init pocetude       # scaffold volume + config + policy + box + repos
$ foundry up                  # box running, ports published, agent running, watchers live
$ foundry down
```

Run inside a project (or its volume root) and the name is inferred. Pass a name
explicitly from anywhere.

### Full surface

| Command | Does |
|---|---|
| `foundry init [name]` | Scaffold volume root, `foundry.json`, clone repos, apply policy rules, build/pull image, create box. Idempotent. |
| `foundry up [name]` | Start box → publish ports → start agent → start watchers → register hooks → mark-all. Everything the config says is on. |
| `foundry down [name]` | Stop watchers, agent, box. State persists. |
| `foundry status [name]` | One view: box state, agent + thread sessions, watcher health, published ports, active policy rules. No name = all projects. |
| `foundry logs [name] [-f] [--watcher]` | Host-side `tail` on the volume root. No exec, no SSH. |
| `foundry attach [name]` | tmux attach to the running agent. |
| `foundry shell [name] [cmd...]` | `sbx exec -it`, or `ssh <box>.sbx` with `--ssh`. |
| `foundry resume [name] <thread>` | Resume a thread session (kept: no other command expresses it). |
| `foundry rm [name] [--keep-volume]` | Remove the box. Volume root survives by default. |
| `foundry doctor [name] [--fix]` | Host prereqs (`sbx`, KVM, `kvm` group, login), policy matrix, port mappings, credentials, volume-root filesystem check. `--fix` applies what it can. |
| `foundry config [get\|set\|edit]` | Global and per-project config. |
| `foundry policy <allow\|deny\|ls\|check>` | Escape hatch over `sbx policy`, project-aware. |
| `foundry image <build\|push>` | Escape hatch; normally CI's job. |

**13 commands, 3 of them escape hatches.** The `vm`/`box`, `agent`, `workspace`,
`network`, `template`, and `host` domains all disappear as user-facing nouns.

---

## 3. Full mapping of the current 58

| Today | Becomes | Why |
|---|---|---|
| `vm create` | `foundry init` | fused with workspace + repo + policy setup |
| `vm start` | `foundry up` | plus ports, agent, watchers |
| `vm stop` | `foundry down` | |
| `vm restart` | `foundry up` after `down` | `up` is idempotent; a dedicated verb earns nothing |
| `vm destroy` | `foundry rm` | |
| `vm ssh` | `foundry shell` | |
| `vm list` | `foundry status` (no args) | |
| `vm status` | `foundry status` | |
| `vm ip` | **deleted** | no per-box IP; nothing needs one |
| `vm copy` | **deleted** | `cp` into the volume root on the host |
| `vm rename` | **deleted** | boxes are disposable; rename the volume dir and `init` |
| `vm snapshot` | `foundry image` / `sbx template save` | |
| `vm update` | **deleted** | rebuild the image, or `foundry shell -- apt upgrade` |
| `agent start/stop/restart` | `foundry up` / `down` | agent is not a separate lifecycle |
| `agent attach` | `foundry attach` | |
| `agent status` | `foundry status` | |
| `agent logs` | `foundry logs` | |
| `agent sessions` | `foundry status` | folded into the status view |
| `agent resume` | `foundry resume` | kept |
| `agent enable-autostart` | `foundry.json: autostart: true` | config-driven, applied by `up` |
| `agent disable-autostart` | same key | |
| `gh-watcher init` | `foundry init` | derived from config |
| `gh-watcher start` | `foundry up` | |
| `gh-watcher stop` | `foundry down` | |
| `gh-watcher status` | `foundry status` | |
| `gh-watcher logs` | `foundry logs --watcher` | |
| `gh-watcher mark-all` | automatic on `up` | already the default; `--no-mark-all` stays |
| `gh-watcher reset` | `foundry doctor --fix` | |
| `forgejo-watcher init` | `foundry init` | |
| `forgejo-watcher register-hooks` | automatic on `up` | already opt-out per AGENTS.md |
| `forgejo-watcher unregister-hooks` | automatic on `rm` | |
| `forgejo-watcher start/stop/status/logs/mark-all/reset` | as gh-watcher above | |
| `workspace init` | `foundry init` | |
| `workspace sync` | **deleted** | the mount *is* the sync |
| `workspace init-ralph` | `foundry init` | |
| `workspace edit` | **deleted** | `$EDITOR ~/.local/share/foundry/volumes/<p>/…` |
| `workspace info` | `foundry status` | |
| `workspace template` | `foundry init` scaffolds it | |
| `template list/build base/build golden` | `foundry image build` | one image, no base/golden split |
| `host setup` | `foundry doctor --fix` | |
| `host status` | `foundry doctor` | |
| `network init/status/cleanup` | **deleted** | replaced by `foundry policy` |
| `config get/set/edit/show` | `foundry config` (`show`→`get` with no key) | |

Deleted outright: **17**. Absorbed into `init`/`up`/`down`/`status`: **28**.

---

## 4. One config file per project

Four files today — `git-config.json`, `agents.json`, `gh-watcher.json`,
`forgejo-watcher.json` — become one `foundry.json` at the volume root. This is
what makes `init`/`up` able to do everything without flags:

```jsonc
{
  "name": "pocetude",
  "agent": "kimi-ralph",              // was: a CLI arg on every agent command
  "image": "ghcr.io/org/foundry-agent:kimi-ralph",
  "resources": { "cpus": 4, "memory": "8g" },
  "autostart": true,                  // was: enable-autostart command
  "repos": [
    { "url": "git@forge.example.com:org/api.git", "branch": "main" }
  ],
  "network": {
    "allow": ["forge.example.com:22"], // auto-derived from repos; editable
    "deny":  []
  },
  "watcher": {
    "kind": "forgejo",                // or "github", or absent
    "url": "https://forge.example.com",
    "token_file": "secrets/forge-token",
    "repos": ["org/api"],
    "port": 9101                      // static host port, stable across restarts
  }
}
```

`init` writes it; `up` reads it and reconciles reality to it. Every deleted
command is a line in this file instead.

---

## 5. Principles this locks in

1. **Verbs, not nouns.** Users express intent (`up`), not topology (`vm start`
   then `agent start` then `gh-watcher start`).
2. **`up` is idempotent reconciliation.** Run it any time; it makes reality
   match `foundry.json`. This is what lets `restart`, `init-ralph`, `sync`,
   `register-hooks`, and `mark-all` disappear as commands.
3. **cwd infers the project.** Explicit names still work everywhere.
4. **Config over flags.** Per AGENTS.md: opt-out, not opt-in. Anything in
   `foundry.json` happens automatically; every automatic behavior keeps a
   `--no-*` flag.
5. **Escape hatches stay** (`policy`, `image`, `shell`, and plain `sbx`), but
   they're not on the common path.
6. **One screen of `--help`.** If it doesn't fit, something is wrong.

---

## 6. Impact on the implementation plan

Phase 1's checklist item "`bin/foundry`: `box` domain (create/start/stop/…)"
is **superseded** — build the verb surface directly instead of porting the
`vm` domain and simplifying later. Concretely:

- [ ] Phase 1 builds `foundry init/up/down/status/shell/doctor` over
      `lib/sandbox.sh` + `lib/policy.sh`, not a `box` domain
- [ ] `lib/project.sh` (new, ~200 lines): `foundry.json` load/validate/reconcile,
      cwd→project inference. This is the new center of the CLI.
- [ ] Phase 3 wires `agent`/watcher logic *into* `up`/`down`/`status` rather
      than exposing it as commands
- [ ] Phase 6 adds: migrate the four per-project JSON files into `foundry.json`
      (`foundry config migrate`), and rewrite `docs/CLI-REFERENCE.md` around 13
      commands
- [ ] Deprecation: keep `vm`/`agent`/`workspace` domains for one release,
      each printing the new equivalent and then running it

Net effect on the estimate: `bin/foundry` shrinks from ~1050 lines to ~400, and
`lib/agent.sh` loses its entire command-dispatch surface (the watcher subcommand
trees alone are ~140 lines of `case` in `bin/foundry`).
