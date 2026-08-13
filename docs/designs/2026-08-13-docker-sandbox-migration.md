# Concept: Migrating Agent Foundry from Firecracker to Docker Sandboxes

Status: concept / not implemented
Date: 2026-08-13

Full replacement of the Firecracker VM layer with Docker Sandboxes (`sbx`).
No dual backend. Firecracker, TAP networking, ext4 image building, and the
host-setup scripts are deleted, not abstracted.

---

## 1. The mount question (answered)

**Multiple mounts: yes.** `sbx create <agent> PATH [PATH...]` and
`sbx run <agent> [PATH...]` take an arbitrary number of workspace paths.
Append `:ro` to any of them for read-only. Example from Docker's docs:

```console
$ sbx run claude . /path/to/docs:ro
```

**But there is one hard constraint that shapes the whole design:**

> "Your workspace is mounted at the same absolute path as on your host."
> — [Architecture › Workspace mounting](https://docs.docker.com/ai/sandboxes/architecture/)

There is no `-v host:container` remapping. You cannot mount
`~/foundry-volumes/pocetude/.claude` to `/root/.claude`. Whatever the host path
is, that is the path inside the sandbox. Mounts are also fixed at **creation
time** — there is no `sbx mount` command to add one to a live sandbox
(`sbx cp` exists for one-off file copies).

That kills the naive "mount a config dir onto the agent's dotfile location"
idea, but it does **not** kill your volume-root model — it makes it the only
sane model, and it makes the layout requirements explicit.

### 1.1 Consequence: the volume root must live at the path the agent expects

Since host path == sandbox path, we pick the host path to *be* the agent's home
directory inside the sandbox. Two workable options:

**Option A — mirror `/root` (recommended).** The sandbox agent runs as a user
with home `/root` (today's Foundry convention). Nothing stops us from placing
the host volume root anywhere and telling the agent, via env/config, where its
home is. But agents hardcode a lot (`~/.claude`, `~/.config/gh`, `~/.ssh`), so
the cleanest trick is: mount one directory per project and set `HOME` inside
the sandbox to that mounted path.

```
~/.local/share/foundry/volumes/pocetude/          <- single mount, RW
├── repos/                 # git checkouts
├── .claude/               # Claude Code config + history
├── .codex/  .gemini/
├── .ssh/                  # keys, known_hosts
├── .config/gh/            # gh CLI auth
├── .ralph/                # prompts, fix_plan, memories
├── logs/
└── AGENT.md PROMPT.md ...
```

Inside the sandbox this appears at the identical path, and the session sets
`HOME=/home/<user>/.local/share/foundry/volumes/pocetude`. Everything an agent
writes to `~` lands on the host filesystem automatically. **This is exactly the
"agent memory syncs back to the host" property you wanted — for free, with no
sync process** ("changes in either direction are instant with no sync process
involved").

**Option B — mount several paths.** e.g. project repo at its real path plus a
shared read-only `~/.local/share/foundry/common:ro` for house prompts/skills.
This composes with Option A: one RW volume root per project + N shared RO
mounts for org-wide context.

The recommended shape is **A + one RO shared mount**:

```console
$ sbx create shell \
    ~/.local/share/foundry/volumes/pocetude \
    ~/.local/share/foundry/shared:ro
```

### 1.2 Consequence: no more baking, no more golden image

Because `HOME` is a host directory, per-project state (auth tokens, agent
history, memories, skills, prompt files) leaves the image entirely. The image
only needs *binaries*. That deletes `build-golden.sh` (537 lines),
`build-ubuntu-base.sh` (273), `prepare-kernel.sh` (202) and the whole
snapshot/template layer in `lib/template.sh`.

### 1.3 Bonus mechanisms Foundry no longer has to build

- `sbx skills import` + a shared skills store mounted RW across all sandboxes —
  this is `templates/workspace` skill distribution, done for us. (`--no-share-skills` to opt out.)
- `sbx template save` snapshots a running sandbox to a reusable image —
  replaces `vm_snapshot`.
- `sbx secret set <service>` keeps tokens in the host keychain and injects them
  as HTTP headers **at the host proxy**; the raw value never enters the VM.
  Strictly better than today's `token_file` on a VM disk.
- SSH agent forwarding: `SSH_AUTH_SOCK` is forwarded in, private keys stay on
  the host. Removes `_generate_vm_ssh_key()` and the per-VM keypair lifecycle.

---

## 2. What Foundry becomes

Foundry stops being a hypervisor manager and becomes an **agent-project
orchestrator**: volume-root layout, project config, autonomous-agent loops,
watchers, and lifecycle glue over `sbx`.

### 2.1 Module map

| Today | After |
|---|---|
| `lib/vm.sh` (1219) | `lib/sandbox.sh` (~250) — thin wrapper over `sbx create/run/exec/stop/rm/ls --json` |
| `lib/network.sh` (478) | **deleted**; replaced by `lib/policy.sh` (~120) wrapping `sbx policy` / `sbx ports` |
| `lib/registry.sh` (583) | shrinks to ~150 — `sbx ls --json` is the source of truth for sandbox state; Foundry only stores project↔volume↔sandbox mapping |
| `lib/template.sh` (188) | **deleted**; `sbx template` + a Dockerfile |
| `scripts/setup-host.sh`, `install-firecracker.sh`, `prepare-kernel.sh`, `setup-network.sh`, `build-golden.sh`, `build-ubuntu-base.sh` (~1800) | **deleted**; replaced by `apt-get install docker-sbx` + `docker/foundry-agent.Dockerfile` |
| `lib/workspace.sh` (1266) | shrinks substantially — workspace *is* the volume root; no more copy-into-VM |
| `lib/agent.sh` (2634) | mostly survives; `_ssh_cmd`/`_scp_to_vm_path` collapse to `sbx exec` / plain `cp` (the volume root is on the host!) |

Estimated net deletion: **~4,000 lines**, and the entire root/`doas` requirement.
`sbx` runs unprivileged (user in the `kvm` group), so `_require_root()` and
`resolve_host_home()`'s sudo gymnastics largely go away.

### 2.2 CLI surface

Keep the command names; swap the implementation. Rename `vm` → `box` with `vm`
kept as a deprecated alias for one release.

```
foundry box create <name> [--project <path>] [--template <image>] [--cpus N] [--memory 8g]
foundry box start|stop|restart|destroy <name>
foundry box exec <name> [cmd...]        # was: vm ssh
foundry box list|status <name>
foundry box publish <name> <port-spec>  # was: implicit VM IP
foundry box snapshot <name> <tag>       # sbx template save
```

`foundry box ip` disappears — see §4.

`foundry agent *` is unchanged externally. Internally every `_ssh_cmd` becomes
`sbx exec -u root <box> …`, and every `_scp_to_vm_path` becomes a host-side
`cp` into the volume root.

### 2.3 The image

One Dockerfile replaces the golden-image pipeline:

```dockerfile
FROM docker/sandbox-base:latest        # or the agent-specific default
RUN install node, python, gh, ripgrep, tmux …
RUN npm i -g @anthropic-ai/claude-code @google/gemini-cli @openai/codex
RUN install exactly one ralph variant per tag
```

Built into three tags — `foundry/agent:ralph`, `:ralph-orchestrator`,
`:kimi-ralph` — pushed to a registry, selected with `sbx create -t`.
`config/packages.txt` becomes a build arg. Per-project extras that don't
warrant an image become **kits** (declarative YAML applied at creation).

---

## 3. Autonomous / background operation

Your instinct is right — this is a systemd problem, not an architecture problem.

- Sandboxes **persist**: "You can stop and restart without recreating the VM,
  preserving installed packages and Docker images." State survives `sbx stop`;
  only `sbx rm` destroys it.
- `sbx create` / `sbx run -d` are non-interactive.
- `sbx exec -d <box> <cmd>` runs a command detached inside the box.

So `agent_enable_autostart` becomes a generated user unit:

```ini
# ~/.config/systemd/user/foundry-agent@.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sbx run -d --name %i
ExecStart=/usr/bin/foundry agent start %i
ExecStop=/usr/bin/sbx stop %i
```

plus `foundry-sbx-daemon.service` ordering against `sbx daemon`. Sessions stay
in tmux *inside* the box exactly as today, so `agent attach` becomes
`sbx exec -it <box> tmux attach`. `agent logs` becomes `tail -f` on the host —
the logs are in the mounted volume root now, no SSH needed. That's a
simplification, not a workaround.

---

## 4. The one genuinely hard part: networking

This is where the migration is not a straight win, and it needs a deliberate
decision. Docker Sandboxes' network model is the opposite of Foundry's:

| | Firecracker (today) | Sandboxes |
|---|---|---|
| Address | dedicated routable IP `172.16.0.X` | none; no inbound identity |
| Egress | unrestricted NAT | **deny-by-default**, HTTP/HTTPS via host proxy |
| Raw TCP/UDP/ICMP | free | **blocked** unless a `connect:tcp`/`connect:udp` policy rule allows it |
| Inbound | any port, from anywhere | `sbx ports --publish [HOST_IP:]HOST_PORT:BOX_PORT`, host-side, **not persisted across restart** |
| Box↔box | direct | not possible |

Implications, and how to handle each:

1. **No per-VM IP.** `vm_ip`, the IP pool, `next_ip`, and the `webhook_url`
   auto-derivation in the Forgejo/GitHub watchers all lose their basis.
   Replacement: publish the watcher port explicitly and derive `webhook_url`
   from `<host-ip>:<published-port>`. Since ports default to *loopback* when
   `HOST_IP` is omitted, watchers must publish with an explicit bind:
   `sbx ports <box> --publish 0.0.0.0:9101:9101`. Foundry allocates the host
   port from a pool (a much smaller version of `lib/network.sh`).
2. **Port publishing doesn't survive a restart.** The `foundry box start` path
   must re-apply published ports from project config on every start. This is
   config-driven and matches AGENTS.md's "one command to activate" rule —
   but it *must* be implemented, or watchers silently go deaf after a restart.
   Sanity-check it in `agent gh-watcher status`.
3. **Egress allowlist.** Every host the agent needs — the model API, GitHub,
   npm, PyPI, the self-hosted Forgejo — needs a `sbx policy allow network`
   rule. Foundry should generate these from project config at create time
   (`--deny-network` at create, `sbx policy allow` per project). This is real
   new work, but it is also **a capability Foundry does not have today** and
   the main security upgrade of the migration.
4. **Git over SSH still works**, via forwarded `SSH_AUTH_SOCK` — but port 22 is
   raw TCP, so it needs an explicit rule (`sbx policy allow network
   git.example.com:22`). Document this loudly; the failure mode is a hang.
5. **Sandboxes cannot talk to each other.** If any orchestrator/worker topology
   is planned (`example-project-orchestrator` suggests it), it must route
   through the host, not box-to-box.

Verdict: solvable, but this is where the migration's engineering risk actually
lives. Everything else is deletion.

---

## 5. Other things that change

- **Host requirements:** Ubuntu 24.04+, x86_64 or aarch64, KVM enabled, user in
  `kvm` group. Nested virtualization *is* supported, so cloud VMs work. macOS
  (Apple silicon) and Windows 11 become supported hosts for free — Foundry
  becomes cross-platform, which Firecracker could never deliver.
- **Docker login required.** `sbx login` is mandatory. CLI is free for
  commercial use; only org governance is paid. This is a new hard dependency on
  a vendor account — worth stating in the README.
- **Don't put volume roots on NFS/SMB/cloud-synced dirs** — every read crosses
  the virtiofs passthrough. Relevant since we're deliberately putting `HOME` on
  a mount. Enforce a sanity check at `box create` (per AGENTS.md).
- **`--clone` mode** (repo mounted RO, agent works on a private clone exposed
  as a `sandbox-<name>` host git remote) is a strong fit for the watcher
  workflow, where an agent responds to an issue and you want to review before
  it touches your tree. Worth offering as `foundry box create --clone`.
- **Perf:** virtiofs caching is on by default; expect some overhead vs. an ext4
  root disk. Keep `repos/` on the mount anyway — correctness of the
  memory-sync property beats a few percent.

---

## 6. Migration phases

1. **Spike** — prove out, by hand, on one project: volume root with `HOME`
   redirect, `sbx create shell`, ralph loop running detached, memories landing
   on the host, egress allowlist for the model API. Confirms §1.1 and §4.
2. **`lib/sandbox.sh` + `lib/policy.sh`** — the new lifecycle core; `foundry
   box` commands green.
3. **Volume-root layout + `foundry project init`** — layout generator, migration
   command that rsyncs an existing VM's `/root` into a new volume root.
4. **Rewire `lib/agent.sh`** — `_ssh_cmd` → `sbx exec`, `_scp_to_vm_path` → host
   `cp`; agent start/stop/attach/logs/sessions.
5. **Watchers** — port publishing pool, `webhook_url` derivation, re-publish on
   start, egress rules for the forge. Highest-risk phase.
6. **Systemd units** for autostart.
7. **Delete** `lib/vm.sh`, `lib/network.sh`, `lib/template.sh`, all
   Firecracker/kernel/rootfs scripts; rewrite `install.sh` setup path,
   `docs/ARCHITECTURE.md`, `docs/*-WATCHER.md`, README.

Phases 1 and 5 are the ones that decide whether this is a good idea. Everything
after phase 4 is subtraction.

---

## 7. Open questions to settle before coding

1. `HOME` redirect vs. running the agent as a user whose home genuinely is the
   mount — does the chosen sandbox image let us set the home directory cleanly,
   or do we need a kit / custom entrypoint? (Phase 1 answers this.)
2. Does `sbx exec -u root` + `HOME=` reliably reach the same tmux session as the
   interactive `sbx run` attach path, or do we always own the tmux server
   ourselves via `exec -d`?
3. Do we keep per-project ralph-variant images, or one image with all three and
   select at runtime? (Volume-root state makes the second much cheaper now.)
4. Watcher host-port allocation: static per project in config, or pooled with a
   registry? Config-driven per AGENTS.md argues for static.

---

## Sources

- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) ·
  [Architecture](https://docs.docker.com/ai/sandboxes/architecture/) ·
  [Security model](https://docs.docker.com/ai/sandboxes/security/) ·
  [Default posture](https://docs.docker.com/ai/sandboxes/security/defaults/) ·
  [Credentials](https://docs.docker.com/ai/sandboxes/security/credentials/) ·
  [Customize](https://docs.docker.com/ai/sandboxes/customize/) ·
  [Get started (prereqs)](https://docs.docker.com/ai/sandboxes/get-started/)
- CLI: [`sbx`](https://docs.docker.com/reference/cli/sbx/) ·
  [`run`](https://docs.docker.com/reference/cli/sbx/run/) ·
  [`create shell`](https://docs.docker.com/reference/cli/sbx/create/shell/) ·
  [`exec`](https://docs.docker.com/reference/cli/sbx/exec/) ·
  [`ports`](https://docs.docker.com/reference/cli/sbx/ports/) ·
  [`ls`](https://docs.docker.com/reference/cli/sbx/ls/) ·
  [`stop`](https://docs.docker.com/reference/cli/sbx/stop/) ·
  [`template`](https://docs.docker.com/reference/cli/sbx/template/) ·
  [`secret`](https://docs.docker.com/reference/cli/sbx/secret/) ·
  [`skills`](https://docs.docker.com/reference/cli/sbx/skills/)
