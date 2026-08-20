---
applyTo: "**/*.{yml,yaml}"
description: YAML, GitHub Actions, and settings.yml conventions
---

# YAML

- Indent 2 spaces, never tabs. Quote a value only when it needs it.
- Put the schema comment on the first line where one exists,
  so editors validate the file:
  `# yaml-language-server: $schema=https://json.schemastore.org/...`
- Comment anything non-obvious —
  what a cron expression means, why a version is pinned —
  and link the source when there is one.

## GitHub Actions

- Declare `permissions:` on every job, granting the least it needs,
  with a trailing comment explaining why each one is there.
- Pin third-party actions to at least a major version tag
  (`uses: owner/action@v8`).
- Name every job and step. The name is what a reader sees in a failed run.
- Keep `env:` at the top of the workflow,
  for the values someone is most likely to want to change.
- Prefer a reusable workflow (`on: workflow_call`)
  over copying steps into another repo.

## settings.yml

[.github/settings.yml][settingsFile] is applied by the [Settings app][ghSettings],
and resolves `_extends` **recursively**,
so it inherits the whole template chain.
Declare only what differs from the immediate parent.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[settingsFile]: ../settings.yml

<!-- Public URIs (alphabetical by name) -->

[ghSettings]: https://github.com/repository-settings/app
