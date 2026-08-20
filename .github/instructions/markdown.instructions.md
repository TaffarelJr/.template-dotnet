---
applyTo: "**/*.md"
description: Markdown conventions for docs and community health files
---

# Markdown

- Wrap prose at natural phrase breaks,
  one clause per line where that makes a diff easier to read.
- **Never reflow a paragraph you didn't otherwise change.**
  It turns a one-word edit into an unreviewable diff.
- Use reference-style links, defined at the bottom of the file,
  so body lines stay short.
  Group the definitions under two comments, each list alphabetical:
  - `<!-- Source Code URIs (alphabetical by file hierarchy) -->`
  - `<!-- Public URIs (alphabetical by name) -->`
- Mark a heading with `<!-- omit from toc -->`
  to keep it out of a generated table of contents.
- Align table pipes, and declare column alignment with `:---` or `:---:`.
- Diagrams: [Mermaid][mermaid] inline,
  [PlantUML][plantUml] for standalone documents.
- Trailing whitespace is significant in Markdown, so it isn't trimmed here.
  Don't add it on purpose.

<!-- Public URIs (alphabetical by name) -->

[mermaid]: https://mermaid.js.org
[plantUml]: https://plantuml.com
