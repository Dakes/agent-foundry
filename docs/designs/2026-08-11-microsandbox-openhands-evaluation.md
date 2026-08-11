# Evaluation: Firecracker → microsandbox, and Ralph/Claude Code → OpenHands

Date: 2026-08-11
Status: Investigation — **recommendation: do neither migration as stated; cherry-pick two things**

## Question

1. Does it make sense to migrate the VM layer from Firecracker to
   [microsandbox](https://github.com/superradcompany/microsandbox)?
2. Does it make sense to replace much of the coding-agent layer with
   [OpenHands](https://github.com/OpenHands/OpenHands)?

Stated acceptance criteria for (2): it only makes sense if OpenHands can run on a
**Claude subscription**, if it serves the goal of a **fully autonomous, self-learning**
coding agent, and if it **integrates with Forgejo/GitHub**.

## Verdict

| Proposal | Verdict | Reason in one line |
|---|---|---|
| Firecracker → microsandbox | **No** | Solves a problem we don't have; its lifecycle model contradicts ours; beta software under the whole product. |
| OpenHands *agent* replaces Ralph/Claude Code | **No** | Fails the subscription criterion outright — Anthropic blocked third-party harnesses from subscription billing on 2026-04-04. |
| OpenHands *control plane* (Agent Canvas / Agent Server) driving Claude Code over ACP | **Maybe — worth a spike** | Keeps subscription auth inside the official `claude` binary, and replaces ~1,400 lines of bespoke watcher bash with a supported Forgejo integration. |

---

## Part 1 — Firecracker → microsandbox

### What microsandbox actually is

- libkrun-based VMM (KVM on Linux, Hypervisor.framework on macOS, WHP on Windows),
  not Firecracker. Library-first: you embed it and spawn microVMs from your process.
- Runs **OCI images** (Docker Hub / GHCR) with an OverlayFS writable layer.
- Boot times advertised under 100 ms.
- Host-side network stack (smoltcp) with policy: allow/deny hosts and ports, DNS
  pinning, TLS inspection, port publishing. Notable feature: **secrets are swapped in
  at the host egress layer, so real credentials never enter the guest.**
- Has SSH/SFTP, volumes, snapshots of the writable layer, detached mode (`msb run -d`),
  adjustable CPU/memory, and an MCP server.
- Apache-2.0, 7.2k stars, YC-backed, actively developed (commits as recent as
  2026-08-11).
- README states plainly: *"Microsandbox is still **beta software**. Expect breaking
  changes, missing features, and rough edges."*

### Why it's a bad fit for Agent Foundry

**1. The lifecycle models are opposites.** microsandbox's stated design principle is
*"No background services or `systemd` units. The lifecycle of the VM is tied to the
application process."* Agent Foundry is the exact inverse: a long-lived VM per project
that survives host reboots, runs watcher daemons and tmux/screen sessions for days, and
is reachable over SSH and an inbound webhook port. We would be fighting the tool's
central assumption on day one.

**2. There is no gain on the axis that matters.** microVM boot time is irrelevant to a
VM that lives for a week. Firecracker is already the fastest mature option and is
production-hardened (it runs AWS Lambda). We would trade proven for beta and get back
~25 ms of boot time we never spend.

**3. The migration is not where the code is.** Firecracker coupling is genuinely small
— 12 references in `lib/vm.sh` (binary resolution + `_generate_fc_config`), plus
`scripts/setup-host.sh`, `scripts/install-firecracker.sh`, `scripts/prepare-kernel.sh`.
The other ~8,000 lines of `lib/` are SSH-driven orchestration and are already
VMM-agnostic. But the cost isn't the VMM shim — it's the two layers underneath it:

- **Image pipeline**: `scripts/build-ubuntu-base.sh` / `build-golden.sh` produce an ext4
  rootfs. microsandbox wants OCI images. Full rewrite of template build.
- **Network model**: `lib/network.sh` gives each VM a static IP on a TAP bridge
  (172.16.0.0/24). `lib/agent.sh:2189` derives the Forgejo webhook URL as
  `http://${vm_ip}:${listen_port}/webhook`. microsandbox publishes ports on the host
  instead, so per-VM addressing, `vm ssh`, and webhook derivation all change shape.

**4. Beta software as the load-bearing foundation.** Breaking changes in the VMM would
break every VM in the fleet, and the fleet is the product.

### What microsandbox has that we'd actually want

Two things are genuinely attractive and worth stealing without migrating:

- **OCI images instead of hand-rolled ext4.** We can have this on Firecracker today:
  build the golden image from a Dockerfile, then `docker export | mkfs.ext4`. That's
  most of the ergonomic win at a fraction of the risk, and it makes
  `templates/update-ai-deps.sh` mostly redundant.
- **Host-side egress policy + secret injection.** For a fully autonomous agent this is
  the strongest idea in the project: the VM never holds the real token, and a
  compromised or confused agent can only reach an allowlist of hosts. We can approximate
  the network half with nftables rules on the TAP interface in `lib/network.sh`. The
  secret-swap half would need a host-side proxy — a real project, but a much better
  investment than a VMM swap.

### Recommendation

Keep Firecracker. Revisit microsandbox only if one of these becomes true:

- We need macOS or Windows hosts (microsandbox's clearest differentiator).
- We add a genuinely ephemeral workload — per-PR throwaway sandboxes, untrusted code
  execution — where it would sit *alongside* Firecracker as a second backend rather
  than replacing it.
- It exits beta and grows a supported persistent-VM story.

---

## Part 2 — OpenHands

### The subscription question decides it

**Anthropic restricted subscription OAuth to its own products on 2026-04-04.** Claude
Pro/Max no longer covers usage through third-party harnesses; enforcement began with
OpenClaw and expanded to third-party harnesses generally. Claude Code, Claude.ai, and
Claude Desktop are unaffected. Third-party tools must use an API key or pay-as-you-go
"extra usage" billing.

OpenHands' own docs confirm the state of play: their LLM-subscriptions page supports
**OpenAI/ChatGPT subscriptions only** — *"OpenAI subscription is the first provider we
support"* — with no Claude subscription support. The OpenHands-CLI issue proposing
`openhands login <provider>` OAuth (OpenHands-CLI#261) was **closed as stale**.

So: running the **OpenHands agent** means LiteLLM → Anthropic **API key**, metered per
token. For a Ralph-style loop running 24/7 that is not a marginal cost difference — it
is the difference between a flat monthly subscription and an uncapped per-token bill.
This fails the user's stated gate, and it's the correct place to stop.

### The one configuration that does pass

OpenHands has repositioned around **Agent Canvas**, a self-hosted control center:
*"Run OpenHands, Claude Code, Codex, Gemini, or any ACP-compatible agent across local,
remote, and cloud backends."* Three components: Agent Canvas (frontend), **Agent Server**
(REST API running multiple agents on one machine), and **Automation Server**
(schedule- and webhook-triggered runs, with Slack/GitHub/Linear integrations).

If Claude Code is the agent driven over ACP, then the official `claude` binary makes the
LLM calls with its own OAuth, and subscription billing still applies. In that
configuration you are **not** replacing the coding agent — you are replacing the
*orchestration and eventing layer* while keeping Ralph/Claude Code as the brain.

Caveat worth naming: whether Anthropic considers an ACP-driven `claude` binary a
"third-party harness" is not settled by anything published. The calls are made by
Anthropic's own shipped client, which is the safe side of the line, but this is a policy
risk to monitor, not a guarantee.

### Scoring against the other two criteria

**Forgejo/GitHub integration — clear win for OpenHands.** OpenHands ships a unified git
provider abstraction covering GitHub, GitLab, Bitbucket Cloud, Bitbucket Data Center,
**Forgejo**, and Azure DevOps, including self-hosted instances, with PR/MR creation and
microagent discovery. Against that, we currently maintain:

- `templates/forgejo/` — watcher, receiver (socat on :8080), hook manager, mark-all
- `templates/gh-watcher/` — a parallel implementation for GitHub
- per-agent adapter scripts in `templates/ralph/` and `templates/kimi/`
- the webhook plumbing in `lib/agent.sh` (~600 lines around the watcher config)

That's roughly 1,400+ lines of bash reimplementing what the Automation Server does as a
supported feature. This is the single strongest argument in OpenHands' favour.

**Fully autonomous — parity, not a win.** OpenHands headless mode runs in always-approve
mode with JSON event output, and powers the OpenHands Resolver (issue → edit → test →
PR, unattended). That is real and mature. But it is the same capability our Ralph loop
plus watcher already provides; adopting it buys robustness, not a new capability.

**Self-learning — no decisive win, and don't overread the claim.** What OpenHands
actually ships is (a) **microagents/skills** that auto-load repo conventions when
triggered, persist across sessions, and can be enabled/disabled, and (b) a **condenser**
that compresses context so a session can exceed the context window indefinitely, backed
by a replayable EventLog. Both are good engineering. Neither is online learning — no
weights change, and there is no shipped mechanism that mines past trajectories into
improved policy. (Search results on "agents that learn from past trajectories" are
research literature, not OpenHands features.) Claude Code's `CLAUDE.md` + skills +
memory cover substantially the same ground, and we already use them. If we want genuine
self-improvement, it has to be built either way: a persistent cross-run memory store
that distils recurring discoveries into skills. Neither project hands it to us.

### Recommendation

Do not replace the agent layer with OpenHands' agent — the subscription gate closes it.

Do consider a **time-boxed spike** (2–3 days) on the narrow question that survived:

> Can OpenHands Agent Server, running inside a Foundry VM, drive Claude Code over ACP
> against a Forgejo repo — with subscription auth intact — well enough to retire
> `templates/forgejo/` and `templates/gh-watcher/`?

Success criteria for the spike:

1. `claude` authenticates via its own OAuth and the run does **not** consume API credit.
2. Forgejo provider works against a self-hosted instance (token scopes, webhook delivery
   into the VM — the same `ALLOWED_HOST_LIST` / routing constraints documented in
   `docs/FORGEJO-WATCHER.md` still apply).
3. Automation Server webhook triggers replace `forgejo_watcher.sh` without losing
   `mark-all` semantics (see the Watcher Lifecycle rule in `AGENTS.md` — restarts must
   not reprocess the backlog).
4. It fits as a new agent type in `lib/agent-registry.sh` rather than requiring changes
   to `vm.sh` / `network.sh`.

If the spike succeeds, add `openhands` as an agent type alongside `ralph`,
`ralph-orchestrator`, and `kimi-ralph` — additive, opt-in, no migration. If it fails on
criterion 1, close the question: the economics of a 24/7 loop on metered API billing
don't work, and that was the user's gate.

---

## Summary of concrete actions

| Priority | Action | Effort |
|---|---|---|
| — | Keep Firecracker. No VMM migration. | none |
| Medium | Build the golden rootfs from a Dockerfile (`docker export` → ext4) instead of the bespoke ext4 scripts. | ~1 week |
| Medium | Egress allowlisting per VM via nftables on the TAP interface. | ~2 days |
| Medium | Spike: OpenHands Agent Server + Claude Code over ACP + Forgejo, per criteria above. | 2–3 days |
| Low | Revisit microsandbox if macOS support or ephemeral per-PR sandboxes become requirements. | — |

## Sources

- microsandbox — https://github.com/superradcompany/microsandbox, https://docs.microsandbox.dev/
- OpenHands — https://github.com/OpenHands/OpenHands, https://docs.openhands.dev/
- OpenHands LLM subscriptions — https://docs.openhands.dev/sdk/guides/llm-subscriptions
- OpenHands headless mode — https://docs.openhands.dev/openhands/usage/cli/headless
- OpenHands-CLI subscription-OAuth proposal (closed/stale) — https://github.com/OpenHands/OpenHands-CLI/issues/261
- Anthropic third-party harness restriction, 2026-04-04 — https://venturebeat.com/technology/anthropic-cuts-off-the-ability-to-use-claude-subscriptions-with-openclaw-and, https://thenextweb.com/news/anthropic-openclaw-claude-subscription-ban-cost
