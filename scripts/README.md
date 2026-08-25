# Repo scaffolding scripts

These scripts create a new repo **derived from the current repo**.
Each one creates a new repo on GitHub, and clones it next to this one locally.

| File                | Purpose                                                  |
| ------------------- | -------------------------------------------------------- |
| 📄 `Helpers.psm1`    | Shared helper module — the whole library                  |
| 📄 `New-Repo.ps1`    | Create a new repo — `-Kind Template` or `-Kind Code`      |
| 📄 `Helpers-*.psm1`  | _Optional, one or more per layer_ — that layer's additions |

`-Kind` drives the only two differences: a **Template** keeps `scripts/` so it can spawn its
own children, while **Code** removes `scripts/` and sets `is_template: false`.

## Usage

Every value is an **optional parameter**.
Pass what you want on the command line; anything you omit is **prompted for**
(with a default where reasonable — press ENTER to accept).
So you can run fully interactive, partially pre-filled, or fully unattended.

```powershell
# fully interactive - just answer the prompts (including -Kind)
./scripts/New-Repo.ps1

# partially pre-filled - prompts only for what's missing
./scripts/New-Repo.ps1 -Kind Template -Name dotnet

# fully unattended - no prompts at all (scriptable / batchable)
./scripts/New-Repo.ps1 -Kind Code -Name my-service `
    -Visibility Public -Description 'My service' -Homepage '' `
    -Topics 'dotnet, service' -CodecovToken $env:CODECOV -SkipManualPrompts
```

Parameters:

- `-Kind` — `Template` (a new layer) or `Code` (a leaf repo). Default: `Code`.
- `-Name` — the new repo name, in kebab-case. For `-Kind Template` the `.template-`
  prefix is optional: `dotnet` and `.template-dotnet` both give `.template-dotnet`.
- `-Visibility` — `Public` or `Private`. Default: `Public`.
  Applied at creation only; an existing repo keeps the visibility it has.
- `-Description` — the repo description for `settings.yml`.
  Required, one line, 350 characters or fewer.
- `-Homepage` — the repo homepage URL for `settings.yml`.
  An `http(s)` URL, or empty to omit it.
- `-Topics` — the repo topics for `settings.yml` (comma-separated).
  Normalised to what GitHub accepts: lowercase, letters, digits and hyphens.
- `-CodecovToken` — the `CODECOV_TOKEN` secret value
  (empty to skip; prompted without echo when omitted).
- `-SkipManualPrompts` — skip every prompt and the confirmation gate;
  required for a truly unattended run.

An explicit empty value (e.g. `-Homepage ''`) counts as "supplied"
and skips that prompt.

Every value is validated wherever it comes from, but the response differs:
a prompt says what is wrong and asks again, while a bad command-line value
or default throws, because there is nobody to ask. That matters because
PowerShell's own `[ValidateSet]` only checks parameters that were *bound* —
a prompt answer would otherwise go unchecked.

The GitHub **owner is a constant** (`$script:RepoOwner` in `Helpers.psm1`) —
this scaffolding is personal-only, so there's no owner parameter to pass. The scripts warn
if the repo's `origin` owner doesn't match it.

## Scaffold, then customize separately

Scaffolding produces a complete, known-good baseline and stops. Its work is grouped into
four commits, each with a single concern, so the history stays readable:

1. `chore: remove template-only files` — deletes the files that belong only to the base repo
   and de-links their rows in `README.md`. For a code repo it instead removes `scripts/` and
   replaces the whole README with a normal project one, since a leaf should document itself
   rather than the chain it came from.
2. `chore: retarget template references` — rewrites `owner/parent` → `owner/this-repo` in
   `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md` and `.github/ISSUE_TEMPLATE/*`, and
   moves the README diagram's highlight off the base repo onto the template row.
3. `ci: enable the template sync schedule` — points `TEMPLATE_REPO_URL` at the **immediate
   parent** and switches the nightly schedule on.
4. `chore: customize repo settings` — writes `.github/settings.yml`, and for a private repo
   replaces the inherited MIT license with an all-rights-reserved notice.

Plus one commit per layer, from each `Helpers-*.psm1` that contributes an entry point.

Each commit stages only its own pathspec, so a re-run can never sweep unrelated
uncommitted work into a `chore:` commit.

What it does **not** do is pause partway through for you to add repo-specific
customizations. Anything you want to change — dependabot ecosystems, `.editorconfig`,
`.gitattributes`, `.gitignore`, `README.md` — is just a normal commit you make afterwards
on a branch and merge as a PR. That's also required: once the Settings app applies the
rulesets, direct pushes to `main` are rejected.

## Idempotent & resumable

Re-running a script on the same repo is safe:

- The repo is created only if missing; API settings are checked before being set.
- The local clone is reused (never reset), so existing history is preserved.
- Each scaffolding commit is skipped if it's already in the repo's history —
  so **post-scaffold changes are never overwritten**,
  and a fully-scaffolded repo is a **no-op**.

If a run dies partway through, just run it again —
it verifies what's done and picks up where it left off.

