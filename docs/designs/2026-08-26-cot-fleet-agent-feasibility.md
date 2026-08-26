# Can we bolt the Claude-of-Tanks framework onto Agent Foundry?

**Status:** research / pitch. Nothing built. No decision made.
**Question asked:** could CoT's multi-agent framework become another Foundry agent
type, running on stock Claude Code with a subscription?
**Short answer:** yes, and the expensive-looking part is the cheap part.

---

## The cold open

A guy shipped 2117 commits of a Three.js tank game by running 6–8 Claude agents in
parallel for weeks. He didn't do it by being clever with prompts. He did it by
making **"done" a thing a program decides, not a thing an agent claims**.

That's the whole trick. Three sentences:

1. **An agent's report is evidence, not truth.** Somebody with no stake re-derives
   every number.
2. **Done is defined by a tool.** Six scores, all ≥ 90, `min()` is the headline.
   Nothing averages away a failure.
3. **Failures come back as work orders, not scores.** Not "you got 74". Instead:
   *"at z=+4.36 your bow bottom is 0.58 m too deep."* The agent's next action is
   fully determined by tool output.

Everything else in that repo — 996 lines of rulebook, a 9361-line blackboard, hash
freezing, FIFO ticket locks — is scaffolding holding those three sentences up.

---

## The bit where I tell you it's easier than it looks

I went looking for the hard parts. Most of them are already sitting in this repo or
shipped in stock Claude Code. Here's the mapping:

| CoT mechanism | Stock Claude Code primitive | Foundry already has |
|---|---|---|
| Role briefs as skills | `~/.claude/skills/<n>/SKILL.md` | `HOME` **is** the volume root → skills land natively, zero plumbing. `skills/claude/` even exists as a gitignored staging dir |
| Builders (6–8 parallel, isolated) | `.claude/agents/*.md`, `background: true`, isolated context windows, **20 concurrent by default** | — |
| Critics that *mechanically cannot* edit | subagent frontmatter `tools: Read, Grep, Glob, Bash` | — |
| Builders never commit | `disallowedTools` on the builder agent def | prohibitions doctrine (`AGENTS.md` → "Every task mode must state explicit prohibitions") |
| **The gate defines done** | **`Stop` hook, exit 2** | — |
| **Failures return as work orders** | **exit-2 stderr is shown to Claude** | — |
| Ledger is tool-written, hand edits are a violation | `PreToolUse` hook denying Write/Edit on `ledger.json` | — |
| One agent per file | `PreToolUse` hook checking a lane map | — |
| Packets survive agent death | plain files | **the volume root is a live host bind mount.** Already durable. Already the point of the project |
| No iteration cap | `/goal` | `agent_max_iterations()` already returns `0` |
| Owner directives | a forge comment | the Forgejo watcher, already shipping |
| Resume-before-respawn | — | watcher restart + `mark-all` cutoff semantics |

Read that table again. **Foundry already built the boring half.** Durable
host-mounted state, per-project isolation, an event source, a prompt architecture
with enforced precedence rules, and a CLI registry designed to take new agent types.

---

## The star of the show: `Stop` hook = the gate

This is the one idea worth the whole exercise, and it's about 40 lines.

CoT's gate is "run the tool, every component ≥ 90, and here are the 12 worst columns
with coordinates." Stock Claude Code gives you this verbatim:

```bash
# <volume-root>/.claude/hooks/gate.sh   — wired as a Stop hook
gate_out="$("$FOUNDRY_GATE_CMD" --json)" || true
if ! jq -e '.pass' <<<"$gate_out" >/dev/null; then
    {
        echo "GATE FAILED. You are not done. Worst items, in order:"
        jq -r '.worst[] | "  \(.id): \(.detail) (have \(.actual), need \(.required))"' \
            <<<"$gate_out"
        echo "Fix the top item, re-run the gate, repeat. Do not report success."
    } >&2
    exit 2      # ← Claude Code will not let the agent stop
fi
```

Confirmed against the docs: `Stop` and `SubagentStop` both support exit code 2, which
*"prevents Claude from stopping, continues the conversation"*, and on exit 2 the
hook's **stderr is shown to Claude**. That is literally the work-order channel.

