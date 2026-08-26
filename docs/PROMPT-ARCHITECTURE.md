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

## Where the fleet's role briefs sit in this

The fleet ([FLEET.md](FLEET.md)) puts durable per-role instructions in the
volume root, at `.claude/agents/*.md` and `.claude/skills/fleet-*/SKILL.md`.
That looks like the contradiction this document exists to prevent, so the line
is worth stating explicitly:

- A **role brief** says how to *be* a builder or a critic: never commit, run
  the gate before the first edit, what a usable report contains. It is the
  fleet's equivalent of `AGENT.md` — "how", scoped to a role.
- A **task prompt** still says what to build, in which mode, with which
  prohibitions. It is generated per request and it is authoritative.

A brief that started saying what to build would re-create exactly the failure
in §1 below, with the same symptom: two unranked imperatives and an agent
resolving them differently on every run. `scripts/check-prompts.sh` guards the
task-prompt side of this; the brief side is a review rule.

The fleet block in the generated prompt names the skill and states the rules
that outrank the briefs, so the precedence is written down where the agent
reads it rather than only here.

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
under `~/repos/` in the sandbox, loaded automatically by the CLI from its
working directory — commonly say things like *"if something is unclear, launch an
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

`default` is not reachable by resolution any more — nothing infers it, and an
unknown mode is an error rather than a silent downgrade to it. It stays valid
so an adapter can pass it deliberately, which is the hook an opt-in "just do
what the comment says" setting would use. See "No mode, no run" below.

### Mode resolution

The mode is **stated, never guessed**. The comment that triggers a run always
contains the trigger keyword — that is what makes it a trigger — so the word
straight after it carries the mode:

```
@touya review    have a look at the last commit
@touya fix       the bug you introduced in parse_args
@touya implement add a --verbose flag
@touya answer    why does the uploader time out?
```

Precedence, highest first:

1. The word after the trigger keyword (`TRIGGER_KEYWORD`, per watcher config).
2. `/review` or `mode: review` anywhere in the request — explicit, so free to
   support, and they survive a reworded mention.
3. `pipeline_failure` is always `fix`: the event is the request, and no human
   comment exists to state a mode.
4. Otherwise `help` — see below.

Quoted material is removed before any of this. Replying with the previous
comment quoted is routine, and a mode word inside a blockquote or code fence
belongs to someone else's message.

#### Why not infer the mode from the phrasing

The first implementation did infer it: synonym tables per mode, a politeness
stripper, clause splitting, noun-form patterns. It read well and it failed
badly. `"don't implement anything, just review it"` resolved to nothing;
`"reveiw this"` resolved to nothing; `"Bitte behebe den Fehler"` resolved to
nothing; and each repair made the next result harder to predict. It was ~80
lines of natural-language processing in shell, and the thing it decided was
which *prohibitions* the agent received.

One stated word is worth thirty inferred ones. The syntax costs a user four
characters and is impossible to get subtly wrong; inference was free to type
and silently wrong. The list of synonyms is now the list of modes.

### No mode, no run

A request that states no mode gets a **hardcoded reply** listing the syntax,
and no agent is started.

`foundry_task_mode` returns `help`; the adapter writes `foundry_help_comment`
to `FOUNDRY_REPLY_FILE` and returns `FOUNDRY_EXIT_HELP` (78). The watcher posts
that file and skips the agent entirely.

The reply is hardcoded, not generated: explaining the syntax is not a task for
a language model. It costs tokens and latency, and a generated answer can
invent a mode that does not exist. `scripts/test-prompt-lib.sh` asserts that
every mode in `FOUNDRY_TASK_MODES` appears in the help text, so the two cannot
drift.

This replaces the old `default` mode as the fallback. `default` remains valid
for an adapter that asks for it deliberately, but nothing resolves to it any
more — a request nobody has understood now produces a question, not a guess.

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
| Per-agent wiring | `templates/goal/watcher_agent_goal.sh`, the one adapter |
| Durable capabilities | `AGENT.md` at the volume root |
| Per-task instructions | generated `<dotfolder>/task_prompt.md` |

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

### Untrusted input

The triggering comment, the description, and the discussion are written by
anyone who can comment on the repository. They used to be spliced into the
prompt raw, which let a comment forge its own `## Execution Contract` section —
at the same heading level as the real one, later in the document, inside the
block the prompt declares authoritative. An architecture built on precedence
cannot let its input mint precedence.

