---
name: review
description: >-
  Reviews the current change, scaling the depth to the change itself - from an
  inline read for a one-liner, up to five specialist reviewers in parallel
  before a pull request. Use when asked to review, check, or critique changed
  code.
when_to_use: >-
  Trigger phrases: review this, review my changes, check this before I push,
  is this ready for a PR, what's wrong with this.
argument-hint: "[optional path, 'staged', or 'full']"
allowed-tools: Read Grep Glob Bash Agent
---

Scale the review to the change. Five parallel subagents cost roughly fifteen
times a plain conversation — right before a pull request, absurd for a
renamed variable.

## 1. Establish the diff

Work out what changed, and say so before deciding anything:

- An argument was given — review that path, or the staged changes for
  `staged`. `full` forces every reviewer regardless of size.
- On a branch — `git diff $(git merge-base HEAD main)..HEAD`.
- On the default branch with uncommitted work — `git diff HEAD`.
- Otherwise — `git diff HEAD~1`.

If nothing changed, say so and stop. Don't invent a scope.

## 2. Choose the depth

Read `--stat` and the file list first, then pick:

- **Two files or fewer and under ~50 lines, with no new public surface** —
  review it yourself, inline. No subagents.
- **Anything larger** — pick the lenses the diff actually implicates.
- **Pre-PR, or `full`, or it touches authentication, crypto, input parsing,
  secrets, workflow permissions, or a public API** — run all five. Don't
  economise on those.

Pick lenses by what the change contains:

- **`security-reviewer`** — handles input, credentials, tokens, paths, shell
  or SQL; changes a workflow `permissions:` block; adds a dependency.
- **`perf-reviewer`** — adds or changes a loop, a query, an I/O call, an
  async path, or anything that runs per item.
- **`quality-reviewer`** — adds or restructures logic, types, or control
  flow. Skip for a pure rename or a formatting pass.
- **`test-reviewer`** — changes behaviour, or touches test files. Skip when
  the change genuinely cannot have a test.
- **`docs-reviewer`** — renames anything, adds or removes a file, changes a
  parameter or a step, or edits a document. In this repo that is most
  changes, because it documents itself heavily.

A docs-only change usually needs `docs-reviewer` alone. A formatting pass
usually needs nothing at all.

## 3. Fan out

Dispatch the chosen reviewers in **one message**, so they run concurrently.

Give each the *same* explicit scope — the diff command you settled on and the
file list. Vague task descriptions are the main reason parallel reviewers
duplicate each other's work.

## 4. Say what you ran

Before the findings, one line: which reviewers ran, which you skipped, and
why. A review whose depth is invisible can't be trusted or corrected.

## 5. Synthesise

One list, most severe first. Merge findings that are the same defect seen
through two lenses, keeping the sharper explanation and noting both angles.

Rank by consequence, not by which reviewer raised it:

1. Exploitable, or wrong results.
2. Will break under real load or real data.
3. Untested behaviour that can regress silently.
4. Documentation that is now wrong — a reader will trust it and be misled.
5. Design that will cost the next reader time.
6. Convention drift, or documentation that is merely missing.

For each finding: `path:line`, one sentence on the defect, one on the fix.

Then state what you did **not** find, in a line or two. A reviewer that only
ever reports problems gives no signal that the clean parts were looked at.

## 6. Stop

Report and stop. Do not start fixing anything unless asked — the point of the
review is to let the human decide what is worth changing.

If a reviewer returns something you can see is wrong, say so and drop it
rather than passing it through. Five agents reporting confidently is not the
same as five agents being right.
