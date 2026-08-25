---
name: commit
description: >-
  Writes a Conventional Commit message for the current changes, grouped so
  each commit carries one concern, and commits them. Use when asked to commit,
  or to stage and commit work in progress.
when_to_use: >-
  Trigger phrases: commit this, commit my changes, write a commit message,
  stage and commit.
argument-hint: "[optional scope hint]"
allowed-tools: Read Grep Glob Bash
---

Read `docs/ConventionalCommits.md` for the format. This skill is how to apply
it, not a second copy of it.

## 1. Never commit to the default branch

Check the branch first. On `main`, create a descriptive one and switch to it
before anything else — direct pushes are rejected by the rulesets anyway, so
committing there just makes work you have to move.

## 2. Read what actually changed

`git status --porcelain` then `git diff` for unstaged and `git diff --cached`
for staged. Read the diff, not just the file names: the message has to
describe intent, and file names don't carry it.

## 3. Group by concern, not by file

One commit, one concern. Several unrelated edits sitting in the tree means
several commits, staged by pathspec — `git add -- <paths>` — not one
`git add -A`.

Ask which of these each change is, and split when the answer differs:

- a behaviour change,
- a fix for a specific defect,
- a rename or restructure with no behaviour change,
- formatting only,
- docs only,
- tests only.

Never sweep unrelated uncommitted work into a commit to save a step. If you
find changes you don't recognise, leave them alone and say so.

## 4. Write the message

`type(scope)!: description`, and pick the type from the list in
`docs/ConventionalCommits.md` — including the custom `infra` type for
Terraform, GitHub settings, and other DevOps changes.

- Imperative present tense: "change", not "changed" or "changes".
- The subject says **what** changed. It fits in one line and needs no body to
  make sense.
- Add a body when the change needs a *why* — the constraint you were working
  around, the thing you tried that didn't work, the bug the diff doesn't
  reveal on its own. Wrap it at 72 characters.
- Skip the body when the subject already says everything. A body that
  restates the subject is noise.
- `!` or a `BREAKING CHANGE:` footer when callers have to change.

## 5. Verify before committing

Show the message and the exact file list for each commit, then commit. After
each one, confirm with `git log --oneline -1` that it landed as intended.

Do not push. Pushing is a separate decision, and the human makes it.
