# Template Chain <!-- omit from toc -->

How these repos are related, how a change travels between them, and who owns
which file when the two disagree.

This document is kept in **every** repo, including leaf code repos. A leaf has
no `scripts/` folder, so this is the only place the model is written down —
and a leaf still receives syncs from its parent, so its maintainer still needs
it.

#### Table of Contents <!-- omit from toc -->

- [The shape](#the-shape)
- [Why merge and not a template](#why-merge-and-not-a-template)
- [How a change travels down](#how-a-change-travels-down)
- [Who owns which file](#who-owns-which-file)
- [Settings inheritance](#settings-inheritance)
- [Re-parenting](#re-parenting)

## The shape

`.github` is the base. Every other repo is derived from it, directly or
through a template layer:

```text
.github                     the base: files every repo gets
 ├─ .template-dotnet        + everything a .NET repo needs
 │   └─ .template-nuget     + everything a published package needs
 │       └─ onion-seed.data a leaf: real code
 └─ my-service              a leaf derived straight from the base
```

Each repo has a `template` remote pointing at its **immediate parent**, and
the [Template Sync][syncFile] workflow merges from it. A leaf is a leaf
because nothing is derived from it — that is the only difference, and it is
why scaffolding removes `scripts/` from one.

## Why merge and not a template

GitHub's own "Use this template" is a **one-shot copy** with no ongoing
relationship. The whole point here is that a change made in `.github` keeps
flowing downstream, forever. So scaffolding deliberately creates an *empty*
repo and populates it from the `template` remote instead.

That choice rules out the other obvious approach. Render-based scaffolders —
Copier, Cookiecutter, Yeoman, `dotnet new` — expand placeholders into a fresh
tree, and combining one with `git merge template/main` does not work: the
child renders `name: {{ repo_name }}` to `name: my-service`, and every later
sync tries to put the placeholder **back**, conflicting on those lines
forever. Git cannot tell that the render was intentional.

The two models are mutually exclusive. Adopting a render tool would mean
replacing Template Sync with that tool's update command, not running both.

## How a change travels down

1. Change lands in a parent's `main`.
2. Template Sync runs in each child — nightly, or dispatched by hand.
3. It merges `template/main` into a `template-sync` branch and opens a PR
   titled *Merge changes from template repo*.
4. You review and merge it.

Two consequences worth knowing:

- **It is one hop at a time.** Merging into `.template-dotnet` does not touch
  `.template-nuget`; that repo's own sync has to run next. A change reaches
  the bottom of a three-layer chain only after three merges.
- **A clean sync opens no PR.** A freshly scaffolded repo is already a
  descendant of its parent, so there is nothing to merge. A PR appearing right
  after scaffolding means something diverged unexpectedly.

The `/template-sync` skill walks through reviewing and resolving one.

## Who owns which file

When a sync conflicts, this is the question to ask. Getting it backwards is
how a repo either loses its own customizations or drifts from its template.

- **`scripts/Helpers.psm1`, `scripts/New-Repo.ps1` — the template, always.**
  These are inherited verbatim and must stay byte-identical at every layer. A
  per-layer edit conflicts on every future change, forever. Layer-specific
  behaviour belongs in an additive `Helpers-<NN>-<slug>.psm1`, which nothing
  inherited has to be edited to add.
- **`.github/settings.yml` — this repo.** It declares only its own deltas;
  the rest is inherited through `_extends` at runtime, not through the file.
- **`.github/workflows/template-sync.yml` — split.** This repo owns
  `TEMPLATE_REPO_URL` and the schedule. The template owns the steps.
- **`README.md` — split.** A template owns its diagram highlight and its own
  tables; the base owns the shared structure. A leaf replaces the file
  outright, because a project README should describe the project.
- **`LICENSE` — this repo**, if it is private and carries the
  all-rights-reserved notice. Otherwise the template's MIT.
- **`Helpers-*.psm1`, `.claude/`, `.github/instructions/`, `docs/` —
  whichever side actually changed.** These are additive by file, so a conflict
  usually means both sides edited the same line. Read both.
- **Anything else — prefer the template**, and treat the conflict as a signal
  that this repo customized something it should not have.

## Settings inheritance

Each repo's `settings.yml` carries `_extends: <the repo it was derived from>`,
so it only states what differs — description, homepage, topics, name, and
visibility when private.

The [Settings app][ghSettings] resolves `_extends` **recursively**: it follows
each parent's own `_extends` until one has none. So a repo derived from
`.template-dotnet` also inherits everything from `.github` through the chain.
Nearest layer wins.

Things to know before editing a shared layer:

- **Editing a parent does _not_ re-sync its children.** The Settings app only
  runs when a push touches *that repo's own* `.github/settings.yml`. After
  changing a shared layer, each downstream repo needs its own `settings.yml`
  touched to pick the change up.
- Inheritance is **additive only** — a child cannot remove a label or ruleset
  an ancestor contributed. Keep shared layers minimal.
- Same-named rulesets merge, but their **inner** arrays (`rules`,
  `bypass_actors`, `conditions.ref_name.include`) concatenate without dedupe.
  Define each ruleset in exactly **one** layer, or give child rulesets
  distinct names.
- If a layer is **unreachable** — renamed, or private and not visible to the
  app's installation — the chain **truncates silently**. No error, just
  partially applied settings. Keep every layer accessible.
- Scaffolding emits a **bare** `_extends`, meaning the same owner. Don't
  hand-edit one to point at another owner: every hop resolves against *this*
  repo's owner rather than the parent's, so a cross-owner chain truncates
  unless every level spells out `owner/repo`.

## Re-parenting

Moving a repo to a different parent is two edits and a merge:

1. Repoint the `template` remote, and `TEMPLATE_REPO_URL` in
   [template-sync.yml][syncFile], at the new parent.
2. Change `_extends` in [settings.yml][settingsFile] to match.
3. Run Template Sync and resolve the merge using the ownership list above.

Because propagation is a merge rather than a render, git already knows which
commits the repo has, so a new parent sharing history with the old one merges
cleanly. Only genuinely new content conflicts.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[settingsFile]: ../.github/settings.yml
[syncFile]: ../.github/workflows/template-sync.yml

<!-- GitHub Repo URIs (alphabetical by name) -->

[ghSettings]: https://github.com/repository-settings/app
