# Implementation Plan: Firecracker → Docker Sandboxes

Status: ready to implement
Date: 2026-08-13
Concept: [2026-08-13-docker-sandbox-migration.md](./2026-08-13-docker-sandbox-migration.md)

Full replacement. No dual backend, no compatibility shim beyond one release of
deprecated command aliases. This document is the work order: every phase has a
definition of done and a checklist.

---

## 0. Decisions locked in

| Question | Decision |
|---|---|
| Per-box IP address | **Dropped.** Inspection is `sbx exec` / `ssh <box>.sbx` / `sbx tui`. Nothing else needed it except watcher webhooks (§4). |
| Network posture | **Open internet, closed LAN.** See §1. |
| Box home directory | Host volume root, mounted at its own absolute path, `HOME` pointed at it. |
| Image strategy | One Dockerfile per ralph variant, pushed to a registry, selected with `sbx create -t`. |
| Background/autostart | systemd **user** units wrapping `sbx run -d` + `foundry agent start`. |
| Registry ownership | `sbx ls --json` owns box state. Foundry's registry keeps only project↔volume↔box mapping and agent/session state. |

### Inspecting and entering a box (replaces `foundry vm ssh`)

Three mechanisms, all first-class:

```console
$ sbx exec -it <box> bash              # shell inside, no SSH involved
$ sbx setup ssh && ssh <box>.sbx       # real SSH; no port, no key, ProxyCommand-based
$ sbx tui                              # dashboard: status, resources, live network requests
$ sbx ls --json                        # machine-readable state
```

`sbx setup ssh` writes a managed block to `~/.ssh/config` using
`ProxyCommand sbx ssh proxy %n`, so `ssh <box>.sbx` needs no listening port and
no keypair. It also supports normal SSH local port forwarding. `foundry box
exec` maps to the first form; `foundry box ssh` to the second.

---

## 1. Network policy design (the part you actually care about)

Docker Sandboxes' defaults already match the goal, and they're enforced at the
network layer, not by the agent:

