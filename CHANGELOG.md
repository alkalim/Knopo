# Changelog

Notable changes per release, newest first. Dates are release dates.

## v0.2.0 (2026-07-01)

Multi-graph windows, a native Back/Forward control, and visual polish.

**New**
- **A graph per window.** Each window now holds its own graph, so you can work on two graphs side by side (e.g. a roadmap beside your work). Open Graph (`⌘O`) switches only the focused window; native tabs (`⌘T`) each carry their own graph. Tab titles are graph-qualified only when a window's tabs span different graphs.

**Improved**
- Back/Forward is now the native segmented control: click to step, press-and-hold for history.
- Page and journal titles scale with content zoom (`⌘+` / `⌘-`).
- Larger right-sidebar card titles; the `⋯` menu now matches the close button's color.
- Query and embed results hang-indent wrapped lines under the bullet instead of the region edge.
- Release downloads are named by version, OS, and architecture (e.g. `Everseq-0.2.0-macos-arm64.zip`).

## v0.1.2 (2026-06-29)

A maintenance release: embed/reference reliability, indexing robustness, and macOS 15/26 visual consistency.

**Fixes**
- Block embeds (`{{embed ((id))}}`) resolve reliably: the target block's id is persisted when an embed or reference is created.
- Embedded headings are no longer clipped to the wrong line height.
- A duplicate block `id::` across files no longer aborts indexing, so the graph always opens.
- Page and tag renames now include just-typed edits that hadn't been saved yet.
- The journal home refreshes correctly when the set of days changes.
- Consistent window backgrounds and right-sidebar styling across macOS 15 and 26.

**Docs**
- Expanded README (screenshot, "How it compares" table); spec tidy-ups.

## v0.1.1 (2026-06-25)

Initial public release: a native (AppKit, no Electron) macOS outliner in the Logseq tradition, storing your graph as plain Markdown files.

- Outliner editing with byte-stable Markdown round-trips.
- Page links `[[Page]]`, block references and embeds, tags, and a small query language.
- Daily journal, linked/unlinked references, full-text search (`⌘K`), and a right sidebar for side-by-side reference work.