So: an agent that has not passed the gate **physically cannot end its turn**, and the
thing that stops it also tells it exactly what to fix next. "There is no iteration cap
— the gate defines done" becomes a config file.

Foundry's contribution is the socket, not the gate. `foundry.json` grows:

```json
"fleet": {
  "gate": "npm run gate -- --json",
  "gate_schema": "v1",
  "lanes": { "api": "src/api/**", "ui": "src/ui/**" },
  "builders": 4,
  "critics": 1
}
```

And per the repo's own Sanity Checks doctrine: **no `gate` command → refuse to start a
fleet run.** Loudly. With the reason. Because without a gate, "the orchestrator
verifies everything" quietly degrades into a human reading diffs, which is exactly
what the CoT report warns about.

---

## Five ways to do this, cheapest first

### Tier 0 — "The Freebies" · ½ day · difficulty 2/10

The CoT report's own finding: *"the parts that cost nothing are the parts most repos
skip."* No new agent type. Pure `prompt-lib.sh` + template work.

- **Honest residuals as a required report field.** An agent that reports only
  successes has filed a non-conforming report. One new bullet in the completion
  block.
- **Packets.** Per-task `packets/<slug>.md` in the volume root, written *before*
  reporting, not after. Survives every death because the volume root is a host
  directory.
- **Stated doc precedence.** Foundry already does this better than CoT
  (`PROMPT-ARCHITECTURE.md` is genuinely good). Just extend it to the packets.
- **"Law discoveries for the bank"** — a report field that feeds `AGENT.md`.

**Verdict: do this regardless of what else you decide.** It's a handful of `printf`
lines and it makes every existing agent type better.

### Tier 1 — `claude-gate` · 2–3 days · difficulty 4/10

`claude-goal` plus the Stop hook above. **One agent. No fleet.** The single
highest-value-per-line item in this entire document.

New files:
- `templates/fleet/gate-hook.sh` (~60 lines)
- `.claude/settings.json` seeding in `lib/project.sh` (~40 lines)
- registry entry + one `case` arm in `start-goal.sh.template` (~30 lines)
- new task mode `build` with prohibitions (~50 lines in `prompt-lib.sh`)

Gotcha you'll hit immediately: `scripts/check-prompts.sh` rule 6 hardcodes
`for mode in review implement fix answer default`. Adding a mode without adding its
`_foundry_never` prohibition fails CI. **That's the guard working**, not a bug.

**Verdict: the actual recommendation.** You get "done is decided by a tool" and
"failures come back as work orders" without touching Foundry's one-agent-per-project
model at all.

### Tier 2 — `claude-fleet` · 1–2 weeks · difficulty 6/10

**This is the "new agent type" you asked about.** One `claude -p` process. Inside it,
the orchestrator plus builder/critic subagents.

```
foundry-work (tmux, one process)
└── claude -p "/goal <condition>"          ← ORCHESTRATOR. only thing that commits.
    ├── @builder api      (background, isolated ctx, SubagentStop→gate)
    ├── @builder ui       (background, isolated ctx, SubagentStop→gate)
    ├── @builder infra    (background, isolated ctx, SubagentStop→gate)
    └── @critic           (tools: Read/Grep/Bash — cannot edit. mechanically.)
```

Everything is declarative:

| Piece | Where it lives | Enforced by |
|---|---|---|
| Builder brief | `.claude/agents/builder.md` | frontmatter `tools`, `disallowedTools`, `maxTurns`, `model` |
| Critic brief | `.claude/agents/critic.md` | read-only tool list — it *can't* edit source |
| Orchestrator landing protocol | `.claude/skills/land-round/SKILL.md` | the skill, invoked by name |
| Lane ownership | `foundry.json` `.fleet.lanes` | `PreToolUse` hook: deny Edit outside your lane |
| Ledger integrity | `packets/ledger.json` | `PreToolUse` hook: deny all writes except by the gate |
| Done | `.fleet.gate` | `SubagentStop` hook, exit 2 |

The concurrency limit is 20 by default — CoT's proven load is 6–8, so you fit with
room to spare. Set `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` per project to keep quota
sane.

