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
foundry policy baseline [--reset]
foundry policy allow <resource> [project]
foundry policy deny <resource> [project]
foundry policy check <target> [project]
foundry policy ls [project]
```

`baseline` initializes the global policy as `allow-all` (full internet egress)
and then denies the LAN ranges worth denying: `192.168.0.0/16`, where home and
small-office networks live, and `169.254.0.0/16`, which carries the cloud
metadata endpoint. Set `FOUNDRY_PRIVATE_RANGES` in `config.conf` for a LAN on
a different range.

The rest of RFC1918 is deliberately left reachable. Container networking lives
there — `172.17.0.0/16` on a default Docker install — and denying the range a
sandbox's own DNS resolver sits in disables name resolution for every sandbox
on the host. No allow rule can undo that: sbx resolves a conflict in favour of
the deny. Sandboxes already
block private space by default; Foundry adds explicit denies so the posture
survives a preset change and cannot be widened by a kit. The result: the open
internet is reachable — including a self-hosted forge on a public URL — while
the LAN and the host are not.

The global preset can only be set once (`sbx policy init`). On a host that is
already initialized, `baseline` keeps the existing preset and only reconciles
the deny rules; rules it has already added are not added twice. `--reset` wipes
the whole sbx policy store first and is never implied, because it stops every
running sandbox.

Note that these denies apply to *egress*. A service the agent runs on its own
loopback inside the sandbox is unaffected, so denying `127.0.0.0/8` does not
break a dev server started in the box.

Resources are hostnames, `host:port`, IP addresses, or CIDR ranges. Non-HTTP
TCP (git over SSH on port 22) needs an explicit `host:22` rule — `init` and
`up` derive these from the project's git remotes automatically. UDP and ICMP
are blocked at the network layer and cannot be allowed.

## Image

```bash
foundry image build                     # -> foundry-agent:base
foundry image build ralph               # -> foundry-agent:ralph
foundry image build ralph-orchestrator
foundry image build kimi-ralph
foundry image push [tag]
```

Builds `docker/foundry-agent.Dockerfile`. The image carries binaries only: all
per-project state lives in the mounted volume root.

`:base` carries the interactive CLIs (claude, gemini, codex) and is what every
interactive project uses; a variant argument adds one autonomous Ralph runner
and tags the image after it. Projects pick their image implicitly from
`.agent`, or explicitly via `.image` in `foundry.json`.

Two things this command does that are easy to miss:

- The image's `agent` user is created with **your** UID/GID, so files the
  sandbox writes into the volume root stay editable on the host.
- After building, the image is imported into the sandbox runtime's own image
  store (`docker save` → `sbx template load`). Without that, `sbx create -t`
  tries to *pull* the tag and fails with `403 Forbidden`, because a locally
  built image is invisible to it.

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

## Removed commands

`vm`, `agent`, `workspace`, `template`, `host` and `network` were the
pre-sandbox Firecracker commands. They are gone; running one prints where its
job moved to:

| Removed | Replacement |
|---|---|
| `vm` | `init` / `up` / `down` / `status` / `shell` / `rm` |
| `agent` | `up` / `down` / `attach` / `logs` |
| `workspace` | none needed — the volume root *is* the workspace |
| `template` | `image build` |
| `host` | `doctor --fix` |
| `network` | `policy` |
