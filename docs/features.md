# Knopo user guide

Knopo is a local-first macOS outliner. Notes live in a **graph**: a folder of
plain Markdown files that remains readable and editable without Knopo. The app
adds block editing, links, backlinks, search, tags, embeds, and live queries on
top of those files.

This page introduces Knopo's concepts and everyday features. See also the
[command reference](commands.md) and [query syntax](query-syntax.md).

## Start with a graph

Choose **File > Open Graph…** (`⌘O`) to open an existing folder or create a new
one. A graph contains one knowledge base:

```text
graph/
  pages/       ordinary pages
  journals/    daily journal pages
  assets/      imported images
  .knopo/      settings and a rebuildable search index
```

Knopo opens the last-used graph on the next launch. The journal is the home
view, so a new graph opens on today's notes.

## Blocks and outlines

A **block** is one item in an outline. It may contain text, Markdown, properties,
or multiple lines, and it may have child blocks. The block and all of its
descendants form a subtree.

- Press `Enter` to split a block and create a sibling.
- Press `Tab` and `⇧Tab` to indent and outdent.
- Press `⌥↑` and `⌥↓` to move a block and its subtree.
- Click the disclosure triangle to collapse or expand children.
- Click a bullet to **zoom in**, making that block the temporary root. Use the
  breadcrumb above the outline to move back up.
- Drag a bullet to move a block. Drop between rows to make it a sibling, or onto
  a row to make it that block's first child.

Press `Esc` while editing to select the whole block. From block selection you
can extend the selection with `⇧↑` and `⇧↓`, then indent, move, copy, paste, or
delete all selected blocks together. A selected parent carries its subtree with
it.

Blocks can be empty. An empty leaf hides its bullet when it is not focused, but
remains available for editing — unless it is the page's only block, which keeps its
bullet so an empty page still shows where to write.

**Today's journal opens ready to write.** Whether it is blank or already has
today's notes in it, the caret starts in an empty block at the end, so you can
type straight away — and revisiting the day reuses that block rather than adding
another. Nothing is written by simply opening the journal; the block becomes part
of the file when you type in it. Past days open quietly, for reading.

Other pages open ready to write only when there is nothing to read yet — a new
page, or one you have only linked to. There, the single empty block shows a faint
**Start typing, or / for commands**. That hint is only drawn on screen: it never
becomes part of the note, so it is never saved or found by search, and it stays out
of the way once the page has any content. A page whose file has been emptied, and a block you
zoom into that has no children, are given a block of their own the same way — so
every empty page looks alike.

### Editing and Markdown

The focused block shows its raw Markdown source. Unfocused blocks show rendered
content. Knopo supports:

