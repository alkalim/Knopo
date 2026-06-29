# Everseq — Specification

A local-first, single-user outliner: everything is a block, pages are trees of blocks, knowledge is connected through `[[Page]]` references and block references, and a daily journal is the default entry point.

This document specifies functional behavior, the data model, the on-disk format, and the chosen technology stack (§15). Everseq is a native macOS application.

---

## 1. Goals and non-goals

### Goals

- Outline editor where every piece of content is a **block** in a tree.
- Plain **Markdown files** on disk as the source of truth; the app must never hold data hostage.
- **Page references** (`[[Page]]`), **block references** (`((block-id))`), and a **linked-references** panel.
- **Tags** as lightweight labels (`#tag`) — a separate namespace from pages.
- **Journal**: one page per day, auto-created, reverse-chronologically browsable.
- **Favourites** and **recent pages** for navigation.
- Fast full-graph operations (backlinks, search) on graphs up to ~10,000 pages / ~1,000,000 blocks.

### Non-goals

- Whiteboards, flashcards, PDF annotation, task management beyond plain text.
- Queries — deferred, not rejected: v1 ships without them but must stay forward-compatible (§17).
- Plugin system, themes beyond light/dark, custom CSS.
- HTTP server, sync service, real-time collaboration, multi-user anything.
- Mobile apps and cross-platform support. Native macOS only.
- WYSIWYG rich-text editing. Blocks are edited as Markdown source with live preview when not focused (see §5.4).

---

## 2. Core concepts

| Concept | Definition |
|---|---|
| **Graph** | A directory on disk containing all pages of one knowledge base. |
| **Page** | A named document consisting of an ordered tree of blocks. Maps 1:1 to a Markdown file. |
| **Block** | A single outline node: one Markdown paragraph plus its children. The atomic unit of editing, referencing, and folding. |
| **Journal page** | A page whose name is a date; created automatically. |
| **Page reference** | An inline link `[[Page Name]]` from a block to a page. |
| **Block reference** | An inline transclusion `((block-id))` of one block into another location. |
| **Tag** | An inline label `#tag`. Not a page; has no content of its own. |
| **Linked references** | The list of blocks elsewhere in the graph that reference the current page, shown below the page content. |

---

## 3. Data model

### 3.1 Block

```
Block {
  id:        UUIDv4            // stable for the block's lifetime
  content:   string            // raw Markdown source, single logical paragraph
  children:  Block[]           // ordered
  collapsed: bool              // fold state (persisted)
}
```

Derived (indexed, not stored): the set of page references, block references, and tags parsed out of `content`.

Rules:

- A block's `id` is assigned at creation and never changes, including across moves between pages. This is what makes block references durable.
- `content` may be empty (placeholder blocks are allowed).
- Block order within a parent is significant and user-controlled.

### 3.2 Page

```
Page {
  name:      string            // unique, case-insensitive; display case = case at creation
  blocks:    Block[]           // top-level blocks
  isJournal: bool              // derived from name/location
  properties: map<string, string>   // optional page-level key:: value pairs (front block)
}
```

Rules:

- Page names are unique **case-insensitively**: `[[Project X]]` and `[[project x]]` resolve to the same page. The display name uses the casing from when the page was first created; renaming can change it.
- Forbidden characters in page names: `/ \ # [ ]` and leading/trailing whitespace. `/` is reserved for hierarchy (see below).
- **Namespaces**: a `/` in a page name (`[[Projects/Outliner]]`) creates a flat page whose name contains the separator. The page browser groups such pages hierarchically for display, but there is no inheritance or other semantics.
- A page exists if (a) its file exists, or (b) it is referenced from somewhere. Case (b) is a **stub page**: it has no file until the user adds content to it. Linked references still work on stubs.

### 3.3 Tag

A tag is nothing but a normalized string. The system maintains a derived index:

```
TagIndex: map<tag-name, Set<block-id>>
```

There is no tag entity to open as a document, no tag content, no tag properties. See §8.

---

## 4. On-disk format

### 4.1 Layout

