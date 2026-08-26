# The Fleet

`claude-fleet` is an agent type that runs one Claude Code process as an
**orchestrator** and gives it builder and critic subagents, arranged around a
**gate**: a command the project supplies that decides whether work is done.

It exists for changes that are too big for one agent to hold. It is deliberate
overhead, and for most requests it is the wrong tool — which is why it is
opt-in per request rather than per project.

Adapted from the multi-agent framework described in
[`designs/2026-08-26-cot-fleet-agent-feasibility.md`](designs/2026-08-26-cot-fleet-agent-feasibility.md).

---

## The idea in three sentences

1. **A report is evidence, not truth.** The orchestrator re-derives every
   number before it lands anything.
2. **Done is decided by a tool.** The gate, not a conversation, and not how
   finished the work looks.
3. **Failures come back as work orders.** The gate names the worst items with
   their coordinates, and those are the next instructions.

Everything below is machinery for those three.

---

## Choosing it, per request

The strategy is a word in the request, on either side of the mode:

```
@yourbot fix this error                       → solo, fix
@yourbot implement the openspec 123           → solo, implement
@yourbot fleet implement the openspec 465     → fleet, implement
@yourbot solo implement the openspec 465      → solo, forced
```

`/fleet` and `strategy: fleet` work anywhere in the comment too.

The mode and the strategy are separate axes. The mode says *what kind of work*
and carries the prohibitions; the strategy says *how much machinery*. Any mode
composes with either strategy.

A request that names no strategy gets the project's default,
`.fleet.strategy` in `foundry.json` — `solo` unless you change it. So a project
can be fleet-by-default with `solo` as the escape hatch, or the other way
round, and either way the request wins.

**A fleet run is refused, not downgraded.** If the fleet cannot run — no gate
configured, fleet disabled, or the project's agent is not Claude — the watcher
posts a comment saying why and starts nothing. Quietly running solo would hand
back a single agent's work while the requester believes an orchestrator
verified it and a critic reviewed it.

---

## Setting it up

```bash
foundry fleet init my-project      # write the defaults into the project
$EDITOR ~/.local/share/foundry/volumes/my-project/foundry.json
foundry fleet check my-project     # verify it would actually run
```

`init` writes editable copies of the role briefs, the orchestrator skill, the
hooks and `fleet-land` into the volume root, and seeds `.fleet` in
`foundry.json`. It guesses a gate command from the repositories it finds
(`npm test`, `make check`, `pytest`, `cargo test`, `go test ./...`) and tells
you to check it. It never overwrites a brief you have edited; `--force` does.

You do not have to run it. A fleet run materialises whatever is missing on its
way up, exactly as `init` would. The command exists so you can see and edit the
result before a real request arrives.

Then switch it on:

```json
"fleet": { "enabled": true, "gate": { "command": "make check" } }
```

---

## The gate

This is the part that is not optional, and the part only you can write.

Without it, "the orchestrator verifies everything" degrades into several agents
agreeing with each other. Foundry refuses to start a fleet with no gate
command, and says so on the issue.

### Two shapes

**`exit`** — an ordinary check. Exit status is the verdict; the tail of the
output is the work order.

```json
"gate": { "command": "npm test && npm run lint", "format": "auto" }
```

**`json`** — richer, and worth building once a project uses the fleet often.
The command prints an object with `pass`, and optionally `score` and `worst`:

```json
{
  "pass": false,
  "score": 74,
  "worst": [
    { "id": "coverage", "detail": "lib/parse.c is below the floor",
      "actual": "61%", "required": ">= 80%" },
    { "id": "latency", "detail": "p95 on /search regressed",
      "actual": "412ms", "required": "<= 250ms", "at": "bench/search.json:18" }
  ]
}
```

Each `worst` entry reaches the agent as an instruction with coordinates rather
than as a score to feel bad about. That is the difference between "you scored
74" and "p95 on /search is 412ms, needs to be under 250ms, see
bench/search.json:18".

`format: "auto"` (the default) tries JSON and falls back to exit status, which
is what a project gets before anyone has written a JSON gate.

### How it is enforced

The gate runs as a `Stop` and `SubagentStop` hook. When it fails, the hook
exits 2 — which prevents the agent from ending its turn — and writes the work
order to stderr, which is the channel the agent reads. So an agent that has not
passed the gate **cannot stop**, and the thing stopping it is telling it what
to fix.

`foundry fleet gate <project>` runs it by hand, through the same path, so you
can see what an agent would see.

### Budgets

"No iteration cap" is right when a human is watching the spend and wrong in an
unattended sandbox on a subscription. `.fleet.gate.max_iterations` (default 12)
bounds it: past that the gate stops holding the agent and asks for an honest
report of what will not pass and why. A run that stops at "the gate will not
pass because X" is a good outcome. A run that reports success with a failing
gate is not.

A clean tree with nothing unpushed is not gated at all — a `review` or `answer`
round has produced no work to measure, and holding it against whatever state
the branch was already in would only stop the fleet reviewing a red branch.