## Inheritance model

- Every template repo carries this `scripts/` folder,
  so a new repo can be derived from **any** template at **any** level.
- `-Kind Template` **keeps** `scripts/` (the child can spawn its own children).
- `-Kind Code` **removes** `scripts/` and sets `is_template: false`
  (a code repo isn't derived from, and outside contributors have no use for the
  personal templating infrastructure).
- Keep `Helpers.psm1` **and** `New-Repo.ps1` **identical at every layer** so merges stay
  clean. Everything layer-specific goes in a `Helpers-<NN>-<slug>.psm1` instead — the same
  idea as `_extends` for settings: shared logic inherited, deltas declared locally.

### Per-layer customization: `Helpers-<NN>-<slug>.psm1`

Each layer contributes one **additive** module — never by editing an inherited one:

```text
Helpers-10-dotnet.psm1    added by .template-dotnet
Helpers-20-nuget.psm1     added by .template-nuget
Helpers-20-winui.psm1     added by .template-winui   (sibling; never sees nuget's)
```

Any `*.psm1` beside `Helpers.psm1` is a layer module — the name is a convention, not a
requirement, and nothing inherited needs editing to add one. They load in filename order,
which is why the convention carries a tier number. Import order is not what matters (every
module is imported `-Global`, and calls happen later); the tier fixes the order their entry
points **run** in, so a parent's scaffolding finishes before a child's starts.

Each module exports **helpers for its descendants to reuse**, and optionally one entry
point matching `Invoke-*Scaffold`:

```powershell
# .template-dotnet/scripts/Helpers-10-dotnet.psm1
function Rename-DotnetProject { param($RepoPath, $To) ... }   # reusable by lower layers

function Invoke-DotnetScaffold {
    param([hashtable]$Context)   # RepoPath, RepoName, Kind, OwnerRepo, SourceOwnerRepo
    Rename-DotnetProject -RepoPath $Context.RepoPath -To $Context.RepoName
}
Export-ModuleMember -Function Rename-DotnetProject, Invoke-DotnetScaffold
```

A lower layer can then call `Rename-DotnetProject` directly — the modules are imported
`-Global`, so every layer's helpers are visible to the layers below it. That's the point of
using modules rather than plain scripts.

The entry point is discovered from the module's own `ExportedFunctions`, so its name is never
coupled to the filename — only to the `Invoke-*Scaffold` pattern. **None** is fine: a layer
is free to contribute helpers only, and that is logged rather than treated as an error. Two
or more throws, because the order they would run in is ambiguous.

**Why one module per layer rather than one shared file:** with a single fixed name, every
layer would have to *edit* its parent's copy to append its steps — guaranteeing a merge
conflict on that file forever, and forcing the child to restate the parent's logic. Adding a
file instead means template merges stay clean and each layer owns exactly what it wrote.

Layers are read from the **source** template — wherever `New-Repo.ps1` is running from — so a
leaf still gets its ancestors' renames even though scaffolding deletes the leaf's own
`scripts/` folder. Base layers with nothing to customize contribute no file.

**Each layer owns its own commits.** A layer that does several unrelated things should make
several commits, by calling the exported `Invoke-GatedCommit` itself:

```powershell
Invoke-GatedCommit -RepoPath $Context.RepoPath `
    -Message 'chore: rename the placeholder project' -Body { ... }