```
<graph-root>/
  pages/
    Project X.md
    Projects%2FOutliner.md        // '/' percent-encoded in filenames
  journals/
    2026-06-10.md
  .everseq/
    config.json                   // favourites, settings
    cache.db                      // rebuildable index (SQLite); safe to delete
```

- One page = one file. Filename = page display name with filesystem-unsafe characters percent-encoded.
- `cache.db` holds the block/reference/tag index and recent-pages list. It is a **cache**: deleting it loses nothing except recents; the app rebuilds it from the Markdown files on next start.
- `config.json` holds favourites and user settings. It is authoritative (not rebuildable) and should be committed/backed up along with pages.

### 4.2 File format

Pages are serialized as Markdown bullet lists; indentation (2 spaces) encodes the tree.

```markdown
- First top-level block
  - A child block
    id:: 6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f
  - Another child, **bold** and a link to [[Project X]] #urgent
- Second top-level block ((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))
```

Rules:

- Each bullet (`- `) is one block. Continuation lines indented to the bullet's content column belong to the same block (multi-line blocks: code fences, quotes).
- `id:: <uuid>` is written as a property line under a block **only when the block is referenced** by at least one block reference. Unreferenced blocks carry no persisted id (their UUIDs live only in the cache), keeping files clean. Once written, an `id::` is never removed automatically.
- `collapsed:: true` is persisted the same way, only when true.
- Page properties (`key:: value` lines in the first block) are supported minimally: parsed, displayed, and round-tripped, but no semantics are attached except `title::` (overrides display name).
- Files edited externally are detected via file-watcher and reloaded; if the page is open with unsaved changes, last-writer-wins with the losing version saved to `.everseq/conflicts/`.
- The app must **round-trip** files byte-stably: opening and saving a page without edits must not change the file.

---

## 5. Markdown support

### 5.1 Inline syntax (rendered within a block)

| Syntax | Rendering |
|---|---|
| `**bold**`, `*italic*`, `~~strike~~` | as usual |
| `` `code` `` | inline code |
| `==highlight==` | highlighted text |
| `[label](url)` | external link — underlined and marked with a trailing ↗ to distinguish it from internal references; opens in system browser |
| `![alt](path-or-url)` | inline image; relative paths resolve against `<graph-root>/assets/` |
| `[[Page Name]]` | page reference (§6), rendered in the accent color. **Display vs. identity:** the link *target* is the literal name in the file, but the rendered *text* is the page's display title — a date reference like `[[2026-06-10]]` shows as "Jun 10th, 2026". Faint `[[ ]]` brackets around the name are an optional per-app viewing preference (off by default), not stored in the file |
| `((uuid))` | block reference (§7) |
| `#tag`, `#[[multi word tag]]` | tag chip (§8) |
| `$...$` | inline math (KaTeX-compatible subset) |

### 5.2 Block-level syntax

A block whose content starts with a recognized prefix renders accordingly:

