# Project Setup Guide

How to create and configure a Foundry project.

## Overview

A project is one directory on the host — the **volume root** — plus one
sandbox. The volume root is bind-mounted into the sandbox at the same absolute
path, so everything in it is a normal host file you can edit, grep and back up
directly.

```
~/.local/share/foundry/volumes/<project>/
├── foundry.json     # the whole project config
├── .ssh/            # git keys and config (you write these by hand)
├── repos/           # cloned inside the sandbox by init/up
├── logs/            # agent logs, tailed by 'foundry logs'
└── .foundry/        # generated start scripts
```

There is no `projects/` folder, no `git-config.json` and no `agents.json` any
more: one `foundry.json` replaces all three.

## Step 1: Create the project

```bash
foundry init my-project
```

This scaffolds the volume root, seeds `foundry.json` and `.ssh/config`, applies
the network policy baseline plus any rules your remotes need, creates the
sandbox, and clones the declared repos inside it.

On a first run you will have no repos declared yet, so:

```bash
$EDITOR ~/.local/share/foundry/volumes/my-project/foundry.json
```

## Step 2: Configure `foundry.json`

```json
{
  "name": "my-project",
  "agent": "claude",
  "autostart": false,
  "repos": [
    {
      "url": "git@github.com:myorg/backend.git",
      "branch": "main",
      "dir": "backend"
    },
    {
      "url": "https://forge.example.com:3000/myorg/frontend.git"
    }
  ],
  "resources": {
    "cpus": 4,
    "memory": "8g"
  },
  "network": {
    "allow": [],
    "deny": []
  }
}
```

**Fields** — all optional except what you actually use:

- `agent` — `claude`, `gemini`, `codex`, `ralph`, `ralph-orchestrator`,
  `kimi-ralph`. Defaults to `claude`. At most one agent per project.
- `image` — override the image; otherwise derived from `agent`
  (`foundry-agent:base` for interactive agents).
- `repos[].url` — any git URL. `branch` and `dir` are optional; `dir` defaults
  to the repo name.
- `resources.cpus` / `resources.memory` — memory takes a unit (`8g`, `4096m`);
  a bare number is read as MiB. Empty means "let the sandbox decide".
- `network.allow` — rules derived from your remotes are written back here by
  `init`, so every exception is visible in a diff. You can add your own.
- `watcher.receiver_port` — the port **the forge POSTs webhooks to**, not a
  port on the forge. Published as `0.0.0.0:<port>:<port>` so the forge can
  reach into the sandbox. Must be **1024 or above**: binding a privileged port
  needs daemon privileges the sandbox runtime does not have, and it surfaces as
  a 403 from the port mapper.
- `watcher.kind` / `watcher.token_file` — forge watcher
  config. **Not yet ported to the sandbox transport**; the port is published
  but nothing listens on it.

Apply any change with `foundry up` — it reconciles rather than recreating.

## Step 3: Set up git keys

Foundry never reads `~/.ssh`. Keys live in the project's own `.ssh/`, and you
create them by hand — that way an agent identity separate from your personal
one is just a different key, and nothing is generated behind your back.

```bash
cd ~/.local/share/foundry/volumes/my-project/.ssh
ssh-keygen -t ed25519 -f id_agent -C "foundry-agent" -N ""
```

Then add the **public** key to your forge:

- GitHub: repo → Settings → Deploy keys (or a dedicated account's SSH keys)
- Forgejo/Gitea: repo → Settings → Deploy keys
- GitLab: Settings → Repository → Deploy keys

`init` seeds `.ssh/config` with commented blocks to fill in — a plain host, a
self-hosted forge on a non-standard port, and the separate-agent-account
pattern:

```
Host github.com
    IdentityFile ~/.ssh/id_agent
    IdentitiesOnly yes

# A separate identity for the agent, so it does not act as you:
Host github-agent
    HostName github.com
    IdentityFile ~/.ssh/id_agent
    IdentitiesOnly yes
```

With the last form, write remotes as `git@github-agent:myorg/repo.git`.

Permissions are normalized for you (`.ssh` 700, files 600) on every `init`,
`up` and `doctor --fix`.

## Step 4: Bring it up

```bash
foundry up my-project
```

The clone runs **inside the sandbox**, on purpose: it is the first real test of
your key and of the network policy, and it happens before any agent starts. If
it fails, the error names the three causes worth checking — no key in `.ssh`,
the forge blocked by policy, or a wrong branch.

Verify the whole picture with:

```bash
foundry doctor my-project
foundry status my-project
```

## Which way does the traffic go?

Two directions, and only one of them needs a port published:

| | Direction | Configured by |
|---|---|---|
| **Webhook** | forge → sandbox | `watcher.receiver_port` — published to the host |
| **Forge API** (posting comments, reading PRs) | sandbox → forge | `watcher.instance_url` — outbound, nothing published |

So `receiver_port` is a port on *your* machine that the forge dials into. Set
the webhook in the forge to `http://<your-host>:<receiver_port>/`. It never has
to be 80 — a webhook URL carries its own port — and 80 usually cannot be bound
anyway.

## Network access to your forge

Egress is open to the internet and closed to the LAN and the host. A forge on
a public URL works with no extra setup. A forge reachable only on your LAN is
**deliberately blocked** — that is the point of the posture.

Git over SSH is non-HTTP TCP and always needs an explicit rule; `init` derives
these from your remotes automatically. Check one with:

```bash
foundry policy check forge.example.com:22
```

## Context files

Anything you drop in the volume root is visible to the agent at the same path
inside the sandbox — `overview.md`, `architecture.md`, coding standards, and
the agent's own dotfolder (`.claude/`, `.ralph/`, `.kimi/`).

For context that should be available to *every* project, use the shared
directory, which is mounted read-only into every sandbox:

```
~/.local/share/foundry/shared/
```
