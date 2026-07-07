# Changelog

Notable changes per release, newest first. Dates are release dates.

## v0.2.3 (2026-07-07)

Query pages by their properties, with editor and navigation fixes.

**Added**
- Query by page property: `{{query type:: person}}` now lists pages by their page properties (the un-bulleted `key:: value` lines at the top of a page), including pages that have only properties and no bullets. Matches appear as clickable page names.
- `[[` page-link autocomplete ranks closer matches first, so the page you are typing is not buried under looser fuzzy matches.

**Improved**
- Page properties at the top of a page render dimmed, like properties, instead of as plain text.

**Fixed**
- Links to pages whose names contain a slash (e.g. `Test/Page1`) open the correct page instead of an empty stub.
- Focusing a block no longer leaves a stale selection highlight, and a selection no longer spans multiple pages or panes at once.
- Completing a `[[` link no longer leaves a stray space before a following comma, period, or colon.

## v0.2.2 (2026-07-06)

Editor and window refinements.

**Added**
- Leading page content before the first bullet (e.g. a bare `# Heading`) now renders read-only above the outline instead of being hidden.

**Improved**
- The main view and right sidebar resize proportionally, and the sidebar width is remembered across restarts.
- Windows reopen at their saved size and position without a brief flash on launch.
- More tips on the welcome page for new graphs.

**Fixed**
- The link/reference autocomplete popup no longer stays stuck open after navigating away from the page.

## v0.2.1 (2026-07-02)

Backslash escaping, editor and query refinements.

**Added**
- Backslash escaping: a `\` before a special character makes it literal and skips autocomplete, so `\#tag` is plain text and `\$5` a dollar amount, not math.

**Changed**
- Query results list journal days newest-first.
- Undo reverts a single action at a time: typing is no longer folded into the following structural edit, so one `⌘Z` no longer wipes out more than you expect.

**Fixed**
- Escaped tokens no longer highlight as live tags/refs in the focused editor.
- Clicking the blank space after a wrapped link's last line no longer opens the link.

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