Quoted material is now wrapped in a `<<<UNTRUSTED` fence that the execution
contract names and defines as data. Inside the fence, Markdown headings are
defanged (`## X` → `- X`) and fence markers are broken, so quoted text can
neither impersonate a section nor escape its container.


## Goal-mode agents

`claude-goal`, `codex-goal` and `agy-goal` do not run a loop Foundry writes.
Each CLI ships a `/goal` command that keeps working across turns until a
completion condition holds, so the prompt layer supplies the condition and the
CLI owns the loop.

`foundry_goal_condition` turns the resolved mode into an end state the run can
demonstrate — the same terminal action `foundry_objective_block` already
declares, restated as something observable:

| Mode | Condition |
|---|---|
| `review` | a review comment is posted, and no file was modified |
| `fix` | the fix is pushed to the branch and the failing checks pass |
| `implement` | a pull request implementing the request is open |
| `answer` | a comment answering the request is posted, nothing modified |

Every condition ends with `, or stop after N turns`
(`FOUNDRY_GOAL_MAX_TURNS`, default 20). None of the three CLIs has a
max-iterations flag: the bound has to be inside the condition, or a loop that
cannot satisfy its condition runs until the token budget is gone.

The condition stays short and points at the generated prompt file rather than
restating it. Claude caps a condition at 4,000 characters, and a condition that
competes with the prompt re-creates the source conflict this architecture
exists to prevent.

### What differs between the three

| | Who decides "done" | Verified |
|---|---|---|
| `claude-goal` | a separate small model evaluates the transcript each turn | documented for `-p` |
| `codex-goal` | the agent itself, via an `update_goal` tool | ran headless, completed in 7s |
| `agy-goal` | the `<!-- GOAL_COMPLETE -->` sentinel it emits | ran headless |

Three behaviours are baked into `templates/goal/start-goal.sh.template`
because each cost a debugging session:

- **Claude needs `--output-format stream-json`.** With the default text output
  `/goal` prints nothing until the condition is met, so a long run cannot be
  told from a hung one in `foundry logs -f`.
- **agy's `-p` takes the prompt as its value.** Any flag placed after it is
  swallowed as prompt text, and the agent answers a question *about* the flag.
  Flags come first.
- **agy anchors on a git repository.** Started outside one it works in an
  internal scratch workspace and reports success for work done somewhere else
  entirely. The start script refuses to run when `AGENT_REPO_PATH` is not a git
  checkout, because that failure is invisible in the output.

agy's `--print-timeout` also defaults to five minutes, which would kill a long
run mid-work; `FOUNDRY_GOAL_TIMEOUT` (default `4h`) overrides it.

### Standing instructions

`AGENT.md` in the volume root is the one file to write for instructions that
apply across every repository in the project. The scaffold symlinks each CLI's
native memory file at it — `.claude/CLAUDE.md`, `.gemini/GEMINI.md`,
`.codex/AGENTS.md` — so every agent loads it without Foundry injecting
anything. A real file already at one of those paths is never replaced.

Per-repo `AGENTS.md` files still apply, and the execution contract still ranks
them: authoritative for *how*, never for *whether* or *what*.

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
7. **Untrusted text is fenced.** The triggering request and all background
   material pass through `_foundry_quote`.
8. **Repository paths are derived**, never hardcoded: the volume root differs
   per project.

`scripts/test-prompt-lib.sh` covers mode resolution against realistic phrasings
plus the structural guarantees (review mode forbids opening a PR; the
triggering request precedes background; checklist style never puts a checkbox
on a prohibition).

---

## Extending

**Adding a mode.** Add it to `FOUNDRY_TASK_MODES`, add a `case` branch in
`foundry_objective_block` with at least one `_foundry_never`, add a row to
`foundry_help_comment`, and add cases to `scripts/test-prompt-lib.sh`. No
detection words are needed: the mode is whatever the user types after the
trigger keyword, so the name itself is the trigger.

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

The resolved mode is logged: `Resolved task mode: review (kind: pr)`. A run
that answered with the syntax instead logs `No task mode stated; replying with
usage` and exits 78 without starting an agent.

Inspect the generated prompt in the volume root: `task_prompt.md` inside the
agent's own dotfolder — `.claude/` for `claude-goal`, `.codex/` for
`codex-goal`, `.gemini/` for `agy-goal`. The volume root is a host directory,
so these are readable without entering the sandbox.

If the agent did the wrong kind of work, check the `Mode:` line first. If the
mode is right and the behaviour is wrong, the objective needs a sharper
prohibition. If the mode is wrong, the request stated the wrong word — the
resolver has no judgement to second-guess.