> "Sandboxes cannot communicate with each other and cannot reach your host's
> localhost." … "Traffic to private IP ranges, loopback, and link-local
> addresses is also blocked." … "Raw TCP connections, UDP, and ICMP are blocked
> at the network layer."
> — [Network isolation](https://docs.docker.com/ai/sandboxes/security/isolation/)

So the LAN and the host are closed by construction. What we choose is how much
of the *internet* to open.

### Foundry's stance: `Open` preset + explicit private-range denies + per-project allows

The `Open` preset is "equivalent to adding a wildcard allow rule with
`sbx policy allow network "**"`". Deny rules always narrow and always win, and
local deny rules survive even under org governance. So:

```bash
sbx policy set-default open            # full internet, per your requirement
# belt-and-braces: private space stays denied even if a preset/kit widens it
sbx policy deny network 10.0.0.0/8
sbx policy deny network 172.16.0.0/12
sbx policy deny network 192.168.0.0/16
sbx policy deny network 169.254.0.0/16
sbx policy deny network 127.0.0.0/8
sbx policy deny network fc00::/7
sbx policy deny network fe80::/10
```

`foundry host setup` applies this set as the **Foundry baseline** and prints it.
The denies are redundant with the documented default, deliberately: they make
the posture explicit, survive a `sbx policy reset` to `Open`, and protect
against a kit adding a broad allow.

### Non-HTTP: git over SSH

UDP and ICMP can never be unblocked. Raw TCP **can**, per destination:

```bash
sbx policy allow network "git.example.com:22"
```

Foundry generates these from project config. Every project's git remotes are
parsed at `box create` and turned into rules — this is the AGENTS.md
"config-driven" rule applied to the network layer.

### A self-hosted forge on your LAN

This is the one case where the two goals collide: the LAN is denied, but your
Forgejo may live there. Resolution is a single-host hole, not a range:

```bash
sbx policy allow network "192.168.1.50:3000"      # forge HTTP
sbx policy allow network "192.168.1.50:22"        # forge SSH, if used
```

Foundry emits exactly these two rules when `forgejo.url` resolves to a private
address, warns on stdout that it is punching a LAN hole, and records it in the
project config so it's reviewable. Everything else on the LAN stays denied.

### Verification (must be automated, not assumed)

`sbx policy check network <target>` evaluates a rule without starting a box.
`foundry box doctor <name>` runs the matrix:

| Target | Expected |
|---|---|
| `api.anthropic.com` | Allowed |
| `github.com:22` | Allowed (rule present) |
| `192.168.1.1` | **Denied** |
| `10.0.0.1` | **Denied** |
| `169.254.169.254` | **Denied** (cloud metadata) |
| forge host, if configured | Allowed |

---

## 2. Target layout

```
~/.local/share/foundry/
├── volumes/<project>/           # THE mount. HOME inside the box.
│   ├── repos/
│   ├── .claude/ .codex/ .gemini/ .config/gh/
│   ├── .ssh/
│   ├── .ralph/  (PROMPT.md, fix_plan.md, memories.md)
│   ├── logs/
│   └── AGENT.md PROMPT.md
├── shared/                      # mounted :ro into every box
└── boxes/<name>/meta.json       # foundry-side mapping only

~/.config/foundry/
├── config.conf
├── projects/<project>.json      # incl. network.allow[], ports[]
└── registry.json                # project↔volume↔box, agent + session state
```

Box creation, canonical form:

```bash
sbx create shell \
  --name "foundry-${project}" \
  -t "ghcr.io/<org>/foundry-agent:${variant}" \
  --cpus "${cpus}" --memory "${memory}" \
  ${publish_flags} \
  "${volume_root}" \
  "${shared_root}:ro"
```

---

## 3. Module work

### New

| File | Responsibility | Est. |
|---|---|---|
| `lib/sandbox.sh` | `sandbox_create/start/stop/destroy/exec/list/status/publish/snapshot`; wraps `sbx`, parses `sbx ls --json` | ~280 |
| `lib/policy.sh` | baseline application, per-project rule generation from git remotes + forge URL, `policy_check_matrix` | ~160 |
| `lib/volume.sh` | volume-root scaffold, `HOME` wiring, migration from a live Firecracker VM | ~200 |
| `docker/foundry-agent.Dockerfile` | one image, three tags via build arg | ~60 |
| `systemd/foundry-agent@.service` (user unit) | autostart | ~25 |

### Rewritten / shrunk

| File | Now | After | Change |
|---|---|---|---|
| `lib/agent.sh` | 2634 | ~2100 | `_ssh_cmd`→`sandbox_exec`; `_scp_to_vm_path`→host `cp` into volume root; `_get_vm_ip` deleted; watcher URL derivation reworked |
| `lib/workspace.sh` | 1266 | ~600 | workspace *is* the volume root; all copy-into-VM paths deleted |
| `lib/registry.sh` | 583 | ~200 | `status`/`pid`/`ip`/`tap` fields drop out; `sbx ls --json` is authoritative |
| `lib/config.sh` | 511 | ~450 | drop `GATEWAY_IP`/`IP_RANGE_*`/`HOST_INTERFACE`/`KERNEL_DIR`; add `SBX_TEMPLATE`, `VOLUME_DIR`, `PORT_RANGE_*` |
| `install.sh` | 474 | ~300 | drop firecracker/kernel/rootfs provisioning; add `sbx` presence + `kvm` group check |
| `bin/foundry` | — | — | `vm`→`box` domain (alias `vm` one release); **delete `network` domain**, add `policy` |

### Deleted outright

```
lib/vm.sh                      1219
lib/network.sh                  478
lib/template.sh                 188
scripts/build-golden.sh         537
scripts/build-ubuntu-base.sh    273
scripts/prepare-kernel.sh       202
scripts/install-firecracker.sh  156
scripts/setup-network.sh         29
                              ------
                               3082 lines
```

`scripts/setup-host.sh` (642) shrinks to ~120: install `docker-sbx`, add user to
`kvm`, `sbx login`, apply the policy baseline, `sbx setup ssh`.

Net: **~4,000 lines removed**, plus the `doas`/root requirement across the CLI
(`_require_root()` disappears from the box lifecycle path; `sbx` runs as the
invoking user in the `kvm` group).

---

## 4. Watchers (the risk phase)

Losing the per-box IP means `webhook_url` can no longer be derived from it.
Replacement mechanism:

1. Foundry allocates a **host port** per watcher from `PORT_RANGE_START/END`
   (default `9100-9199`), stored in the project config — static, not dynamic,
   so it's stable across restarts and reviewable.
2. The box publishes it with an explicit bind, because omitting `HOST_IP` binds
   loopback only:
   ```bash
   sbx ports "$box" --publish "0.0.0.0:${host_port}:${box_port}"
   ```
3. `webhook_url` = `http://<host-lan-ip-or-configured-hostname>:<host_port>/…`,
   derived once at `gh-watcher init` / `forgejo-watcher init`.
4. **Port publishing does not survive a restart.** `foundry box start` must
   re-apply every configured port mapping, every time. Non-negotiable — the
   failure mode is a silently deaf watcher.
5. The watcher service inside the box must bind `0.0.0.0`, not `127.0.0.1`, or
   the forwarder can't reach it.
6. `agent <x>-watcher status` gains a check: published ports present on the box
   AND `curl` from the host to the mapping succeeds. Per AGENTS.md's
   "no silent failures", status must fail loudly when the mapping is missing.

Note the asymmetry that makes this safe: inbound publishing is a host-side
forward and is unaffected by the egress policy; the LAN denies in §1 do not
block the forge from reaching the watcher.

---

## 5. Phases and checklist

### Phase 0 — Spike (throwaway, answers the unknowns)

- [ ] Install `sbx` on the target host; confirm `lsmod | grep kvm`, user in `kvm` group
- [ ] `sbx create shell ~/.local/share/foundry/volumes/spike` and confirm the path is identical inside
- [ ] Confirm `HOME=<volume root>` makes Claude Code write `.claude/` to the host dir
- [ ] Confirm `sbx exec -d` can start a tmux server that `sbx exec -it … tmux attach` reattaches to
- [ ] Run a ralph loop unattended for 1h; confirm `.ralph/memories.md` lands on the host live
- [ ] `sbx stop` + `sbx run -d`; confirm installed packages and agent history survive
- [ ] Verify policy matrix from §1 with `sbx policy check network`
- [ ] Measure git-heavy op (`git status` on the largest repo) vs. current VM — record the number

**DoD:** every box above ticked, with the `HOME` mechanism decided (env var vs.
custom entrypoint in the image vs. kit) and written down.

### Phase 1 — Core lifecycle

- [ ] `lib/sandbox.sh` with the full API; every function returns non-zero on `sbx` failure and surfaces `sbx` stderr (AGENTS.md: surface remote errors)
- [ ] `lib/policy.sh` baseline + `policy_check_matrix`
- [ ] `bin/foundry`: `box` domain (`create/start/stop/restart/destroy/exec/ssh/list/status/publish/snapshot/doctor`), `vm` aliased with a deprecation warning
- [ ] `foundry policy` domain (`baseline/allow/deny/ls/check`)
- [ ] `network` domain removed from dispatch and help
- [ ] `docker/foundry-agent.Dockerfile` builds; three tags push
- [ ] `./scripts/shellcheck.sh && ./scripts/syntax-check.sh` clean

**DoD:** `foundry box create demo && foundry box exec demo -- claude --version` works end to end.

### Phase 2 — Volumes and projects

- [ ] `lib/volume.sh` scaffolds the §2 layout
- [ ] `foundry project init <name>` creates volume root + project config
- [ ] `foundry volume migrate <old-vm> <project>` rsyncs a live Firecracker VM's `/root` into a volume root (run before deleting anything)
- [ ] Sanity check: refuse a volume root on NFS/SMB/cloud-synced paths (virtiofs passthrough — every read crosses the boundary)
- [ ] Shared `:ro` mount wired into every create

**DoD:** an existing project runs from a migrated volume root with its history intact.

### Phase 3 — Agent layer

- [ ] `_ssh_cmd`/`_ssh_cmd_tty` → `sandbox_exec`
- [ ] `_scp_to_vm_path` → host-side `cp` into the volume root
- [ ] `_get_vm_ip` and all callers removed
- [ ] `_generate_vm_ssh_key` removed; SSH agent forwarding documented instead
- [ ] `agent attach` → `sbx exec -it <box> tmux attach`
- [ ] `agent logs` → host `tail -f` on the volume root (no exec at all)
- [ ] `agent start/stop/restart/status/sessions/resume` green for all six agent types

**DoD:** all `foundry agent` commands pass against a Phase-2 project.

### Phase 4 — Watchers

- [ ] Host-port allocation from `PORT_RANGE_*`, persisted in project config
- [ ] `webhook_url` derivation from host address + published port
- [ ] Re-publish all configured ports on every `foundry box start`
- [ ] Watcher services bind `0.0.0.0` inside the box
- [ ] Forge-host policy rules auto-generated; LAN-hole warning printed
- [ ] `*-watcher status` verifies the mapping end to end and fails loudly if absent
- [ ] Live test: real webhook delivery from the forge → agent triggered

**DoD:** a real issue on the forge triggers an agent run, and still does after `foundry box restart`.

### Phase 5 — Autostart

- [ ] `systemd/foundry-agent@.service` user unit generated by `agent enable-autostart`
- [ ] Ordering against the `sbx` daemon; box start → port publish → agent start
- [ ] `disable-autostart` removes cleanly
- [ ] Survives a host reboot (verify with `loginctl enable-linger`)

### Phase 6 — Demolition

- [ ] Delete the eight files in §3
- [ ] `install.sh` rewritten; `setup-host.sh` reduced to the `sbx` path
- [ ] `config/default.conf` purged of network/kernel keys
- [ ] `docs/ARCHITECTURE.md` rewritten (three-layer model → host / sandbox / volume)
- [ ] `docs/CLI-REFERENCE.md`, `docs/PROJECT-SETUP.md`, both watcher docs, `README.md` updated
- [ ] Per AGENTS.md: document `sbx` prerequisites, the policy model, and the LAN-hole caveat in `docs/`
- [ ] `TODO.md` and `docs/planning/vm-lifecycle.md` reconciled
- [ ] `VERSION` bumped to a major; migration notes in the release entry

---

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `HOME`-on-a-mount doesn't work cleanly for some agent CLI | Phase 0 gates everything else; fallback is a custom entrypoint in the image or a kit |
| Port mappings lost on restart → deaf watcher | Re-publish on start + status check that fails loudly (Phase 4) |
| virtiofs slower than ext4 for git-heavy repos | Measured in Phase 0; virtiofs caching is on by default; `DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE=0` only if it misbehaves |
| Vendor dependency: `sbx login` required, CLI is Docker-controlled | Accepted. CLI is free incl. commercial use; only org governance is paid |
| A kit or preset reset widens egress to the LAN | Explicit deny rules for private CIDRs in the baseline; deny always narrows |
| Agent edits host files live (direct mount) incl. `.git/hooks` | Offer `foundry box create --clone` for watcher-driven work (repo RO, agent works on a private clone exposed as a `sandbox-<name>` remote) |

---

## 7. Out of scope for this migration

- Box-to-box communication (not supported; route via host if ever needed)
- Org governance / audit logs (paid tier)
- MCP gateway integration — worth a follow-up design, not part of the port
