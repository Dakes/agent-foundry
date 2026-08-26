---
name: fleet-report
description: The required shape of a round report inside a Foundry fleet run. Use when a builder or critic is writing up a completed round, or when the orchestrator is checking whether a report is complete enough to act on. Triggers - "write the report", "report the round", "is this report complete".
---

# Round report format

A report exists so that someone who was not there can check it. Every field
below is there because its absence hid a real failure at some point.

## Required fields

**1. What changed.** One paragraph. Files and behaviour, not intent.

**2. Before / after.** Per gate component, the number before your changes and
the number after. Both from runs you performed, not from the work order you
were handed.

**3. Per work-order item.** For each item you were given: the item as stated,
what you did about it, and the measurement that closes it. An item you did not
close is listed here as open, not omitted.

**4. Honest residuals.** *Required, and never empty by default.* What is still
wrong, still failing, still unproven, still guessed. Anything you worked around
instead of fixing. Anything you are not confident about.

If you genuinely believe nothing is left, write that as an explicit claim —
"no residuals: every item closed with a measurement" — so that it reads as a
statement someone can check rather than as a field you skipped.

**5. Worst remaining items.** Where the next round starts, in priority order.

**6. Cross-lane dependencies.** Anything you needed outside your lane and did
not touch.

**7. Rules discovered.** Anything you learned that should apply to future
rounds in this project. This is how a project accumulates standards instead of
re-learning the same lesson each round.

## What makes a report unusable

- Numbers with no command attached.
- "Tests pass" instead of the command and its output.
- Adjectives where a measurement belongs: cleaner, faster, more robust.
- A residuals section that says "none" on a round that hit three problems.
- Claiming an item is closed because the code now looks right.