Best part: **the seven CoT role skills in the zip are already the right file format.**
`spawn-builder.md`, `spawn-critic.md`, `land-round.md`, `graduate.md`, `photo-round.md`
— YAML frontmatter, `name`, `description`, triggers. Swap the tank nouns for code
nouns and they drop into `<volume-root>/.claude/skills/`. That's a find-and-replace
exercise, not an authoring one.

Rough size: ~1000 lines, most of it declarative config and markdown.

**Verdict: worth it, once Tier 1 has proven the gate works on a real project.**

### Tier 3 — the out-of-process fleet · 4–6 weeks · difficulty 9/10

N separate `claude -p` processes in N tmux sessions, orchestrator as its own process,
coordination purely through files. Maximum fidelity to CoT. True crash survival: one
builder segfaulting doesn't take the fleet with it.

Cost:
- Foundry's entire lifecycle assumes **one session per project**.
  `agent_session_name()` literally returns a constant with a comment explaining why.
  `status`, `logs`, `attach`, `down` all inherit that assumption. Reworking it is the
  bulk of the 4–6 weeks, and none of that work is the interesting part.
- 8 concurrent Claude processes on one subscription is a *very* different burn rate
  from 8 subagents inside one process.

**Verdict: don't.** The crash-survival argument is the only real win, and Tier 2 gets
most of it for free because packets live on a host bind mount. Revisit only if Tier 2
demonstrably falls over.

### Tier X — the mixed fleet · +2 days on top of Tier 2 · difficulty 5/10

The genuinely fun one, and **uniquely available to Foundry** because
`foundry-agent:base` already ships every CLI in one image.

Your own `CLAUDE.md` says: *"Never spawn Agents using your native Task feature. Always
spawn agents using the gemini skill. This is to conserve tokens."* You already
invented this. Formalise it:

```
Claude (Opus)  → orchestrator: verifies, lands, commits.  Expensive. Rare.
Claude (critic)→ adversarial review.                       Expensive. Rare.
Gemini / Codex → builders: grind the gate loop.            Cheap. Constant.
```

The builders don't need judgment. They need to read a work order with coordinates in
it and make a number go up — the gate is doing the thinking. That's the cheapest
possible token per unit of progress, and it spreads load across three subscriptions
instead of hammering one.

`VISION.md` §2 already says "Maximize AI subscription usage across projects." This is
that, one level down.

---

## What it actually costs you

No pitch without the invoice.