- `**bold**`, `*italic*`, `~~strikethrough~~`, and `==highlight==`
- inline code with backticks and fenced code blocks
- headings (`#` through `######`), quotes (`> `), and horizontal rules (`---`)
- `[label](https://example.com)` links and bare `http://` or `https://` URLs
- images, including optional display sizes
- `TODO` and `DONE` task markers at the start of a block
- GitHub-style pipe tables (see [Tables](#tables) below)
- inline `$math$`, currently displayed as styled source rather than typeset math

Underscores do not create emphasis, so names such as `file_name.md` remain
literal. Put a backslash before a Markdown trigger to escape it; for example,
`\#not-a-tag` displays as `#not-a-tag` without creating a tag.

Setext headings, footnotes, and HTML rendering are not supported. Their source is
preserved, but unsupported syntax is displayed as plain text. A prefix such as
`1.` is ordinary block text rather than an ordered-list marker. The outline's
bullets and indentation define structure.

Use `⇧Enter` for a newline inside one block. In a fenced code block, plain
`Enter` also inserts a newline while the caret is inside the fence, and `Tab`
indents code instead of the outline.

On a page taller than the window, the view follows the caret: moving between
blocks with the arrow keys, pressing `Enter`, or typing past the bottom of the
window scrolls just enough to keep the caret in sight.

Right-click a bullet and choose **Background Color** to tint that block. The
color applies to the block itself, not its children.

### Tables

A GitHub-style pipe table is one block. Write a header row, a delimiter row, then
the data rows — as continuation lines of the same block, so use `⇧Enter` (or just
`Enter`, which adds a row while the caret is inside a table):

```text
| Fruit | Qty | Notes |
| --- | ---: | :---: |
| Apples | 3 | fresh |
| Pears | 12 | from [[Marina]] |
```

The delimiter row is what makes it a table, and it sets each column's alignment:
`:---` left, `---:` right, `:---:` centred. Without it, lines containing `|` stay
ordinary text, so a pipe in a sentence is safe. Cells take normal Markdown —
page references, tags, emphasis, and inline code all work inside them, and
references in cells appear in backlinks like any others.

Rows are padded or truncated to the header's width, `\|` writes a literal pipe,
and a `|` inside `` `code` `` does not split a cell.

By default a table is as wide as the row allows. Add a `table-width:: min`
property line to the block to keep it only as wide as its content needs
(`table-width:: max` is the default). A table never runs off the edge of the
window: when its columns do not fit, the widest ones are narrowed until they do.
The property is part of the block's source, not its rendered output, so it is
visible while you edit the block and hidden otherwise.

A focused table shows its raw source, with the pipes dimmed — editing happens in
Markdown, so there is no cell-by-cell editing, and `Tab` still indents the block.
`Enter` on the blank row left by a previous `Enter` leaves the table and starts a
new block. Pasting a table keeps it in one block. Cell text does not wrap: an
over-long cell is shortened with an ellipsis. Where there is no room for a grid —
backlink rows, hover previews, embeds, query results — a table shows its raw
Markdown instead.

## Pages

A **page** is a named tree of blocks backed by one Markdown file. Page names are
case-insensitively unique, while the spelling used when the page was created is
kept for display.

Open **All Pages** in the left sidebar to browse, filter, create, favourite, or
delete pages. A name such as `Projects/Knopo` is shown in a namespace group in
All Pages, but it is still one flat page; namespaces do not inherit content or
settings.

A page may exist as a **stub**: a page reference has named it, but no file exists
yet. A stub is navigable and has backlinks. Knopo creates its file when content
is first added.

The page menu (`…`) provides page actions such as favourite, rename, open in the
right sidebar, and delete. Renaming updates page references throughout the
graph. Deleting sends the file to the macOS Trash; incoming page links then lead
to a stub.

## Page references

A **page reference** links a block to a page:

```markdown
Discuss this in [[Project Knopo]].
```

Type `[[` to search for a page or create a reference to a new stub, then press
`Enter` or `Tab` to complete it. A normal click opens the page. `⌘`-click or
`⇧`-click opens it in the right sidebar. Hover over a page reference to preview
the beginning of the page.

Date references use a stable ISO name such as `[[2026-07-21]]`, but render using
the configured friendly date format.

## Block references

A **block reference** points to one specific block by its durable ID:

```markdown
((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))
```

Type `((` and search block content to insert one, or right-click a bullet and
choose **Copy Block Reference**. Knopo stores an `id::` property on the source
block when it first becomes a reference target.

An unfocused reference displays the source block's current content. It does not
include the source block's children. Click it to navigate to the source. Edit the
source rather than the displayed reference.

If the source block is deleted, the reference remains visible as a broken
reference. Knopo asks for confirmation before deleting blocks with incoming
references.

## Embeds

An **embed** displays source content as a read-only outline inside another
block:

```markdown
{{embed [[Project Knopo]]}}
{{embed ((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))}}
```

| Form | What it displays |
|---|---|
| Page embed | All blocks on the referenced page |
| Block embed | The referenced block and its full subtree |
| Plain block reference | Only the referenced block's own content |

Use `/page-embed` or `/block-embed` to insert an embed and choose its target.
Click embedded content to navigate to the source. Embedded content cannot be
edited in place, although a `TODO`/`DONE` checkbox inside it can update its
source block. Nested embeds are shown literally to prevent cycles.

Both references and embeds count as links to their source and therefore appear
in backlinks.

## Linked and unlinked references

Every page has a references area below its outline.

**Linked References** lists blocks elsewhere in the graph that contain a page
reference to this page or a block reference to one of this page's blocks. Results
are grouped by source page and include breadcrumbs for context. Self-references
are omitted. Linked-reference blocks can be edited in place; the change is
written to their source page.

**Unlinked References** finds plain-text mentions of the page name that are not
yet links. Choose **Link** beside a result to wrap that mention in `[[...]]` in
the source block.

## Tags

A **tag** is a case-insensitive label, not a page:

```markdown
#urgent
#[[in progress]]
```

Type `#` to autocomplete existing tags. Click a rendered tag to open its
generated tag view: a read-only list of matching blocks grouped by page. Tags
have no page content, do not appear in page autocomplete, and do not create page
backlinks.

The left sidebar shows frequently used tags with occurrence counts. Tags can be
favourited and renamed; renaming updates their occurrences across the graph.
Use a [query](query-syntax.md) when you need tag intersections or want to combine
a tag with a task, page reference, or property.

## Queries

A **query** is a live filter whose results appear inside its host block:

```markdown
{{query #work TODO}}
{{query (and #urgent (not DONE))}}
```

Queries can filter by tags, page references, `TODO`/`DONE` state, and block or
page properties. Filters can be combined with `and`, `or`, and `not`. Type
`/query` to insert a query skeleton.

Results are read-only and grouped by page. Click a result to navigate to its
source; task checkboxes update the source block. See [Query syntax](query-syntax.md)
for the complete language and current limitations.

## Tasks and properties

Start a block with `TODO ` or `DONE ` to give it a task state. Click its checkbox
or press `⌘Enter` to toggle `TODO` and `DONE`; on a plain block, `⌘Enter` first
adds `TODO`. Tasks are lightweight markers; Knopo does not add scheduling or a
separate task manager.

A property is a `key:: value` line. In a block, put property lines after the
block's content:

```markdown
- Prepare the release
  status:: active
  owner:: Alex
```

Properties are displayed below rendered block content and can be used in
queries. A few properties that only describe how a block looks are treated
differently: `table-width::` is visible while you edit the block but not in its
rendered output, and `background-color::` is set from the bullet menu and never
shown as text at all.

Unbulleted property lines before the page's first block are page-level
properties:

```markdown
type:: project
status:: active
- First project note
```

Page-level properties can make the page itself appear in a property query. The
special first-block property `title::` overrides the page's displayed title; the
page's link identity and filename remain unchanged.

## Journal

Knopo's home view is a journal with one page per calendar day. Today is always
shown, followed by previous non-empty days in reverse chronological order. A
journal is an ordinary page in every other respect: it can contain blocks, be
referenced, be favourited, and show backlinks.

Use `⌘J` to go to today: the journal opens and the caret lands in an empty block
at the end of today, ready to type. Every press does both, from another page or
from another day in the feed, so it doesn't matter where you were — and it never
navigates away from the journal, so repeating it doesn't bounce you between views.
Click a day's heading to open that day on its own page. A block being edited
elsewhere — including one in the right sidebar — hands its editing back and commits
what you had typed there. Right-click **Journal** in the sidebar and
choose **Jump to Day…** to navigate to another date. Slash commands such as
`/today`, `/tomorrow`, `/yesterday`, and `/date` insert date references.

Knopo also recognizes Logseq journal filenames that use underscores, such as
`2026_07_21.md`, as the same calendar identity as `2026-07-21`.

## Search, find, and navigation

- **Search** (`⌘K`) searches page names and all indexed block text. Page matching
  is fuzzy; block full-text search matches token prefixes. For example, `log`
  matches `logging` but not `catalog`.
- **Find in Page** (`⌘F`) finds substrings in the visible outline. On the journal
  home it searches all currently rendered days. Use `⌘G` and `⇧⌘G` to move
  between matches.
- **Back** and **Forward** (`⌘[` and `⌘]`) move through navigation history.
- **Favourites**, **Recents**, **Tags**, and **All Pages** live in the left
  sidebar. Recents can be cleared from the View menu.
- The **right sidebar** holds a stack of page or tag panes for side-by-side
  reference work. Use `⌘`-click or `⇧`-click on internal links and sidebar rows
  to open them there.
- Multiple windows or native tabs can show the same graph or different graphs.
  Views of the same graph share content, index updates, and undo history.

## Images and assets

Drag image files from Finder into an outline, paste copied image files or bitmap
data, or use `/image`. Knopo copies imported files into the graph's `assets/`
folder and inserts portable Markdown.

Hover over a rendered image and drag its right-edge handle to resize it while
preserving its aspect ratio. Resizing changes the Markdown to an Obsidian-style
width form such as:

```markdown
![diagram|640](../assets/diagram.png)
```

Deleting or undoing the block does not delete the imported asset file.

## Your files and external edits

Pages are Markdown bullet lists; two-space indentation stores the outline tree.
Knopo preserves untouched source byte-for-byte, including Markdown it does not
interpret. Content before the first bullet is preserved and displayed read-only
as a page preamble; edit the file directly to change that preamble.

Knopo watches the graph for external file edits and refreshes its index. If an
external edit conflicts with unsaved in-app changes, the last writer wins and
the losing version is saved under `.knopo/conflicts/`.

Your typing is written to disk a couple of seconds after you stop, and at least
every ten seconds while you keep going — plus immediately when you quit Knopo or
switch to another app. So the file on disk trails what is on screen by seconds,
never by more, and edits with no net change do not touch the file at all. That
matters if your graph lives in versioned cloud storage or on a share: Knopo tries
not to produce a new version of a page for every keystroke.

The SQLite index at `.knopo/cache.db` is rebuildable — if you ever delete it,
remove its `cache.db-wal` and `cache.db-shm` companions too, and Knopo rebuilds
the index from your Markdown on the next launch. Page and journal Markdown files
are the source of note content; `.knopo/config.json` stores favourites and
settings and should be backed up with the graph.

A graph kept on a network share (SMB, NFS) works, but the index runs in a slower
single-connection mode there, because those filesystems lack the shared memory
SQLite needs for its faster concurrent mode. Your notes are unaffected either
way; for the best experience keep the graph on a local disk.
