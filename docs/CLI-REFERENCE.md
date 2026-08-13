# Foundry CLI Reference

All commands run from the host system.

## Command Structure

```bash
foundry <command> [project] [options]
```

The project is inferred from the current working directory when omitted — run
from anywhere inside a project's volume root (or a directory containing a
`foundry.json`) and the name is resolved automatically.

## Global Options

```bash
-h, --help      Show help
-v, --version   Show version
--verbose       Enable verbose logs
--dry-run       Print intended actions without executing
```

## Lifecycle

```bash
foundry init <project> [--no-clone]
foundry up [project] [--no-agent]
foundry down [project]
foundry rm [project] [--purge-volume] [-y|--yes]
```

- `init` scaffolds the volume root, validates config, applies the network
  policy baseline plus this project's derived rules, creates and starts the
  sandbox, then clones declared repositories **inside the sandbox**.
- `up` is idempotent reconciliation: it makes reality match `foundry.json`.
  Start the sandbox, re-publish ports, clone anything missing, start the agent.
  Run it any time; there is no separate `restart`.
- `rm` removes the sandbox. The volume root — repos, agent memory, keys, logs —
  is kept unless you pass `--purge-volume` and confirm.

Port mappings do not survive a sandbox restart, which is why `up` re-publishes
them on every run.

## Inspection

```bash
foundry status [project]
foundry logs [project] [-f|--follow] [--watcher]
foundry attach [project]
foundry shell [project] [--ssh] [command...]
foundry doctor [project] [--fix]
```

- `status` with no project lists every project. With one, it shows the sandbox
  state, agent, cloned repositories and their branches, published ports, and
  the sandbox's active network rules.
- `logs` reads files directly from the volume root on the host — no exec, no
  SSH.
- `shell` uses `sbx exec` by default. `--ssh` connects over `ssh <box>.sbx`,
  which requires `sbx setup ssh` once (no port and no key are involved).
- `doctor` checks host prerequisites, the network policy matrix, `.ssh`
  permissions and key presence, and whether watcher ports are actually
  published. `--fix` applies the policy baseline and normalizes permissions.

## Policy

```bash
foundry policy baseline
foundry policy allow <resource> [project]
foundry policy deny <resource> [project]
foundry policy check <target> [project]
foundry policy ls [project]
```

`baseline` sets the `open` preset (full internet egress) and then denies every
private, loopback and link-local range. Sandboxes already block private space
by default; Foundry adds explicit denies so the posture survives a preset
change and cannot be widened by a kit.

Resources are hostnames, `host:port`, IP addresses, or CIDR ranges. Non-HTTP
TCP (git over SSH on port 22) needs an explicit `host:22` rule — `init` and
`up` derive these from the project's git remotes automatically. UDP and ICMP
are blocked at the network layer and cannot be allowed.

## Image

```bash
foundry image build [variant]     # ralph | ralph-orchestrator | kimi-ralph
foundry image push [variant]
```

Builds `docker/foundry-agent.Dockerfile`. The image carries binaries only: all
per-project state lives in the mounted volume root.

## Config

```bash
foundry config get <key>
foundry config set <key> <value>
foundry config edit
foundry config show
```

Global config keys are normalized to uppercase underscore form internally, for
example `default.cpus` -> `DEFAULT_CPUS`.

Per-project settings live in `<volume root>/foundry.json`. Every field is
optional:

```jsonc
{
  "name": "pocetude",
  "agent": "kimi-ralph",
  "image": "foundry-agent:kimi-ralph",
  "resources": { "cpus": 4, "memory": "8g" },
  "autostart": false,
  "repos": [
    { "url": "git@forge.example.com:org/api.git", "branch": "main", "dir": "api" }
  ],
  "network": {
    "allow": ["forge.example.com:22"],
    "deny": []
  },
  "watcher": {
    "kind": "forgejo",
    "port": 9101,
    "token_file": "secrets/forge-token"
  }
}
```

`network.allow` is derived from the project's git remotes and written back on
`init`, so every exception — especially any hole punched in the LAN denial — is
reviewable in a diff.

## Volume root layout

```
~/.local/share/foundry/volumes/<project>/
├── repos/          # git checkouts
├── .ssh/           # keys and config (user-managed, see below)
├── .ralph/         # prompts, plans, memories
├── .claude/ .codex/ .gemini/ .config/gh/
├── logs/           # agent and watcher logs
├── secrets/        # token files
├── foundry.json
└── AGENT.md
```

This directory is mounted into the sandbox at the same absolute path, and is
the agent's `HOME` there. Everything the agent writes to `~` persists on the
host automatically — there is no sync step.

## Git SSH keys (manual setup)

Foundry does not generate or manage SSH keys. Each project's `.ssh/config` is
seeded with commented examples on `init`; fill it in by hand:

```bash
ssh-keygen -t ed25519 -f ~/.local/share/foundry/volumes/<project>/.ssh/id_agent
$EDITOR ~/.local/share/foundry/volumes/<project>/.ssh/config
```

Add the public key to the git account or repository the agent should use — a
deploy key, or a dedicated agent account. Host SSH agent forwarding is *not*
used, because it would give the agent your own identity rather than its own.

The first clone runs inside the sandbox, so a wrong key or a blocked forge
fails there, before any agent starts.

## Deprecated commands

`vm`, `agent`, `workspace`, `template`, `host` and `network` are the
pre-sandbox Firecracker commands. They still work for one release and print a
deprecation notice. See `foundry <domain> help`.