| Prefix | Rendering |
|---|---|
| `# ` … `###### ` | heading (heading level is visual only; outline depth is independent) |
| `> ` | block quote |
| `#+BEGIN_QUOTE` … `#+END_QUOTE` | block quote (org-mode container form; render-only, recognized for compatibility — the markers round-trip untouched) |
| ```` ``` ```` fenced code | code block (the whole fence is one block). Inside a focused fence, `Enter` inserts a newline and `Tab` inserts an indent, instead of acting on the outline. No per-language syntax highlighting in v1 — the language tag is stored and shown, code renders monospace |
| `---` alone | horizontal rule |
| `TODO ` / `DONE ` | checkbox-style rendering with click-to-toggle; stored as the literal keyword (no task engine behind it). `Cmd+Enter` in the focused block cycles plain → `TODO` → `DONE` |

Tables (GitHub style) render read-only inside a block; editing happens in raw source.

### 5.3 Explicitly unsupported

- Setext headings, HTML passthrough (HTML is escaped and shown literally), footnotes, ordered-list semantics (a block starting with `1.` is just text).

### 5.4 Editing model

- The focused block shows **raw Markdown source** in a plain text editor.
- Unfocused blocks show the **rendered** form.
- `Enter` creates a sibling block below; `Shift+Enter` inserts a newline inside the block; `Tab` / `Shift+Tab` indent/outdent; `Backspace` at start of an empty block deletes it and focuses the previous block.
- `Alt+↑/↓` moves a block (with subtree) among its siblings.
- `Cmd+Enter` toggles the focused block's `TODO`/`DONE` state (§5.2).
- Clicking a bullet **zooms** into that block (it becomes the temporary page root, with a breadcrumb back). Clicking the fold triangle toggles `collapsed`. An empty leaf block hides its bullet while unfocused (the gutter is kept, so nothing shifts).

### 5.5 Slash commands

Typing `/` at a word start in the focused block opens the command popup — the same hand-rolled panel as the `[[` / `((` / `#` autocompletes: continued typing filters by command-name prefix, `↑`/`↓` navigate, `Enter`/`Tab` commit, `Esc` dismisses. Committing always **removes the typed trigger** (the `/` and any filter text) before applying the command's edit. While the popup is open, `Enter` commits the popup and never splits the block.

All commands are one undo step together with the keystrokes of the current edit session (§13).

| Command | Effect |
|---|---|
| `/today`, `/tomorrow`, `/yesterday` | inserts the corresponding `[[<ISO date>]]` reference (§10) |
| `/date` | opens a calendar to insert `[[<ISO date>]]` for any chosen day (§5.5.4) |
| `/quote` | prefixes the block with `> ` (block-level quote, §5.2); no-op if the prefix is already present |
| `/code-block` | inserts a fenced code block skeleton (§5.5.1) |
| `/link` | inserts a Markdown link skeleton (§5.5.2) |
| `/page-embed`, `/block-embed` | inserts a `{{embed [[…]]}}` / `{{embed ((…))}}` skeleton and opens the page / block picker inside it (§5.5.3, §7.6) |
| `/query` | inserts a `{{query …}}` skeleton with the caret inside, ready to type a filter (§17) |

#### 5.5.1 `/code-block`

- Committing inserts, at the trigger position:

  ~~~
  ```
  ⟨empty line⟩
  ```
  ~~~

  i.e. the literal text `` ```\n\n``` ``, and places the caret **at the end of the opening fence line**, so typing a language tag (`` ```swift ``) is immediate and optional.
- The skeleton renders as a syntax-highlighted code block (§5.2) when the fence starts the block — the normal case, since `/` commands trigger at word starts and code blocks are typically created in empty blocks. If the trigger was mid-text, the fence is inserted verbatim at the caret and renders literally; the command does not try to rearrange surrounding content.
- **Enter inside a fence**: when the focused block's content starts with an opening fence and the caret is on or before the closing fence line, `Enter` inserts a newline (as `Shift+Enter` does) instead of splitting the block — a code block is one block (§5.2), and splitting mid-fence would corrupt it. With the caret after the closing fence line, `Enter` splits as usual.
- No language autocomplete in v1; the language tag is free text.

#### 5.5.2 `/link`

- Committing the command removes the trigger text and opens a small **link panel** anchored at the caret (popover-style, like the autocomplete panel — not a window-modal sheet), with two fields:
  - **Label** — initial keyboard focus.
  - **URL** — pre-filled when the clipboard holds a single plausible URL (one line, scheme `http`/`https`/`file`); otherwise empty.
- Keyboard flow: `Tab` moves between fields, `Enter` in either field confirms, `Esc` cancels. Clicking outside the panel cancels.
- On confirm, `[label](url)` is inserted at the trigger position and the caret lands after the closing `)`. If the label is empty, the URL doubles as the label (`[https://…](https://…)`).
- Confirm is disabled while the URL field is empty; no further validation — a malformed URL is the user's to own and renders per §5.1 (external link opening in the system browser).
- On cancel, nothing is inserted (the trigger was consumed when the command was chosen).

#### 5.5.3 `/page-embed`, `/block-embed`

- Both appear under the prefix `embed` as well as their own names, so typing `/embed` lists both.
- Committing replaces the trigger with a skeleton — `{{embed [[]]}}` (page) or `{{embed (())}}` (block) — and drops the caret between the inner brackets, which immediately re-opens the matching picker (the page autocomplete §6.1, or the block search §7.1) so the target is chosen inline.
- Choosing a target inserts `[[Name]]` / `((uuid))` between the inner brackets, **absorbing** the skeleton's pre-supplied closing `]]` / `))` so the result is exactly `{{embed [[Name]]}}` / `{{embed ((uuid))}}` (never a doubled close). A block target also persists `id::` on its source block, as with any `((ref))` (§7.1).
- Dismissing the inner picker (`Esc`) leaves the skeleton in place as ordinary, editable text; an incomplete `{{embed [[]]}}` is not a valid embed and renders literally until completed (§7.6).

#### 5.5.4 `/date`

- Committing the command removes the trigger and opens a small **date picker** anchored at the caret (a graphical month calendar, popover-style like `/link` — not a window-modal sheet), preselecting today.
- Click a day to select it; `Enter` (or the Insert button) confirms, `Esc` (or clicking outside) cancels. Double-clicking a day confirms immediately.
- On confirm, `[[<ISO date>]]` for the chosen day is inserted at the trigger position (the same stable ISO form `/today` uses, §10), so it renders as the pretty date title and links to that journal page. On cancel, nothing is inserted.
- This is what makes `/date` reference *any* day rather than only today; free-form natural-language date entry ("next friday") remains deferred.

Acceptance criteria for §5.5.1–5.5.4:

1. In an empty block, `/code-block` + `Enter` yields a block whose content is `` ```\n\n``` `` with the caret after the opening backticks; typing `swift`, `Enter`, `let x = 1` produces a rendered Swift code block when focus leaves.
2. `Enter` with the caret inside the fence inserts newlines; `Enter` after the closing fence creates a sibling block.
3. `/link` opens the panel with focus in Label; with `https://example.org` on the clipboard the URL field is pre-filled. Label "docs" + Enter inserts `[docs](https://example.org)` with the caret after `)`. Empty label inserts the URL as label. Esc inserts nothing.
4. `/block-embed` + selecting a block via the inner search yields exactly `{{embed ((<uuid>))}}` (no doubled `))`), which renders as a read-only transclusion of that block's subtree (§7.6); `/page-embed` + selecting "Foo" yields `{{embed [[Foo]]}}`.
5. `/date` opens the calendar; picking June 10 2026 inserts `[[2026-06-10]]` (rendering as "Jun 10th, 2026"); `Esc` inserts nothing.
6. All commands replace the typed trigger text exactly (no stray `/`), participate in the edit session's undo step, and round-trip byte-stably like any block content (§4.2).

### 5.6 Block background colors

A block can carry a background color, rendered as a soft rounded box behind its content.

- **Setting.** Right-click the block's bullet → **Background Color** → pick a preset, or **None** to clear. The current color is checkmarked.
- **Palette.** A fixed set of named colors — gray, red, orange, yellow, green, blue, purple, pink — each appearance-aware (soft pastel in light, muted in dark). Names, not hex, so the tint adapts and stays portable.
- **Storage.** A *hidden* block property `background-color:: <name>`. Like `id::` / `collapsed::` (§4.2), it round-trips in the file but is never shown as editable property text or rendered as a `key: value` line — only its effect (the colored box) appears. Unknown values render no box.
- **Scope.** v1 tints the block's own content area; it does not extend the color over the block's children.

---

## 6. Page references — `[[Page]]`

### 6.1 Syntax and behavior

- Typing `[[` opens an autocomplete popup listing pages by fuzzy match on name, ordered by recency of access, including an option to create a new page with the typed text.
- A committed reference is stored literally as `[[Page Name]]` in the block's Markdown.
- Rendered as a link; click navigates to the page. `Cmd+Click` opens it in the right sidebar.
- Referencing a non-existent page creates a **stub** (see §3.2) — navigable, shows linked references, gets a file only once content is added.
- Hovering a reference shows a preview popover of the page's first ~10 blocks.

### 6.2 Renaming pages

Renaming a page rewrites every `[[Old Name]]` occurrence across the graph to `[[New Name]]` (case-insensitive match, preserving surrounding text), then renames the file. This is a single undoable operation and is the only cross-file write the app performs implicitly.

### 6.3 Aliases — out of scope

No `alias::` support in v1. One page, one name.

---

## 7. Block references — `((block-id))`

### 7.1 Creating

- **Copy block ref**: block context menu → "Copy block reference" puts `((uuid))` on the clipboard and persists `id::` into the source file (§4.2).
- Typing `((` opens an autocomplete popup that searches block content across the graph; selecting a result inserts its reference (assigning a persisted id if needed).

### 7.2 Rendering

- A `((uuid))` renders as the **live content of the referenced block** (transcluded), visually distinguished (dotted underline). Children of the referenced block are not transcluded.
- Click navigates to the source block (its page, zoomed to the block). The transcluded text is not editable in place in v1.
- The referenced block's render updates immediately when the source changes.

### 7.3 Broken references

If the target id does not exist in the graph (deleted block, file removed), render `((uuid))` literally with a "broken reference" style. Never silently drop or rewrite it.

### 7.4 Deleting referenced blocks

Deleting a block that has incoming references prompts: *"This block is referenced in N places. Delete anyway?"* On confirm, the references become broken (§7.3). No automatic inlining.

### 7.5 Counting as a reference

A block reference to block B counts as a **linked reference to B's page** (it appears in that page's Linked References section, §9). An embed (§7.6) counts the same way.

### 7.6 Embeds — `{{embed …}}`

A block whose content contains `{{embed ((uuid))}}` or `{{embed [[Page Name]]}}` renders a **read-only transclusion** of the target:

- `{{embed ((uuid))}}` shows the referenced block **and its full subtree** (children included — unlike a plain `((ref))`, which shows only the one block's first line).
- `{{embed [[Page Name]]}}` shows that page's blocks.
- The transclusion is rendered as an indented, bulleted, read-only list. Clicking it navigates to the source (block or page). It is **not editable in place** (v1) — to edit, navigate to the source. This is the same read-only-list machinery as the tag view (§8.2).
- An embed registers as a reference to its target (§7.5): a block embed is a block reference, a page embed a page reference — so backlinks work.
- Nested embeds inside an embedded subtree render literally (not expanded), preventing cycles. Very large embeds are capped.
- **Editing:** the host block is edited as raw source — the focused block shows the literal `{{embed …}}` text; the rendered (unfocused) form shows the transclusion.
- **Liveness:** an embed reflects the source's current content on (re)load; a same-page edit refreshes it immediately, a cross-page source edit refreshes on next navigation/reload.
- An unresolved/broken embed renders the literal `{{embed …}}` text in a broken style; it is never rewritten.

`{{embed …}}` and `{{query …}}` (§17) are interpreted; any other `{{…}}` still renders literally and round-trips byte-stably.

---

## 8. Tags — `#tag`

**Design decision: tags are labels, not pages.** `#urgent` creates no page, has no content, and never appears in the page list or `[[` autocomplete.

### 8.1 Syntax

- `#word` — letters, digits, `-`, `_`, no leading digit requirement, terminated by whitespace/punctuation.
- `#[[multi word tag]]` — bracketed form for tags containing spaces. Despite the bracket syntax it is still a tag, not a page reference.
- Tags are case-insensitive (`#Urgent` ≡ `#urgent`); displayed lowercase.
- `#` followed by space or inside code spans/fences is not a tag.

### 8.2 Behavior

- Rendered as a chip. Clicking a tag opens a **tag view**: a generated, read-only result list of all blocks carrying that tag, grouped by page, each block rendered with breadcrumb and click-to-navigate. The tag view is not a page — it can't be edited, referenced, or linked to. A tag *can* be favourited, however (§11.1).
- Typing `#` opens autocomplete over existing tags.
- A **Tags** entry in the left sidebar lists tags with usage counts, ordered most-used first; the displayed list is capped (15 in v1, later a setting). Clicking opens the tag view. The usage count is the number of occurrences (a tag appearing twice in one block counts twice).
- Tag occurrences do **not** appear in any page's Linked References (there is no page to link to).
- Renaming a tag (from the tag view's menu) rewrites all occurrences across the graph, same machinery as page rename.

---

## 9. Linked references

Every page (including journal pages and stubs) shows below its content:

### 9.1 Linked References

- All blocks anywhere in the graph whose content contains `[[This Page]]`, plus blocks containing a `((ref))` to one of this page's blocks (§7.5).
- Grouped by source page; each group collapsible; each block rendered with its breadcrumb (page › ancestor blocks) and **editable in place** — edits write through to the source page.
- A block matches if the reference appears in the block itself; ancestors/descendants of matching blocks are shown as context (one level of children, collapsed) but don't count toward the match total.
- Count badge in the section header. Section collapsed by default if count is 0 (hidden entirely).
- Self-references (a page linking to itself) are excluded.

### 9.2 Unlinked References

- Blocks containing the page's name as plain text (case-insensitive, word-boundary match) without brackets.
- Collapsed by default. Each entry has a **Link** button that wraps the matched text in `[[...]]` in the source block.

### 9.3 Index requirements

The reference index updates incrementally on every block commit (debounced ~300 ms) and on external file changes. Backlink lookup for a page must be O(incoming refs), not a graph scan — this is the primary job of `cache.db`.

---

## 10. Journal

- One journal page per calendar day, named by ISO date `2026-06-10`, displayed using the user's date format setting (default `Jun 10th, 2026`), stored in `journals/`. New journals are created with ISO filenames.
- **Logseq compatibility:** journal files written by Logseq use the `yyyy_MM_dd` (underscore) filename form. These are recognized as journals and read normally.
- **Date identity is canonical.** Any spelling of a day — `2026-06-10`, `2026_06_10` — resolves to one journal identity (keyed by the ISO date). So an ISO `[[2026-06-10]]` reference links to an imported underscore-named journal file, with working backlinks, and navigation finds the existing file regardless of separator. (*Title-form* references like `[[Jun 10th, 2026]]` are **not** resolved — that would require a configurable date-title parser; see the design note below.)
- **Today's page is the app's home view.** The journal home shows today followed by previous days, infinite-scrolling backwards. Empty past days are skipped; today appears even when empty.
- Today's page (and only today's) is created lazily: the file is written on first content, but the page is always navigable.
- A date-picker (Journal sidebar context menu → "Jump to Day…") jumps to any day, creating a stub for future/past days on demand.
- Journal pages are ordinary pages in every other respect: they can be referenced (`[[2026-06-10]]`), favourited, and they show linked references — this is what makes "what links to this day" work for date references. A date reference renders as the formatted display title ("Jun 10th, 2026") while the file keeps the stable ISO text (§5.1).
- Typing `/today`, `/tomorrow`, `/yesterday` in a block inserts the corresponding `[[date]]` reference. `/date` opens a calendar to insert `[[date]]` for any chosen day (§5.5.4); free-form natural-language date entry ("next friday") is deferred.

**Design note (deliberate):** Everseq references journals by their stable ISO date and renders the pretty title at display time, rather than storing the human title in the file. This keeps references parser-free and format-stable (changing the display format can never orphan references), at the cost of not resolving title-form date references.

---

## 11. Favourites and recent pages

### 11.1 Favourites

- Any page (including journal pages) can be favourited via its page menu or sidebar context menu.
- **Tags can be favourited too** (revises the earlier "tags cannot be favourited" stance): favourite tags are stored separately from page favourites and navigate to the tag view. In the sidebar Favourites section, pages and tags are distinguished by icon (a document for pages, a hash for tags) rather than a star.
- Favourites appear as a reorderable (drag-and-drop) list at the top of the left sidebar (pages and tags reorder within their own groups).
- Persisted in `config.json` and survive cache deletion: page favourites as an ordered list of page names, tag favourites as an ordered list of tag names. A favourite whose page/tag is renamed follows the rename; a favourite whose page is deleted is removed.

### 11.2 Recent pages

- The sidebar's **Recents** section lists the last 20 distinct pages opened (navigations to a page or zoom into its blocks; sidebar previews don't count).
- Most recent first; visiting a listed page moves it to the top; favouriting does not remove it from recents.
- Stored in `cache.db` (acceptable to lose). Cleared via a "Clear recents" menu item.

---

## 12. Navigation and search

- **Left sidebar**: Journal (home), Favourites, Recents, Tags, All Pages. The Favourites, Recents, and Tags sections are collapsible (state persisted) and capped at 15 entries each in v1.
- **Right sidebar**: stack of panes opened via `Cmd+Click` (or `Shift+Click`) on any page/block reference or sidebar entry; each pane closable; resizable divider; used for side-by-side reference work. The open panes and the dragged divider width are persisted per graph in `config.json`, so a graph reopens with its right sidebar as left.
- **Tabs**: native window tabs (`Cmd+T`). Each tab is an independent view of the **same** graph — its own current page, navigation history, and right-sidebar panes — while the graph data, undo stack, and index are shared across tabs. (Tabs hold pages, not graphs.)
- **Open Graph (`Cmd+O`)**: pick or create a graph folder to switch to; the last graph opened is reopened on next launch. Precedence at launch: `EVERSEQ_GRAPH` env var → last opened → `~/Documents/Everseq`.
- **Search (`Cmd+K`)**: single dialog combining fuzzy page-name match (top section) and full-text block search (below), with `Enter` to navigate and `Cmd+Enter` to open in right sidebar. Full-text index lives in `cache.db`. The dialog is a fixed size (it does not resize as results change).
- **Find in page (`Cmd+F`)**: a find bar scoped to the current view's outline(s) — matches the rendered (visible) text, highlights all matches with the current one emphasized, shows "n of m", and steps with `Cmd+G` / `Shift+Cmd+G`. On the journal home it spans all currently-rendered days. (Distinct from `Cmd+K`, which searches the whole graph via the index.)
- **Breadcrumbs** when zoomed into a block: `Page › parent › parent`, each segment clickable.
- Back/forward navigation history (`Cmd+[`, `Cmd+]`), per tab. The window/tab title shows the current page or section name.
- **Layout persistence**: the window's size and position are saved across launches (under a stable key in app preferences — SwiftUI's own window autosave is unreliable for this bare-SPM executable), as is the left sidebar's collapse/expand state; the right-sidebar panes and width persist per graph (above).
- **Content zoom** (`Cmd +` / `Cmd −` / `Cmd 0`): a global font-scale factor applied to the outline content of both the main view and the right pane, persisted per app. v1 scales block text (and everything derived from the base font); SwiftUI chrome titles and outline layout constants don't scale yet.

---

## 13. Editing semantics worth pinning down

- **Undo/redo** is per-session, global, and crosses block boundaries (a page rename or a multi-block paste is one undo step).
- **Copy** of a selected block subtree puts Markdown (with indentation) on the clipboard; **paste** of multi-line Markdown splits into blocks by list structure, or by lines if no list markers present.
- **Delete page** moves its file to the OS trash. Incoming `[[refs]]` now point to a stub; incoming `((refs))` become broken (§7.3) after the confirmation prompt (§7.4) — the prompt aggregates counts for the whole page.
- **Selection**: `Esc` from text editing selects the block (node selection); arrows extend selection across siblings; `Tab`/indent, move, delete then operate on the whole selection.

---

## 14. Performance targets

| Operation | Target |
|---|---|
| Cold start, 10k pages / 1M blocks | < 3 s to interactive (index from cache) |
| Full index rebuild (cache deleted) | < 60 s for the same graph |
| Open page with 200 linked refs | < 200 ms |
| Keystroke-to-render in editor | < 16 ms |
| Search-as-you-type results | < 100 ms |

---

## 15. Technology stack

Native macOS application written in **Swift**.

| Concern | Choice |
|---|---|
| UI chrome (sidebars, search palette, settings, navigation) | SwiftUI |
| Outline view | AppKit `NSTableView` with row reuse (virtualization for §14 targets) |
| Block editor | One shared `NSTextView` (TextKit 2) that moves to the focused block; unfocused blocks render as `NSAttributedString` |
| Editor syntax highlighting | Custom `NSTextStorage` attribute pass over the small inline grammar (Marklight-style); blocks are single paragraphs, so full re-highlight per keystroke is fine |
| Autocomplete (`[[`, `((`, `#`, `/`) | Hand-rolled popover UI |
| Block parser / serializer | Custom (§4.2 byte-stable round-trip requirement rules out off-the-shelf Markdown parsers) |
| Inline Markdown tokenization (rendering) | Custom tokenizer; optionally `swift-markdown` (cmark) for standard inlines |
| Index / cache (`cache.db`) | SQLite via GRDB; FTS5 for full-text search |
| External-edit detection | FSEvents |
| Fenced-code rendering | v1 renders monospace with the language tag shown but **no syntax highlighting** (Highlightr/tree-sitter deferred) |
| Math (`$...$`) | **Slipped from v1**: rendered as styled monospace source, not typeset (SwiftMath deferred) |
| Delete page | `NSWorkspace.recycle` (OS trash) |
| Undo | Custom global undo stack (§13), bridged to `NSUndoManager` |

Rationale for going native over a web-view shell (Tauri/Electron): the spec is macOS-only, the hard runtime problems (virtualized outline, file watching, fast search) are easier with platform APIs, and the polish ceiling is higher. The accepted cost is building the focused-block editor (highlighting + autocomplete) by hand, since no ready-made Swift component implements a per-block editing model.

## 16. Out of scope (explicit)

Whiteboards; HTTP/API server; plugin system; sync/collaboration; mobile; **editable-in-place** embeds (read-only `{{embed …}}` is supported — §7.6); flashcards; PDF annotation; org-mode files; aliases; hierarchical tag semantics; encryption.

Queries are not out of scope — they are deferred; see §17.

## 17. Queries — `{{query …}}`

A `{{query …}}` block renders a **read-only, live result list** of the blocks matching a closed filter expression (no Datalog). Phase 1 is implemented.

### 17.1 Phase 1 (implemented)

- **Syntax — two equivalent surfaces.** Shorthand, with bare filters implicitly AND-ed (`{{query #urgent TODO [[Project X]]}}`); and structured s-expressions for composition (`{{query (and #urgent (not DONE) (or #a #b))}}`).
- **Filters:** `#tag`, `[[Page]]` (links-to), task state (`TODO` / `DONE`, or `(task TODO DONE)`), and properties (`key:: value`, `key::` for exists, or `(property "key" "value")`), combined with `and` / `or` / `not`.
- **Rendering.** Results render **in place inside the host block**, in document order among the page's other blocks — the same generated, read-only, grouped-by-page machinery as embeds (§7.6) and the tag view (§8.2): each result a bulleted, click-to-navigate row. Capped (50) with a "showing N of M" footer; the query never lists its own host block.
- **Editing & round-trip.** The host block stays editable: focused shows the raw `{{query …}}`, unfocused shows results. A malformed query renders literally and round-trips byte-stably (§4.2). Query criteria do **not** count as the host block's own references (no backlink pollution).
- **Evaluation.** Queries are pure functions of the `cache.db` index, compiled to parameterized SQL over its facet tables; re-evaluated when the index changes.

### 17.2 Deferred to later phases

Scope filters (`in-page` / `descendant-of`), journal-date ranges, output controls (`:sort` / `:group` / `:limit`), table rendering, inline TODO toggling from results, and saved/named queries as navigable "query pages".

### Binding commitments (unchanged)

- **Index completeness.** The `cache.db` block index stores, per block, everything a query filters on: page references, block references, tags, block properties (`key:: value`), the `TODO`/`DONE` keyword state, and the containing page's name and journal date.
- **Tag model unaffected.** Tags remain labels (§8). Queries are the mechanism for tag intersections, tag + page-ref combinations, and (later) date-range filters — which is why none of those warrant page-like tag semantics.
