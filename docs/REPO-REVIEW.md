# Repository Review — 2026-08

> **Point-in-time record, August 2026.** These are the findings from one review
> pass, kept for the reasoning behind the changes that followed. It is not
> maintained against the current tree: where it disagrees with the code, the
> code is right. Live invariants live in `scripts/check-prompts.sh`.

Findings from a review of Agent Foundry, the reasoning behind each, and what
was changed. Prompt-architecture items are summarised here and covered in full
in [PROMPT-ARCHITECTURE.md](PROMPT-ARCHITECTURE.md).

Status key: **Fixed** — resolved in this change. **Open** — not addressed.
**Superseded** — the Docker sandbox migration deleted the code the finding
described, so there is nothing left to fix.

The review was written against the Firecracker VM backend. The Docker sandbox
migration (`#2`, `#3`) landed afterwards and removed `lib/agent.sh`,
`lib/workspace.sh`, `lib/vm.sh`, `lib/registry.sh`, and `lib/network.sh`
outright. Findings against those files are marked Superseded and kept for the
record — several describe bug classes worth avoiding when the sandbox
transport grows the same features.

---

## 1. Watcher adapters discarded the user's instruction — Fixed

**What.** Four of the six watcher adapters never read `trigger_body`. The
context builders had always populated it with the triggering comment; only the
two `ralph-orchestrator` adapters used it. On `ralph` and `kimi-ralph`, the
request was dumped into a prose `## Conversation Thread` block and never
surfaced as an instruction.

**Why it matters.** The prompt simultaneously contained a hardcoded,
checkbox-formatted list saying *implement* and a buried sentence saying
*review*. Structural instructions win over buried prose, so "review this MR"
reliably produced a new merge request.

**Fixed.** All six adapters now emit a `## Triggering Request` section, placed
before any background material and labelled as taking priority.

## 2. No concept of task intent — Fixed

**What.** Adapters branched only on event `kind`. Every branch emitted the same
implement-shaped checklist.

**Why it matters.** The kind of event says nothing about the kind of work
requested. A comment on a PR can ask for a review, a fix, or an explanation.

**Fixed.** Five task modes (`review`, `implement`, `fix`, `answer`, `default`)
resolved from an explicit directive or the request's leading verb. Each states
its terminal action and what it must not do — the failure mode was a plausible
adjacent action, which only an explicit prohibition suppresses. `default` is
the conservative generic fallback for requests with no clear intent.

## 3. Repo-level agent files contradicted foundry prompts — Fixed

**What.** `AGENTS.md` / `CLAUDE.md` inside the repositories under
`/root/repos/` are auto-loaded by the agent CLI and commonly instruct it to ask
questions or open an interactive session. No generated prompt ever mentioned
those files, stated the run was headless, or ranked the two sources.

**Why it matters.** Two unranked top-level imperatives with no resolution rule.
The agent burned reasoning on every run deciding which to obey.

**Fixed.** Every prompt opens with an execution contract that states the run is
headless with no interactive channel, and splits authority: repo agent files
are authoritative for *how* (build, test, style) and never for *whether* or
*what*. Also removed the shipped advice to "ask clarifying questions"
(`templates/workspace/README.md`, since removed by the migration) and stripped
workflow and identity rules from `templates/AGENT.md.template`, which was dead
code that nothing deployed.

## 4. `ssh -n` silently discarded every heredoc — Superseded

**What.** `_ssh_cmd` (duplicated in `lib/workspace.sh` and `lib/agent.sh`) runs
`ssh -n`, which redirects stdin from `/dev/null`. Seven call sites piped or
heredoc'd data into it. All seven wrote **empty files**:

| Site | File | Consequence |
|---|---|---|
| `agent.sh:1415` | `foundry-agent.service` | autostart silently broken — empty unit |
| `agent.sh:1842` | gh-watcher `processed.json` | invalid JSON; watcher breaks on next start |
| `agent.sh:2546` | forgejo-watcher `processed.json` | same |
| `workspace.sh:960,978,997,1014` | `memory/*.md` | agent working memory empty |

The two `processed.json` cases sit in the watcher *reset* path, which is the
backlog protection `AGENTS.md` § *Watcher Lifecycle* is built around.

**Fixed, then superseded.** Fixed by adding `_ssh_cmd_stdin` (identical minus
`-n`); the migration then deleted both files. The sandbox transport uses
`sandbox_exec`, which runs `docker exec` **without** `-i` and so has exactly the
same latent property: no current caller pipes into it, but the first one that
does will silently write an empty file. If a caller ever needs stdin, add a
`sandbox_exec_stdin` variant with `-i` rather than reaching for a pipe.

## 5. Silent sync failures — Superseded

**What.** `workspace_sync` never checked `_scp_to_vm`. A failed copy still
reported "Workspace sync complete."

**Why it matters.** Directly against `AGENTS.md` § *No Silent Failures*. Note
that `set -euo pipefail` in `bin/foundry` does not help: the moment a caller
wraps a command in `if !` or `||`, `-e` is disabled for the whole call subtree.

