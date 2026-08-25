---
name: review
description: >-
  Reviews the current change from three independent angles at once - security,
  performance, and repo conventions - then merges the results into one ranked
  list. Use before opening a pull request, or when asked to review, check, or
  critique changed code.
when_to_use: >-
  Trigger phrases: review this, review my changes, check this before I push,
  is this ready for a PR, what's wrong with this.
argument-hint: "[optional path or 'staged']"
allowed-tools: Read Grep Glob Bash Agent
---

Run three reviewers in parallel, then synthesise. Do not review the code
yourself first — that biases the synthesis toward what you already noticed.

## 1. Establish the diff

Work out what changed, and say so before delegating:

- An argument was given — review that path, or the staged changes for
  `staged`.
- On a branch — `git diff $(git merge-base HEAD main)..HEAD`.
- On the default branch with uncommitted work — `git diff HEAD`.
- Otherwise — `git diff HEAD~1`.

If nothing changed, say so and stop. Don't invent a scope.

## 2. Fan out

Dispatch all three in **one message** so they run concurrently:

- `security-reviewer`
- `perf-reviewer`
- `quality-reviewer`

Give each the same explicit scope — the diff command you settled on and the
file list — so they don't each pick a different interpretation. Vague task
descriptions are the main reason parallel reviewers duplicate each other.

## 3. Synthesise

One list, most severe first. Merge findings that are the same defect seen
through two lenses, keeping the sharper explanation and noting both angles.

Rank by consequence, not by which reviewer raised it:

1. Exploitable, or wrong results.
2. Will break under real load or real data.
3. Will cost the next reader time.
4. Convention drift.

For each finding: `path:line`, one sentence on the defect, one on the fix.

Then state what you did **not** find, in a line or two. A reviewer that only
ever reports problems gives no signal that the clean parts were looked at.

## 4. Stop

Report and stop. Do not start fixing anything unless asked — the point of the
review is to let the human decide what is worth changing.

If a reviewer returns something you can see is wrong, say so and drop it
rather than passing it through. Three agents reporting confidently is not the
same as three agents being right.
