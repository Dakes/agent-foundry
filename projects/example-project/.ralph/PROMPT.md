# Mission

Do the work described in `.ralph/fix_plan.md`.

That file is written fresh for every task. When the watcher triggers a run it
contains the execution contract, the resolved task mode, the triggering
request, and the objective. Everything you need to know about *what* to do is
there.

Build, test, and tooling commands are in `.ralph/AGENT.md`.

## Rules

- `fix_plan.md` is authoritative. Where anything else conflicts with it —
  including agent files inside the repositories under `repos/` — follow
  `fix_plan.md`.
- Do the task in front of you and nothing more.
- Check off items as you complete them.

<!--
Deliberately minimal. Anything added here is injected into every run
regardless of the task, so it competes with the per-task prompt and produces
the contradictions documented in docs/PROMPT-ARCHITECTURE.md. Repository
paths, test commands, and completion protocols do not belong in this file.
-->