**1. Rate limits are the real ceiling, not engineering.** 6–8 parallel Claude agents
will eat a 5-hour subscription window alive. Mitigations, in order of effectiveness:
the mixed fleet (Tier X), `model:` per role in the agent frontmatter, and
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` as a hard throttle. Budget for this before
you budget for code.

**2. No oracle, no gate, no framework.** CoT's gate exists because 3D geometry is
*measurable*. Rough tiers for a code repo:

| Strength | You have | Gate looks like |
|---|---|---|
| Strong | golden dataset, reference impl, perf budget, property tests, typed API | a real number, `min()` across components |
| Medium | tests + coverage + lint + complexity + contract tests | mechanical checklist, all-or-nothing |
| Weak | prose, design, product taste | CoT's own `photo-round`: a pre-registered numbered claim table + an adversarial critic, **and an explicit ban on recording measurements you know are meaningless** |

Most Foundry projects land in Medium. That's fine — Medium is enough to make the Stop
hook meaningful. But the framework's honesty rule applies: if the gate would be fake,
**say so and don't run one.**

**3. The orchestrator is a throughput bottleneck by design.** One process verifying
and committing everything. That's the safety property *and* the ceiling. Not a bug to
engineer around.

**4. Law docs accrete.** 996 lines of rulebook plus a 9361-line blackboard.
`LESSONS.md` exists precisely because the rulebook stopped being readable.

**5. It was scaffolding, and it got deleted.** ADR 0005 stripped Layer 2 from public
`main` once the campaign ended. Worth knowing before adopting it as permanent
furniture. Design the fleet as *something a project turns on for a campaign*, not as
the default agent type.

---

## Landmines, ranked

**🔴 The one that decides everything.** Foundry runs Claude with
`--dangerously-skip-permissions`. Do `PreToolUse` hooks still fire and still *deny*
under `bypassPermissions`? The docs confirm hooks **receive** `permission_mode` (so
they can see the mode), but they do **not** state whether a deny is honoured in
bypass mode. If deny is ignored there, the lane guard and the ledger guard are
decorative — the gate (`Stop`/`SubagentStop`, exit 2) is unaffected either way.
**This is a 20-minute spike and it should happen before any other work.** Tier 1
survives a bad answer; Tier 2's enforcement story does not.

**🟡 Rulebook vs. `check-prompts.sh` rule 4.** Durable files answer "how", never
"whether" or "what". A fleet rulebook is 100% "what". Rule 4 currently only scans
`AGENT.md` under `projects/` and `templates/`, so a `docs/BUILD-STANDARD.md` inside
the user's repo slips through — but that's an accident, not a decision. Resolve it
deliberately: the rulebook is **project law living in the project's repo**, referenced
by a skill, never mission text in `AGENT.md`. Then write that down.

**🟡 Infinite gate loop = infinite burn.** "No iteration cap" is right for a supervised
human owner and wrong for an unattended sandbox on a metered plan. The existing goal
condition already ends with *"or stop after N turns and report what is blocking you"*
— keep that, and add a wall-clock budget to the hook. A fleet that reports BLOCKED is
worth more than one that grinds until Tuesday.

**🟢 Subagents die with the parent process.** Real, and already solved: packets are on
a host bind mount. This is the thing Foundry was built for.

**🟢 `skills/{claude,codex,gemini,kimi}/` is currently vestigial** — gitignored,
`.gitkeep` only, referenced by nothing in `lib/` or `install.sh`. It's the obvious home
for shipped role skills. Either wire it up or delete it; right now it promises
something nothing does. (Same complaint `TODO.md` already makes about `.autostart`.)

---

## Blast radius

| File | Tier 1 | Tier 2 |
|---|---|---|
| `lib/agent-registry.sh` | +1 type, ~8 case arms | +1 type |
| `templates/prompt-lib.sh` | new `build` mode + prohibitions | + fleet objective block |
| `scripts/check-prompts.sh` | mode list (rule 6) | + fleet adapter rules |
| `templates/goal/start-goal.sh.template` | one case arm | one case arm |
| `lib/project.sh` | seed `.claude/settings.json`, `packets/` | + `.claude/agents/`, `.claude/skills/` |
| `templates/fleet/` | `gate-hook.sh` | + `lane-guard.sh`, `ledger-guard.sh`, role skills, agent defs |
| `docker/foundry-agent.Dockerfile` | copy hooks to `/opt/foundry/` | same |
| `foundry.json` schema | `.fleet.gate` | `.fleet.{lanes,builders,critics}` |
| `scripts/test-prompt-lib.sh` | new mode assertions | + fleet assertions |
| `docs/` | section in `PROMPT-ARCHITECTURE.md` | new `docs/FLEET.md` |

Tier 1: ~350 lines. Tier 2: ~1000 more, mostly markdown and JSON.

---

## What I would *not* copy

- **Hash-freezing every artifact.** Solves a problem git already solves when your
  agents commit to branches instead of sharing one dirty tree.
- **The FIFO ticket lock.** CoT needed it because a browser render rig is a physical
  singleton. Unless your gate has one of those, skip it.
- **996 lines of numbered clauses.** Start with a one-page rulebook. Let it grow only
  when an incident demands it, exactly as CoT's did — but keep the `LESSONS.md`
  companion from day one, not from line 500.
- **The 9361-line blackboard.** Per-task packets + the gate's ledger cover it at
  Foundry's scale.

---

## The pitch, in one breath

Foundry already has the durable state, the isolation, the event source, and a prompt
architecture with real precedence rules. What it's missing is a **machine-checkable
definition of done**, and stock Claude Code hands you that as a Stop hook that exits 2
and prints the work order to stderr.

Ship Tier 0 this week because it's free. Ship Tier 1 next because it's 350 lines and
it's the whole idea. Ship Tier 2 when a real project has proven its gate isn't a lie.
Skip Tier 3. Try Tier X because you already invented it and it's the one thing nobody
else can do.

**But run the 20-minute permission-mode spike first.** Everything above assumes hooks
still bite under `--dangerously-skip-permissions`, and the docs don't say.
