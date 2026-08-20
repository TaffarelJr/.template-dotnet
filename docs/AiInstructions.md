# AI Instructions <!-- omit from toc -->

One set of rules, several tools.
This document records which file each tool reads,
so a rule never has to be written twice.

#### Table of Contents <!-- omit from toc -->

- [Layout](#layout)
- [Why AGENTS.md is the canonical file](#why-agentsmd-is-the-canonical-file)
- [What belongs where](#what-belongs-where)
- [Adding a file type](#adding-a-file-type)
- [Adding a tool](#adding-a-tool)
- [Known limits](#known-limits)

## Layout

| File                                            | Read by                                             | Contains                              |
| :---------------------------------------------- | :-------------------------------------------------- | :------------------------------------ |
| 📄[AGENTS.md][agentsFile]                        | Copilot, Codex, Cursor, Zed, Jules, and most others | Every rule that always applies        |
| 📄[CLAUDE.md][claudeFile]                        | Claude Code, VS Code Copilot                        | `@AGENTS.md` plus Claude-only notes   |
| 📁[.github/instructions/][instructionsFolder]    | Copilot (all surfaces), agents that follow a link   | Rules scoped to one file type         |
| 📄[.github/copilot-instructions.md][copilotFile] | Copilot                                             | A pointer, for surfaces that need one |
| 📁[docs/][docsFolder]                            | Humans; agents on demand                            | The reasoning behind the rules        |

Nothing is duplicated:
each rule is stated in exactly one of these files,
and everything else points at it.

## Why AGENTS.md is the canonical file

[AGENTS.md][agents] is the cross-tool convention,
and it is the only instruction file
that today's tools either read natively or can import:

- **GitHub Copilot** reads `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` directly,
  in addition to `copilot-instructions.md`.
- **Claude Code** reads only `CLAUDE.md`,
  but `CLAUDE.md` can `@`-import another file,
  and the import is expanded into context at session start.
  That is real transclusion, not a hint,
  so `CLAUDE.md` stays at three lines of its own content.

Instruction files must **state** each rule, not merely link to it.
Agentic tools will follow a Markdown link to `docs/`,
but Copilot code review and inline completion won't:
they get the instruction text injected and nothing more.
So the rule goes in the instruction file
and the rationale goes in `docs/`.

## What belongs where

- A rule that applies to every file → [AGENTS.md][agentsFile].
- A rule that applies to one file type →
  [.github/instructions/][instructionsFolder].
- The explanation, the how-to, the links, the tables → [docs/][docsFolder].

## Adding a file type

Add one file to [.github/instructions/][instructionsFolder],
named `<type>.instructions.md`,
with an `applyTo` glob in its front matter:

```markdown
---
applyTo: "**/*.cs"
description: C# conventions
---
```

This is **additive**: a template layer contributes its own file
and never edits an inherited one,
so template merges stay clean.
A .NET template adds `csharp.instructions.md`;
one with Terraform adds `terraform.instructions.md`.
This base repo carries only what every repo has —
Markdown, YAML, and PowerShell.

## Adding a tool

Most tools now read `AGENTS.md`, so there is nothing to do.
For one that doesn't, add a file it does read
whose entire content points at `AGENTS.md` —
for example a `GEMINI.md` for the Gemini CLI.
Never copy rules into it.

## Known limits

- **Front matter globs are Copilot's mechanism.**
  Claude Code's equivalent is `.claude/rules/*.md` with a `paths:` list,
  which VS Code Copilot also honours.
  Using it would mean a second small file per file type,
  so instead `AGENTS.md` tells agents
  to read the matching file in `.github/instructions/` themselves.
  Claude is good at this, but it is discretionary rather than automatic.
- **`applyTo` on github.com** applies to Copilot code review
  and the cloud agent. In the IDE it applies everywhere.
- **Instructions are context, not enforcement.**
  Anything that must happen every time
  belongs in a ruleset, a workflow, or a hook — not in a Markdown file.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[instructionsFolder]: ../.github/instructions/
[copilotFile]: ../.github/copilot-instructions.md
[docsFolder]: ./
[agentsFile]: ../AGENTS.md
[claudeFile]: ../CLAUDE.md

<!-- Public URIs (alphabetical by name) -->

[agents]: https://agents.md