**Fixed, then superseded.** All ten unchecked `_scp_to_vm` calls were guarded;
the migration then deleted `lib/workspace.sh`. The sandbox mounts the volume
root as a host directory, so there is no copy step left to fail silently. The
underlying warning about `set -e` still applies to the new code.

## 6. Validation scripts aborted after the first failure — Fixed

**What.** `scripts/shellcheck.sh` and `scripts/syntax-check.sh` combine
`set -euo pipefail` with a `cmd | head` pipeline in the failure branch. Under
`pipefail` that pipeline returns non-zero, `set -e` fires, and the script exits
before reaching the next file.

**Why it matters.** The scripts reported a partial pass as if it were the whole
repository. Fixing it surfaced four real shellcheck findings that had been
masked, all now resolved.

**Fixed.** Failure branches no longer abort the run. Both scripts now report
every file in the tree.

## 7. No CI — Fixed

**What.** `AGENTS.md` mandates running both validators before committing.
Nothing enforced it, and there was no `.github/` directory.

**Why it matters.** Every defect above is the kind a CI run catches.

**Fixed.** `.github/workflows/ci.yml` runs syntax check, shellcheck, the prompt
architecture lint, and the prompt library tests.

## 8. Five spellings of one identity — Fixed

**What.** Comment headers were hardcoded in nine files across five variants,
including agent-name mismatches (a `kimi-ralph` VM told it was Ralph by its
durable files and Kimi by its task prompt).

**Fixed.** `agent_identity_name()` in `lib/agent-registry.sh` is the single
source. `foundry_identity` prefers an explicit `AGENT_IDENTITY` and otherwise
derives the name from the registry using `AGENT_TYPE`, so the header is correct
without the host having to write it — which is what kept this working when the
migration deleted the VM-era watcher config writer. Enforced by
`scripts/check-prompts.sh`.

## 9. Competing completion protocols — Partially fixed

**What.** `.ralph/PROMPT.md` demanded a `RALPH_STATUS` block, `ralph.yml`
declared `completion_promise: LOOP_COMPLETE`, and `evaluate_agent_outcome`
gated on process exit code, ignoring both.

**Fixed.** The completion promise is now emitted by the prompt builder from
`FOUNDRY_COMPLETION_PROMISE`, set per adapter — one protocol per agent type,
declared in one place. The example project's `PROMPT.md` no longer states a
competing protocol.

**Open.** `evaluate_agent_outcome` still gates purely on exit code and a
rate-limit log grep. It does not verify that the promise was actually emitted,
so an agent that exits cleanly without finishing is recorded as success.

## 10. Useless `cat` in version reads — Fixed

`bin/foundry:74` and `scripts/build-release.sh:18` both used
`cat FILE | tr -d ...`. Replaced with a redirect.

---

## Open items

Not addressed here. Roughly in priority order. Items that only applied to the
VM backend have been dropped — see the Superseded findings above.

### Watchers are not wired into the sandbox transport

`foundry up` warns that a configured watcher is not started (`lib/commands.sh`,
Phase 4 of the migration). The six adapters and the prompt layer are complete
and tested, and `prompt-lib.sh` is baked into the image, but nothing yet starts
a watcher or copies the adapters into a sandbox. Until that lands, task modes
and the execution contract are unreachable in normal use.

When wiring it up: set `AGENT_TYPE` in the watcher environment so
`foundry_identity` resolves the right name, and copy the adapters for the
project's agent into the sandbox next to `/opt/foundry/prompt-lib.sh`.

### `.shellcheckrc` disables SC2086 and SC2034 globally

SC2086 was disabled for `$FOUNDRY_SSH_OPTS` word-splitting. That variable is
gone with the VM backend, so the suppression now buys nothing and hides every
genuine unquoted-variable bug in the repository. SC2034 likewise hides real
dead variables. Both should be removed and the fallout fixed.

### `sandbox_exec` cannot take stdin

`docker exec` without `-i` discards stdin, exactly as `ssh -n` did. No caller
pipes into it today, so this is latent rather than broken — but it is the same
shape as finding 4, which shipped for months. Add a `sandbox_exec_stdin`
variant before a caller needs one.

### Missing preflight validation

`AGENTS.md` § *Sanity Checks* asks for early validation. `.kimi/config.toml`
still ships `api_key = ""` and nothing checks it before starting an agent — the
failure surfaces as an auth error buried in a tmux log. The same gap applies to
`.ralphrc` and `ralph.yml` values. `foundry doctor` is the natural home.

### Test coverage beyond the prompt library

`scripts/test-prompt-lib.sh` covers prompt construction, which was the
highest-risk logic. `lib/policy.sh`, `lib/project.sh` config parsing, and
`lib/sandbox.sh` have no tests.

### Smaller

- `.gitignore` has bare `*.log` and `logs/`, which will swallow intentional
  log fixtures.
- `VERSION` still reads `0.1.0` while the CLI is well past that.