---

## Roles

Configured in `foundry.json`, written in `.claude/agents/`:

```json
"roles": {
  "fleet-builder": { "count": 3, "model": "sonnet",
                     "summary": "Implements one lane. Never commits." },
  "fleet-critic":  { "count": 1, "model": "opus",
                     "summary": "Adversarial reviewer. Read-only." }
}
```

The key is the subagent's name, and the brief must be at
`.claude/agents/<name>.md` with `name: <name>` in its frontmatter — Claude Code
resolves subagents by that name, not by filename. `foundry fleet check` catches
a mismatch.

Add your own roles the same way: a new key, a new brief. A project with a
security reviewer, a docs writer, or a performance specialist just has more
entries here.

The `summary` is what the orchestrator sees when deciding who to delegate to.
The brief is what the role sees about how to do its job.

**The split that keeps this honest:** a brief says how to *be* a builder. It
never says what to build. What to build comes from the per-task prompt, which
is generated per request and carries the mode's prohibitions. That is the same
rule `AGENT.md` follows, and it is why the briefs can be durable project files
without re-creating the contradiction `PROMPT-ARCHITECTURE.md` exists to
prevent.

`count` caps concurrency: the launcher sets
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` to the total across all roles. The CLI's
own default is far higher than any subscription enjoys, and getting this wrong
shows up as a rate limit halfway through a round.

---

## Lanes

```json
"lanes": { "api": ["src/api/**"], "ui": ["src/ui/**"], "docs": ["docs/**"] }
```

One builder per lane, and lanes must not share files — the whole point is that
several agents can work in one tree without racing.

Lanes are optional. With none configured, the orchestrator partitions the work
per round, which is fine for a project whose shape changes between tasks.
Declaring them is worth it when the same boundaries recur.

---

## The guards

Three PreToolUse and Stop hooks, in `.claude/hooks/fleet/`:

| Hook | Event | Refuses |
|---|---|---|
| `lane-guard.sh` | PreToolUse | writes outside your lane, and writes to protected paths like a gate ledger |
| `commit-guard.sh` | PreToolUse | `git commit/push/merge/rebase/tag` (routed to `fleet-land`), and `stash/clean/reset --hard/checkout --` outright |
| `stop-audit.sh` | Stop, SubagentStop | ending a turn with changes outside your lane |

`git stash` is denied to everyone with no alternative offered. The tree holds
several agents' uncommitted work at once, and stash takes all of it.

Branch work — `git checkout -b`, `git switch` — and all of read-only git are
untouched. They are how an agent proves anything.

### `fleet-land`

The only route to a commit:

```bash
fleet-land -m "message" -- src/api/handler.c    # gate, then stage, then commit
fleet-land --push [branch]                      # gate, then push
fleet-land --gate                               # just run the gate
```

It runs the gate first and refuses while it is failing, so landing without
measuring stops being something anyone can do by accident. It also refuses to
stage the whole tree — `git add .` in a shared tree means "everything anyone
has touched, reviewed or not".

### An honest note on enforcement

Foundry runs Claude with `--dangerously-skip-permissions`. Whether a
`PreToolUse` deny is honoured in that mode is not documented, and has not been
verified here. So lane and commit enforcement is layered:

1. `lane-guard.sh` / `commit-guard.sh` — the cheap early catch, at the point of
   the violation. **Unverified under `bypassPermissions`.**
2. `stop-audit.sh` — the same rule at the end of the turn. A `Stop` hook's exit
   2 is control flow, not a permission decision, so this holds regardless.
3. The orchestrator's own `git status` check before landing — the mechanism the
   original framework actually relied on.

Layers 2 and 3 are the load-bearing ones. If you verify layer 1 one way or the
other, update this section.

---

## Durable notes

Independent of the fleet, and on for every agent type:

```json
"packets": { "enabled": true, "dir": "packets" }
```

Each task gets `<volume-root>/packets/<repo>-<kind>-<number>.md`, and the
prompt tells the agent to write it *as it works, not at the end*. The volume
root is a host directory that outlives any sandbox, so an agent killed
mid-round leaves behind something its replacement can resume from.

Every prompt also requires **honest residuals** in the final comment — what is
still wrong, still unproven, still worked around. An agent that reports only
successes has produced a non-conforming report, and naming the field is what
makes its absence visible.

---

## When not to use it

- **A one-line fix.** The orchestrator will spend more turns delegating than
  the fix takes.
- **`answer` and `review`.** They produce no work to gate. The fleet adds
  latency and nothing else.
- **A project with no meaningful check.** Write the gate first. A fleet built
  on a gate that measures nothing is more convincing than a solo agent and no
  more correct, which is the worst possible combination.
- **When you are near a rate limit.** A fleet is several agents' worth of
  tokens on one subscription.

The honest summary: use it when a change is big enough that you would otherwise
break it into several issues, and when the project can prove its own health
with one command.
