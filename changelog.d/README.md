# changelog.d

One file per change that a user can see, assembled into `CHANGELOG.md` when a version is published. A branch adds its
fragment here, in the same commit as the change, and never edits `CHANGELOG.md` nor the version: two branches never conflict on them.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Fixed

**Scrolling no longer jumps**: what changed for the user, in one entry (no leading "- ").
```

- `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)): it picks the subsection.
- The text is one entry of the list, as it will read there, starting with a short bold summary. It may span lines;
  sub-items are indented `  - ` lines; no blank line, no heading.
- One change, one fragment. Two fragments may share a subject (the time keeps them apart).

`ocntools changelog new Fixed "**...**: ..."` writes one; `ocntools changelog check` (also in `ocntools check`) says whether
they are all well formed; `ocntools changelog preview` prints what the next version brings. `ocntools prepare <version>`
assembles them into a `## [<version>]` section, writes the version and deletes them (gui_toolkit's `changelog` package).
