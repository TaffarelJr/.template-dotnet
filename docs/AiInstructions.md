# AI Instructions <!-- omit from toc -->

One set of rules, several tools.
This document records which file each tool reads,
so a rule never has to be written twice.

#### Table of Contents <!-- omit from toc -->

- [Layout](#layout)
- [Why AGENTS.md is the canonical file](#why-agentsmd-is-the-canonical-file)
- [What belongs where](#what-belongs-where)
- [Agents and skills](#agents-and-skills)
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
| 📁[.claude/agents/][agentsFolder]                | Claude Code, VS Code Copilot                        | Specialist reviewers, read-only       |
| 📁[.github/agents/][ghAgentsFolder]              | Copilot cloud agent, VS Code                        | Thin mirrors of the above             |
| 📁[.claude/skills/][skillsFolder]                | Claude Code, all Copilot surfaces                   | Procedures, loaded only when used     |
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

## Agents and skills

Instructions say *how to write code*. Agents and skills say *how to do a
job* — and they are separate mechanisms with different reach.

### Skills reach further

A skill is a procedure in `.claude/skills/<name>/SKILL.md`, invoked as
`/<name>` or chosen by the model from its `description`. That one path is read
by Claude Code **and** by every Copilot surface, including code review, so a
skill is the closest thing to a write-once artifact in this repo.

Skills load lazily: the body costs nothing until it runs. That makes them the
right home for anything that grew out of `AGENTS.md` into a sequence of steps.

| Skill | Does |
| :---- | :--- |
| `/review` | Fans the four reviewers out in parallel, then merges and ranks |
| `/tdd` | Red, green, refactor - one behaviour per cycle |
| `/commit` | Groups changes by concern and writes a Conventional Commit |
| `/pr` | Opens a PR, described from the commits the branch actually holds |
| `/template-sync` | Reviews and resolves a sync PR from the parent template |

`/tdd` sets `disable-model-invocation: true`, so it only runs when you ask.
The other two are worth letting the model reach for on its own.

### Agents are for isolated, read-only work

A subagent gets its own context window and returns a summary. That pays off
when the work is **self-contained, verbose, and parallel** — which describes a
review and very little else.

| Agent | Lens |
| :---- | :--- |
| `security-reviewer` | Injection, secrets, authz, unsafe input, dependencies |
| `perf-reviewer` | Complexity, allocations, N+1, blocking async |
| `quality-reviewer` | Design and craft: SOLID, coupling, domain modelling |
| `test-reviewer` | Coverage of new paths, and whether the tests are any good |
| `docs-reviewer` | Whether the docs are still true after the change |

All five are read-only, by `tools: Read, Grep, Glob, Bash` plus
`disallowedTools: Write, Edit`. That restriction is the point: a reviewer that
can edit will quietly fix what it found instead of telling you, and you lose
the review.

`docs-reviewer` earns its place in a repo that documents itself this heavily.
A rename touches the README tables, `scripts/README.md`, comment-based help
and the instruction files, and stale documentation is worse than none.

`test-reviewer` exists because `quality-reviewer` is about design, not
verification. Folding tests into it left them reviewed by nobody in
particular, which is how test quality quietly rots.

### Five reviewers is the ceiling, not the default

`/review` sizes itself to the change: a two-file, fifty-line diff is read
inline with no subagents at all; a larger one gets only the lenses the diff
implicates; all five run before a pull request, or when the change touches
authentication, crypto, input parsing, secrets, workflow permissions, or a
public API. It states which reviewers it ran and which it skipped, so the
depth is visible and can be corrected.

That matters because parallel subagents cost roughly fifteen times a plain
conversation. The cost is worth it for a release candidate and ridiculous for
a renamed variable.

### Copilot parity

Skills need nothing: `.claude/skills/` is read by Claude Code **and** every
Copilot surface, including code review.

Agents need a little. `.claude/agents/` covers Claude Code and VS Code, but
the Copilot **cloud** agent only reads `.github/agents/*.agent.md`. So each
reviewer has a thin mirror there, whose body points back at the `.claude/`
file as the single source of truth. Only the `description` is duplicated,
because that field is the routing table and has to be inline — keep the two
in step, and `docs-reviewer` will notice if they drift.

The mirrors declare `tools: ['read', 'search', 'execute']`. Copilot has no
deny-list, so read-only comes from `edit` simply being absent — which is a
stronger guarantee than the allow-plus-deny pair on the Claude side. Claude's
own tool names are accepted there as aliases, but the canonical ones are
clearer about what is going on.

Custom agents are **not** used by Copilot code review. A check that has to
run there belongs in a skill.

### What deliberately isn't an agent

Anthropic's own multi-agent write-up puts the cost at roughly 15x the tokens
of a chat, and says the pattern suits "heavy parallelization" while
"most coding tasks lack sufficient parallelizable components". Work where
every participant needs the same context is called out as unsuitable.

So:

- **No developer agent.** The main conversation is the developer. A subagent
  starts with no history and would re-derive what you just established.
- **No architect agent.** Design needs back-and-forth, which is the one thing
  a subagent is bad at. It is a skill if it is anything.
- **No lead or orchestrator agent.** Claude Code's main loop already
  orchestrates. A lead agent adds a context boundary and becomes the single
  point of failure, for nothing. `/review` is that orchestration expressed as
  a skill instead.

The lever that actually controls delegation is each agent's `description`.
Vague ones are why parallel agents duplicate each other's work.

### Adding one

Both are additive per layer, like everything else here: drop in a file, edit
nothing inherited. Anything needing a language-specific command or a
language-specific rule belongs in the layer that owns it, not here:

| Layer | Worth adding |
| :---- | :----------- |
| `.template-dotnet` | `test-runner` agent (`dotnet test`, summarised); `/coverage` |
| `.template-nuget` | `api-compat-reviewer` — public surface changes and what they mean for the version; `/release` |
| a future UI template | `accessibility-reviewer` |
| a future Terraform template | `/plan-review` — read a plan and flag destructive changes |

This base repo carries only what every repo has.

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

[agentsFolder]: ../.claude/agents/
[skillsFolder]: ../.claude/skills/
[ghAgentsFolder]: ../.github/agents/
[instructionsFolder]: ../.github/instructions/
[copilotFile]: ../.github/copilot-instructions.md
[docsFolder]: ./
[agentsFile]: ../AGENTS.md
[claudeFile]: ../CLAUDE.md

<!-- Public URIs (alphabetical by name) -->

[agents]: https://agents.md
