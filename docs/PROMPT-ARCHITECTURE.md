# Prompt Architecture

How Agent Foundry builds the prompt an autonomous agent receives, why it is
built that way, and what must not be added back.

This document exists because the previous design had no precedence rules. Six
independent sources each asserted goals and workflow at the agent, none of them
claimed authority over the others, and the agent resolved the contradictions
itself — differently on every run. The symptoms were expensive and consistent:
large amounts of reasoning spent deciding which instruction to obey, and tasks
executed as the wrong kind of work.

---

## The problems this replaced

### 1. "Review this MR" produced a new merge request

The watcher adapters branched only on event `kind` (`issue` / `pr` /
`pipeline_failure`). Every branch emitted a hardcoded, implement-shaped
checklist:

```
- [ ] Make the necessary code changes
- [ ] Push fixes to branch `X`
```

The human's actual instruction was dumped into a `## Conversation Thread`
prose block. So the prompt contained an imperative, checkbox-formatted task
list saying *implement*, and a sentence buried in a wall of text saying
*review*. Structural instructions beat buried prose. The agent implemented,
every time, regardless of the request.

Worse, four of the six adapters discarded the request entirely. The context
builders (`gh_watcher_common.sh`, `forgejo_watcher_common.sh`) have always
populated `trigger_body` with the triggering comment, but only the two
`ralph-orchestrator` adapters ever read it. On `ralph` and `kimi-ralph`, the
request was never surfaced as a distinct instruction at all.

### 2. Interactive-session deliberation

Repo-level agent files — `AGENTS.md` and `CLAUDE.md` inside the repositories
under `/root/repos/`, loaded automatically by the CLI from its working
directory — commonly say things like *"if something is unclear, launch an
interactive session"*.

Nothing in any generated prompt mentioned repo-level agent files, stated that
the run was headless, or ranked the two sources. The agent saw two unranked
top-level imperatives and had no way to know that no human was watching. It
reasoned about the conflict on every run.

Three things made it worse: `.ralphrc` permits the `Task` tool, so spawning
sub-sessions looked viable; `templates/workspace/README.md` shipped the advice
*"Ask clarifying questions"*; and `templates/AGENT.md.template` — dead code
that nothing ever deployed — carried its own identity and workflow rules.

### 3. Five spellings of one identity

`## 🤖 Ralph - Task Completed`, `## Ralph - Task Completed`,
`## Kimi - Task Completed`, `## 🤖 $AGENT_DISPLAY_NAME - Task Update (Error)`,
and `## 🤖 ${AGENT_TYPE:-Agent} - ...` were hardcoded across nine files. A
`kimi-ralph` sandbox was told it was Ralph by its durable files and Kimi by
its task prompt.

### 4. Competing completion protocols

`.ralph/PROMPT.md` demanded a `RALPH_STATUS` block, `ralph.yml` declared
`completion_promise: LOOP_COMPLETE`, and `evaluate_agent_outcome` actually
gated on process exit code, ignoring both.

---

## The design

### Precedence, stated explicitly

Highest authority first. This ordering is asserted *in the prompt itself*, not
merely assumed:

1. **Execution Contract** — environment facts and the rule that ranks sources.
2. **Triggering Request** — what the human just asked for.
3. **Objective** — the mode's terminal action and its prohibitions.
4. **Repo-level `AGENTS.md` / `CLAUDE.md`** — authoritative for *how* only.
5. **Background** — reference material, explicitly not instructions.

The key move is (4): repo agent files keep full authority over build commands,
test commands, and code style, and lose all authority over workflow. That
split is what ends the deliberation. Neither file is wrong; the agent just
needed to be told which one wins on which question.

### Section order

Instructions precede reference material, always. Prompts previously opened
with a description and a full conversation dump, so by the time the agent
reached the task list it had absorbed several competing goals. Background now
comes last under a heading that says it is not a list of instructions.

### Task modes

Mode determines the terminal action. Every mode names what it must **not** do,
because the observed failure was never inaction — it was a plausible adjacent
action. Only an explicit prohibition suppresses that.

| Mode | Terminal action | Forbidden |
|---|---|---|
| `review` | post a review comment | modifying code, pushing, opening a PR |
| `implement` | new branch → pull request | pushing to an existing PR branch |
| `fix` | push to the existing branch | opening a new pull request |
| `answer` | post a comment | modifying anything |
| `default` | inferred from the request | opening a PR unless clearly asked |

### Mode resolution

Implemented in `foundry_task_mode`. Highest precedence first:

1. **Explicit directive** anywhere in the triggering comment: `/review`,
   `mode: fix`, `@bot implement`.
2. **Leading verb** of the request, after stripping @mentions, greetings, and
   politeness. `"Hey bot, can you please review this?"` → `review`.
   Only the *leading* verb counts. Scanning the whole body is unpredictable:
   a request to fix something routinely mentions "review" in passing.
