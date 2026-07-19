# Changelog

Notable changes per release, newest first. Dates are release dates.

## v0.5.0 (2026-07-19)

Much faster editing on large pages, and a body font-weight setting.

**New**
- Font weight setting (View ▸ Font Weight): Light, Medium, or Heavy body text.
- `***bold italic***` renders as bold italic.
- Selecting several blocks gives a dedicated right-click menu (copy or delete the selection), rendered blocks get the block menu without needing focus, and copying now puts exactly the selected blocks on the clipboard.

**Improved**
- Pages with many blocks and references open quicker, and pressing Enter or moving blocks updates only the affected rows instead of re-rendering the whole page. Typing no longer hitches around the auto-save.
- The journal home puts more air between a day's last block and the next day's separator.
- On macOS 26, the right sidebar is lighter, with subtler card borders and slightly larger card titles.

**Fixed**
- Inline-code backgrounds no longer smear across wrapped lines.
- Clicking a query or reference result reliably highlights the target block.
- Nested indentation scales with the content zoom.
- Shift+Up/Down shrinks a selection back toward its start instead of always growing it.

## v0.4.0 (2026-07-16)

Images, live TODO checkboxes in queries and embeds, and a native find bar.

**New**
- Insert images by dragging files in from Finder, pasting (a copied file or a screenshot), or the `/image` command. Drag an image's right edge to resize it. Sizes use `![alt|width]` (Obsidian) or Logseq's `{:width}` suffix - both are read, the pipe form is written.
- Check TODO / DONE items on and off directly in `{{query}}` results and `{{embed}}` blocks; the toggle updates the source block wherever it lives.
- Bare `http(s)://` URLs are clickable in rendered text without needing `[...](...)`.
- Select several blocks and press `Tab` / `Shift+Tab` to indent or outdent them together.

**Improved**
- The find bar (`Cmd+F`) is rebuilt from native controls - a real search field, a prev/next stepper, and a toolbar-material strip. It focuses reliably even when you were mid-edit, and typing stays fast on large pages.
- Right-clicking inside a block now shows a relevant menu instead of the stock text-editing one.

**Fixed**
- Pasting multi-line text into a quote block keeps it as one block instead of splitting it into several.
- TODO checkboxes no longer pushed the bullet out of alignment or added extra spacing before the next block.

## v0.3.0 (2026-07-09)

Everseq is now **Knopo**. Same app, new name: the download, the app bundle, and the `knopo://` link scheme all follow. A graph's index and settings folder is now `.knopo/` (the old `.everseq/` folder is ignored; the index rebuilds automatically, but per-graph favourites and sidebar layout do not carry over).

**New**
- Drag and drop: drag a block by its bullet to reorder it or move it under another parent. Dropping between rows inserts it there; dropping onto a block makes it that block's first child. Dragging a selected bullet moves the whole selection.
- Moving blocks with the keyboard (`⌥↑`/`⌥↓`) now works on a multi-block selection too, moving the selected blocks as one unit.
- Typing a formatting marker with text selected wraps the selection instead of replacing it: `[` `[` turns it into a page link, backticks into code, `*` `*` into bold, and so on.

**Improved**
- Lighter look for the outline: softer text color, smaller light-gray bullets that scale with zoom, and a rounded padded box behind inline code.

**Fixed**
- Pages that exist only as references (stubs) now show with the casing they were written in, not lowercase.

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
