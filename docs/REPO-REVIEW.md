# Repository Review — 2026-08

Findings from a review of Agent Foundry, the reasoning behind each, and what
was changed. Prompt-architecture items are summarised here and covered in full
in [PROMPT-ARCHITECTURE.md](PROMPT-ARCHITECTURE.md).

Status key: **Fixed** — resolved in this change. **Open** — not addressed.

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
(`templates/workspace/README.md`) and stripped workflow and identity rules from
`templates/AGENT.md.template`, which was dead code that nothing deployed.

## 4. `ssh -n` silently discarded every heredoc — Fixed

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

**Fixed.** Added `_ssh_cmd_stdin` (identical minus `-n`) and repointed all
seven call sites.

## 5. Silent sync failures — Fixed

**What.** `workspace_sync` never checked `_scp_to_vm`. A failed copy still
reported "Workspace sync complete."

**Why it matters.** Directly against `AGENTS.md` § *No Silent Failures*. Note
that `set -euo pipefail` in `bin/foundry` does not help: the moment a caller
wraps a command in `if !` or `||`, `-e` is disabled for the whole call subtree.

**Fixed.** All ten unchecked `_scp_to_vm` calls now log a specific error and
return non-zero.

## 6. Validation scripts aborted after the first failure — Fixed

**What.** `scripts/shellcheck.sh` and `scripts/syntax-check.sh` combine
`set -euo pipefail` with a `cmd | head` pipeline in the failure branch. Under
`pipefail` that pipeline returns non-zero, `set -e` fires, and the script exits
before reaching the next file.

**Why it matters.** The scripts reported a partial pass as if it were the whole
repository. Fixing it surfaced four real shellcheck findings that had been
masked, all now resolved.

**Fixed.** Failure branches no longer abort the run. Both scripts now report
all 38 files.

## 7. No CI — Fixed

**What.** `AGENTS.md:110` mandates running both validators before committing.
Nothing enforced it, and there was no `.github/` directory.

**Why it matters.** Every defect above is the kind a CI run catches.

**Fixed.** `.github/workflows/ci.yml` runs syntax check, shellcheck, the prompt
architecture lint, the prompt library tests, and a committed-private-key scan.

## 8. Five spellings of one identity — Fixed

**What.** Comment headers were hardcoded in nine files across five variants,
including agent-name mismatches (a `kimi-ralph` VM told it was Ralph by its
durable files and Kimi by its task prompt).

**Fixed.** `agent_identity_name()` in `lib/agent-registry.sh` is the single
source. The host CLI writes `AGENT_IDENTITY` into both watcher configs; every
header derives from it. Enforced by `scripts/check-prompts.sh`.

## 9. Private keys committed — Fixed

**What.** `projects/*/deploy-key-example` were genuine OpenSSH RSA private
keys.

**Why it matters.** They are in git history and trip secret scanners, even as
throwaway examples.

**Fixed.** Removed, replaced with a `.README` explaining how to generate a
keypair. `.gitignore` now excludes `deploy-key*` while keeping `.pub`. CI fails
if a private key reappears.

## 10. Competing completion protocols — Partially fixed

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

## 11. Useless `cat` in version reads — Fixed

`bin/foundry:74` and `scripts/build-release.sh:18` both used
`cat FILE | tr -d ...`. Replaced with a redirect.

---

## Open items

Not addressed here. Roughly in priority order.

### `_ssh_cmd` is duplicated

The same function exists in `lib/workspace.sh` and `lib/agent.sh`, which is why
the `ssh -n` defect had to be found and fixed twice. It belongs in
`lib/utils.sh`. Deferred because moving it touches every caller in both files
and is better done as its own change.

### `.shellcheckrc` disables SC2086 globally

Disabled for `$FOUNDRY_SSH_OPTS` word-splitting, but it hides every genuine
unquoted-variable bug in the repository. The fix is to make `FOUNDRY_SSH_OPTS`
an array and re-enable the check. SC2034 is likewise disabled globally and
hides real dead variables.

### Multi-field registry updates are not atomic

`lib/registry.sh` is otherwise solid — `flock`, temp file plus atomic rename,
post-write `jq empty` validation. But `agent_start` performs four separate
`registry_update` calls, each taking and releasing the lock, so a concurrent
`foundry vm list` can observe a half-written agent record. A
`registry_update_many` taking one lock for the batch would close it.

### Missing preflight validation

`AGENTS.md` § *Sanity Checks* asks for early validation. `.kimi/config.toml`
ships `api_key = ""` and nothing checks it before creating a VM, syncing, and
starting an agent — the failure surfaces as an auth error buried in a tmux log.
The same gap applies to `.ralphrc` and `ralph.yml` values.

### Test coverage beyond the prompt library

`scripts/test-prompt-lib.sh` covers prompt construction. Mode resolution was
the highest-risk logic, but `lib/registry.sh` locking, `lib/config.sh` parsing,
and `lib/network.sh` IP allocation have no tests.

### Smaller

- `.gitignore` has bare `*.log` and `logs/`, which will swallow intentional
  log fixtures.
- `_scp_to_vm` always passes `-r`, so a typo'd source path copies a directory
  tree without complaint.
- `VERSION` still reads `0.1.0` while the CLI is well past that.
