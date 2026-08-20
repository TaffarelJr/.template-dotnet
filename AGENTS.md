# Agent Instructions

Rules for AI coding agents working in this repo.
Human contributors should start with [CONTRIBUTING.md][contribFile].

This file is the short version and always applies.
The reasoning behind each rule is in [docs/Styleguide.md][styleguideFile].

## Before changing anything

- Match the surrounding code first.
  Its existing patterns, spacing, and naming outrank every rule below.
- Follow instructions written in code comments where you find them.
- Read the rule file in [.github/instructions/][instructionsFolder]
  that matches the file type you are about to edit.

## Never commit to `main`

Create a descriptive branch (for example, `awesome-feature-name`),
then open a pull request.
Direct pushes to `main` are rejected by the repo rulesets anyway.

## Line width

- **80 characters** is the target. Wrap by then wherever you can.
- 100 is acceptable occasionally; 120 is the hard limit.
- Break at commas, periods, semicolons, or the end of a complete phrase —
  never mid-thought.
  In code, stack arguments and chained calls vertically.
- **Don't orphan a single word.**
  If wrapping would leave one word alone on the next line,
  run a few characters over the limit instead.
- Relax this only where wrapping is impossible, such as a long URL.

See [docs/VerticalRulers.md][rulersFile] for details.

## Files

- UTF-8 without a BOM, a final newline, and no trailing whitespace.
- Indent with 4 spaces; 2 for Markdown, YAML, JSON, HTML, and CSS.
- CRLF, except where the format requires LF (`*.sh`, `*.vim`).
- The source of truth is [.editorconfig][editorConfigFile]
  and [.gitattributes][gitAttributesFile].
  Don't restate their rules anywhere else.

## Comments

- Explain **why**, not **what**.
  Needing to explain what the code does means the code should be refactored.
- Keep them short. Walls of text don't get read.
- Delete a comment the moment it stops being true.
  A stale comment is worse than no comment.

## Commits

- [Conventional Commits][ccFile]: `type(scope)!: description`,
  plus a custom `infra` type for Terraform, GitHub settings,
  and other DevOps changes.
- Imperative present tense: "change", not "changed" or "changes".
- One concern per commit. Group related edits together
  rather than committing file by file.

## Code

- Small functions. Focused, cohesive classes. Follow [SOLID][solid].
- Favor explicit over implicit,
  and consistency over any particular convention.
- Document public types and members.
- Validate all input, apply least privilege,
  and keep dependencies current.
- Include tests: unit tests covering every public code path,
  plus a few integration tests.
  Aim for 80%+ coverage without sacrificing test quality for the metric.

## Emoji

Functional emoji are welcome:
status markers (✅ ⚠️ ❌), file trees (📁 📄), and scanning aids in tables.
Decorative emoji are not.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[instructionsFolder]: ./.github/instructions/
[ccFile]: ./docs/ConventionalCommits.md
[rulersFile]: ./docs/VerticalRulers.md
[styleguideFile]: ./docs/Styleguide.md
[editorConfigFile]: ./.editorconfig
[gitAttributesFile]: ./.gitattributes
[contribFile]: ./CONTRIBUTING.md

<!-- Public URIs (alphabetical by name) -->

[solid]: https://en.wikipedia.org/wiki/SOLID