```

Each commit is then independently gated, so a resumed run skips only what's already done.

`-Paths` is **optional**. Omit it and the body's changes are detected by diffing `git status`
around the call, staging exactly what it touched — which is what you want for anything
repo-wide such as a placeholder rename, where a hand-maintained path list would silently
leave renamed files out of the commit. Either way your own uncommitted work is excluded by
construction, so it can never be swept in.

If a layer changes files and commits nothing, the run warns — every later step stages an
explicit pathspec, so those changes would otherwise be left behind for good.

### AI agents and skills

`.claude/` carries the reviewers and procedures, and is inherited the same
way. See [docs/AiInstructions.md](../docs/AiInstructions.md) — including
which agent or skill belongs at which layer.

### Settings inheritance

Each new repo's `settings.yml` gets `_extends: <the repo it was derived from>`,
so it only overrides what differs — description, homepage, topics, name, and
visibility when private.

The rest of the model, including the recursive `_extends` resolution and the
several ways a shared layer can surprise you, is in
[docs/TemplateChain.md](../docs/TemplateChain.md). That document is kept in
leaf repos too, where this folder no longer exists.

### VS Code workspace

Each new repo also gets a `<repo>.code-workspace` multi-root workspace containing the
new repo **plus every template layer in its chain**, so template fixes can be made
without switching windows. `.gitignore` already ignores `*.code-workspace`, so it never
reaches a commit, and the script opens it in VS Code when finished.

The new repo is listed first (`folders[0]`), and `dotnet.defaultSolution` pins its
solution so C# Dev Kit doesn't adopt a template layer's placeholder `.sln`. If the repo
has no solution yet, that setting is `"disable"` — replace it once you add one.

## What's automated vs. manual

- ✅ **Automated:**
  - Repo creation, public or private
  - Actions: allowed to create and approve PRs
  - Private vulnerability reporting (falls back to the checklist if refused)
  - Release immutability (same fallback)
  - `CODECOV_TOKEN` secret
  - CodeQL default setup (post-push, for every language the chain registered)
  - Clone + remotes
  - File deletes and scoped find-replace
  - De-linking README rows for the deleted files (and their orphaned link refs)
  - Retargeting the README diagram at this repo's own tier
  - An all-rights-reserved `LICENSE`, for a private repo
  - Retargeting `TEMPLATE_REPO_URL` at the immediate parent + enabling the sync cron
  - `settings.yml` (with chained `_extends`, and `private: true` when private)
  - Commits and push
  - Running Template Sync **and verifying it finished clean with no PR**
  - `<repo>.code-workspace`, then opening it in VS Code
- 📋 **Manual** — printed as a checklist at the end
  (these have no API, so do them in the web UI):
  - Per-push branch/tag limit
  - Code review limits
  - Grouped security updates
  - Dependency graph — listed **only for a private repo**
    (a public one always has it on, with no toggle)
  - Verifying the description and topics landed on the home page

Release immutability used to be on the manual list. It has no field on the repo `PATCH`
endpoint, but GitHub later shipped dedicated endpoints
(`GET`/`PUT`/`DELETE /repos/{owner}/{repo}/immutable-releases`), so it is automated now. The
feature is still in preview, so a failure is non-fatal — it re-adds itself to the checklist.

The other three really are UI-only. Probing plausible endpoints (`code-review-limits`,
`moderation-settings`, `dependabot/grouped-security-updates`, `push-limits`,
`ref-update-limits`) returns the *generic* `docs.github.com/rest` 404 body, whereas a real
route returns a route-specific documentation anchor — a handy way to tell "endpoint exists but
is off/forbidden" from "no such endpoint".

Most other repo settings are applied automatically by the **Settings** GitHub App
(`repository-settings/app`) when `.github/settings.yml` is pushed.

## Alternatives considered

Why this is hand-rolled PowerShell rather than an off-the-shelf scaffolder.
[docs/TemplateChain.md](../docs/TemplateChain.md) covers the short version;
this is the evidence.

### ❌ GitHub's native template repositories

"Use this template" / `gh repo create --template` is a **one-shot copy** with no ongoing
relationship to the source. The entire point of the layered design is that a change made in
`.github` keeps flowing downstream to every descendant, forever. A native template gives you
the first copy and nothing after it. (This is why the scripts deliberately create an *empty*
repo and populate it from the `template` remote instead.)

### ❌ Render-based scaffolders **combined with** merge-based sync

Copier, Cookiecutter, Yeoman, `dotnet new` and friends all **render** a template containing
placeholders into a fresh tree. Combining any of them with a `git merge template/main` sync is
not a viable hybrid — the two mechanisms fight, permanently.

Reproduced in a scratch repo: a template file containing `name: {{ repo_name }}`, whose child
rendered it to `name: my-service`, conflicts on **every** later sync that touches those lines,
and the incoming side always tries to put the placeholder **back**:

```text
CONFLICT (content): Merge conflict in config.yml
<<<<<<< HEAD
name: my-service
=======
name: {{ repo_name }}          ← the template wants its placeholder back, every time
>>>>>>> template/main
```

Git has no way to know the render was intentional. So the two models are mutually exclusive:

| | Placeholders | Propagation | Per-repo values |
| --- | --- | --- | --- |
| **Merge model** _(used here)_ | none — the template's files are literally what children get | `git merge template/main` → PR | the scaffolder writes them as commits |
| **Render model** | yes, natural | re-render + apply the diff (`copier update`) | an answers file |

The render model avoids the conflict by never letting a placeholder reach the child: it
re-renders the *old* and *new* template with the same stored answers, diffs those two
renderings, and applies only that diff. Verified to apply cleanly on the same scenario.

**Consequence:** adopting a templating tool is not an incremental change — it means replacing
the Template Sync workflow with that tool's update command, not running both.

### ❌ Terraform / Pulumi for repo settings

Not adopted because the Settings app already owns repo settings, and pointing a second
declarative system at the same fields invites the two overwriting each other. There is also a
state-management burden that is hard to justify for a handful of personal repos. Worth
revisiting only for settings the Settings app genuinely cannot express.

### ⏳ Still open

Whether to switch wholesale to the **render model** (Copier being the obvious candidate) is
genuinely undecided, and became a live option once template repos no longer needed to be
runnable. The deciding question is whether Copier supports **chained** templates —
`.github` → `.template-dotnet` → leaf, each layer independently updatable — which must be
verified, not assumed. A serious alternative also worth weighing: **flatten the hierarchy**
into one parameterised template with feature flags instead of a multi-level chain.

Note that `settings.yml` inheritance is unaffected either way: it is resolved server-side by
the Settings app, independent of how files are templated.