3. **`default`**, except `pipeline_failure`, which is always `fix`.

`default` is the generic fallback, and it is deliberately conservative: it
tells the agent to determine intent from the request and choose the least
destructive action that satisfies it. It does not assume code should be
written. An unclear request now produces a comment, not an unwanted pull
request.

### Less is more

Prompts previously carried the full description, the entire discussion thread,
and a generic seven-item checklist regardless of relevance. Every extra
sentence is another opportunity to contradict something. The current shape:

```
# <Kind> #<n>: <title>
## Execution Contract      fixed, ~10 lines
## Task                    mode, repo, path, branch, URL
## Triggering Request      authoritative
## Objective               mode-specific, with explicit prohibitions
## Completion              one header, one optional promise
## Background              reference only, last
```

---

## Where things live

| Concern | Location |
|---|---|
| Contract, modes, objectives, assembly | `templates/prompt-lib.sh` |
| Identity string | `agent_identity_name()` in `lib/agent-registry.sh` |
| Per-agent wiring | the six `*_watcher_agent_*.sh` adapters |
| Durable capabilities | project `.ralph/AGENT.md` |
| Per-task instructions | generated `fix_plan.md` / `task_prompt.md` |

`templates/prompt-lib.sh` is baked into the agent image at
`/opt/foundry/prompt-lib.sh` (see `docker/foundry-agent.Dockerfile`, alongside
`agent-session.sh`) and sourced by every adapter. Adapters contain no prompt
text — they resolve the mode, call the builder, and write the result where
their agent expects it.

The identity resolves in `foundry_identity`: `AGENT_IDENTITY` if the watcher
config sets it, otherwise `agent_identity_name()` from `lib/agent-registry.sh`,
which watcher scripts source inside the sandbox. Deriving from the registry
means the header stays correct without the host having to write the value, so
it survives transport changes.

**Watcher status.** Watchers are not yet wired into the sandbox transport
(`lib/commands.sh` warns about this on `foundry up`; it is Phase 4 of the
Docker migration). The adapters and this prompt layer are ready and tested;
what is missing is the host-side code that starts a watcher and copies the
adapters into the sandbox. When that lands, it should set `AGENT_TYPE` in the
watcher environment — `AGENT_IDENTITY` is optional because of the fallback
above.

---

## Rules

These are enforced mechanically by `scripts/check-prompts.sh`, which runs in
CI. Each corresponds to a defect that previously shipped.

1. **No hardcoded identity strings** outside `prompt-lib.sh`.
2. **Adapters must use `foundry_build_task_prompt`** — no hand-rolled prompts.
3. **No inline task instructions in adapters.** Objectives live in one place.
4. **Durable files answer "how", never "whether" or "what".** No mission
   statements, identity rules, comment formats, or workflow instructions in
   `AGENT.md` or `PROMPT.md`.
5. **No hardcoded repository paths in durable prompts.** The watcher supplies
   the repository per task; a baked-in path contradicts it.
6. **Every mode must state at least one prohibition.**

`scripts/test-prompt-lib.sh` covers mode resolution against realistic phrasings
plus the structural guarantees (review mode forbids opening a PR; the
triggering request precedes background; checklist style never puts a checkbox
on a prohibition).

---

## Extending

**Adding a mode.** Add it to `FOUNDRY_TASK_MODES`, add a `case` branch in
`foundry_objective_block` with at least one `_foundry_never`, add detection
verbs to `foundry_task_mode`, and add cases to `scripts/test-prompt-lib.sh`.

**Adding an agent.** Add it to `lib/agent-registry.sh` including
`agent_identity_name`. Write an adapter that sources the prompt library,
resolves the mode, and calls the builder. Set `FOUNDRY_OBJECTIVE_STYLE=checklist`
if the agent reads a task checklist, and `FOUNDRY_COMPLETION_PROMISE` if it
gates loop completion on a sentinel.

**Changing the contract.** Edit `foundry_execution_contract` only. It is the
single place that resolves repo-file conflicts; forking it per agent
re-creates the original problem.

---

## Debugging a run

The resolved mode is logged: `Resolved task mode: review (kind: pr)`.

Inspect the generated prompt in the volume root — `.ralph/fix_plan.md` for
`ralph`, `.ralph/gh_task_prompt.md` for `ralph-orchestrator`,
`.kimi/task_prompt.md` for `kimi-ralph`. The volume root is a host directory,
so these are readable without entering the sandbox.

If the agent did the wrong kind of work, check the `Mode:` line first. If the
mode is right and the behaviour is wrong, the objective needs a sharper
prohibition. If the mode is wrong, use an explicit `/mode` directive and add
the phrasing that missed to `scripts/test-prompt-lib.sh`.
