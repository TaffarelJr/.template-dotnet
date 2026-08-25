---
name: pr
description: >-
  Opens a pull request for the current branch, with a description built from
  the commits it actually contains. Use when asked to open, raise, or create a
  PR, or when a branch is ready to merge.
when_to_use: >-
  Trigger phrases: open a PR, raise a pull request, this is ready for review,
  push this up for review.
argument-hint: "[optional title]"
allowed-tools: Read Grep Glob Bash
---

## 1. Check the branch is ready

- Not on `main`. If it is, stop and say so — there is nothing to open a PR
  from.
- Nothing uncommitted that belongs in the PR. Show `git status --porcelain`
  and ask before including or ignoring anything unexpected.
- Rebased or merged up to date with `main`, so the diff shows only your work.

## 2. Read what the branch contains

`git log --oneline main..HEAD` for the commits, and
`git diff main...HEAD --stat` for the shape of the change.

The description comes from the **commits**, not from your memory of the
conversation. If the commits don't explain the change, that is a sign the
commits need fixing first, not that the PR body should compensate.

## 3. Write the description

Follow `.github/pull_request_template.md` if the repo has one — read it and
fill in its actual sections rather than inventing your own.

Otherwise: what changed, why, and how it was verified. Specifically —

- **Why**, in a sentence or two. The problem, not the diff.
- **What changed**, as bullets grouped by concern, mirroring the commits.
- **How it was verified** — the commands you ran and what they said. "Tests
  pass" is not verification; the output is.
- **Anything deliberately left out**, and why. This is the part reviewers
  most often need and least often get.

Link the issue it closes with `Closes #N` when there is one.

## 4. Push and open it

Push the branch, then `gh pr create` with the title and body. Use the first
commit's subject as the title when there is one commit, and a summary of the
concern when there are several — the PR title follows the same Conventional
Commit format as the commits.

Report the URL. Do not merge it, do not approve it, and do not request
reviewers unless asked.

## 5. Say what reviewers will check

Once open, `Analyze (actions)` and the other required checks have to pass,
and the rulesets block merging until they do. If a check is already failing,
say which, rather than leaving it to be discovered.
