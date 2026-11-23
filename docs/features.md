# Knopo user guide

Knopo is a local-first macOS outliner. A **graph** is a folder of plain
Markdown files. You can read and edit those files in any text editor.

See also the [command reference](commands.md) and [query syntax](query-syntax.md).

## Start with a graph

Choose **File > Open Graph…** (`⌘O`) to open an existing folder or create a new
one.

```text
graph/
  pages/       ordinary pages
  journals/    daily journal pages
  assets/      imported images and PDFs
  .knopo/      settings and a rebuildable search index
```

Knopo opens the last-used graph on the next launch. The journal is the home
view, so a new graph opens on today's notes.

## Settings

In **Knopo > Settings…** (`⌘,`), you can set the theme (System, Light, or Dark),
animations, body font weight, page-link brackets, and journal date format for
all graphs. Animations default to System, which follows macOS Reduce Motion.
The date picker accepts presets and custom Unicode date patterns.
`d{ordinal}` adds the English `st`/`nd`/`rd`/`th` suffix.

Use **File > Graph Settings…** (`⌥⌘,`) to check or rebuild the graph's search index.
Use the View menu or its keyboard shortcuts to adjust zoom and line spacing.

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

Press `Esc` while editing to select the whole block. Extend the selection with
`⇧↑` or `⇧↓`, then indent, move, copy, paste, or delete the selected blocks
together. Selecting a parent includes its subtree.

An empty numbered block keeps its number. An empty, unnumbered block with no
children hides its bullet until you focus it. You can still click it to edit.
The only block on a page keeps its bullet.

Today's journal opens with the caret in an empty block after the day's notes.
Knopo reuses that block when you return and saves it when you type in it.
Past days open for reading.

On a new page or one you've only linked to, the caret starts in an empty block
with the hint **Start typing, or / for commands**. The hint disappears when you
add content and never appears in the file or search results. You get the same
empty block if you clear a page's file or zoom into a block with no children.

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

Knopo preserves Setext headings, footnotes, and HTML as plain text.

Use `⇧Enter` for a newline inside one block. Inside a code fence, `Enter`
inserts a newline and `Tab` indents the code.

Right-click a bullet and choose **Background Color** to tint just that block.

### Numbered lists

Type `1. ` in an empty block, use `/numbered-list`, or right-click its bullet
and choose **Numbered List**. The same menu action toggles numbering on the
top-level blocks in a selection. `Enter` continues a numbered list, and moving
or indenting items updates their numbers automatically.

Each consecutive run starts at 1. An ordinary sibling ends the run. Nested
numbered items use decimal numbers, lowercase letters, then lowercase Roman
numerals. Folding or zooming keeps the original numbers, as do embeds,
Linked References, tag results, and query results.

Press `Backspace` at the start of an item to remove its numbering. On an empty
numbered item with no children, `Enter` outdents the item if its parent is
numbered and the move stays within the current zoom. Otherwise, it removes the
numbering in place.

Pasting a Markdown numbered list creates numbered blocks. Knopo also recognizes
the `logseq.order-list-type:: number` property. It stores new numbering as
`knopo.list-type:: ordered` on ordinary Markdown bullet blocks, with the property
hidden during editing. A `1.` prefix already stored in a block's body remains
literal text.

### Tables

A GitHub-style pipe table is one block. Use `⇧Enter` to put the header,
delimiter, and data rows on separate lines in that block. Once the caret is
inside a table, `Enter` adds a row.

```text
| Fruit | Qty | Notes |
| --- | ---: | :---: |
| Apples | 3 | fresh |
| Pears | 12 | from [[Marina]] |
```

In the delimiter row, use `:---` to align a column left, `---:` to align it
right, or `:---:` to centre it. Without that row, lines containing `|` stay
ordinary text. Cells support page references, tags, emphasis, and inline code.
References in cells appear in backlinks.

Rows are padded or truncated to the header's width, `\|` writes a literal pipe,
and a `|` inside `` `code` `` does not split a cell.

The default, `table-width:: max`, fills the available width. Add a
`table-width:: min` property line to the block to fit the table to its contents.
Knopo narrows the widest columns first so the table never runs off the edge of
the window. The width property is visible only while you edit the block.

Click a table to edit its Markdown. The pipes are dimmed, and `Tab` indents the
whole block. To leave the table, press `Enter` to add a blank row, then press
`Enter` again to start a new block. Pasting a table keeps it in one block.
Each cell displays one line, with an ellipsis if the text is too long. Backlink
rows, hover previews, embeds, and query results show the table's raw Markdown.

## Pages

A **page** is a named tree of blocks backed by one Markdown file. Knopo ignores
case when matching page names and displays each name with its original spelling.

Open **All Pages** in the left sidebar to browse, filter, create, favourite, or
delete pages. A page named `Projects/Knopo` appears under the `Projects`
namespace in the list. Pages in a namespace do not inherit content or settings.

Linking to a page that doesn't exist creates a **stub**. You can open it and
read its backlinks. Knopo creates the file when you first add content.

The page menu (`…`) provides page actions such as favourite, rename, open in the
right sidebar, and delete. Renaming updates page references throughout the
graph. Deleting sends the file to the macOS Trash. Incoming page links then lead
to a stub.

## Page references

A **page reference** links a block to a page:

```markdown
Discuss this in [[Project Knopo]].
```

Type `[[` to search for a page or create a reference to a new stub, then press
`Enter` or `Tab` to complete it. `⌘`-click or
`⇧`-click opens it in the right sidebar. Hover over a page reference to preview
the beginning of the page.

Date references use an ISO date such as `[[2026-07-21]]` in the file. Knopo
displays the date in the format you chose in Settings.

### Page aliases

To give a page another name, add a page property such as
`alias:: AI, Machine Intelligence` above the outline. Knopo also reads aliases
from the first block's properties. Separate names with commas and use double
brackets for a name that contains a comma, such as `[[Doe, Jane]]`.

Type an alias in `[[` autocomplete or in Search (`⌘K`) to find the page. A link
written as `[[AI]]` keeps that label and opens the same page. Linked References
and page-reference queries include links written with either name. Unlinked
References looks for the page's actual name. An existing page name takes
precedence over an alias. If two pages share an alias, links using it stay
unresolved until you change or remove one of the aliases.

## Block references

A **block reference** points to one specific block by its durable ID:

```markdown
((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))
```

Type `((` and search block content to insert one, or right-click a bullet and
choose **Copy Block Reference**. Knopo stores an `id::` property on the source
block the first time you reference it.

An unfocused reference shows the source block's first line, with inline
formatting. Click the text to open the source block for editing. If the source
is a `TODO` or `DONE` task, click its checkbox in the reference to toggle the
source task and stay where you are. You can undo the toggle in one step.

Knopo asks for confirmation before deleting blocks with incoming references.
If you delete the source block, its references stay visible and appear broken.

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
| Plain block reference | The first line of the referenced block |

Use `/page-embed` or `/block-embed` to insert an embed and choose its target.
Click the embedded text to open the source for editing. You can toggle a
`TODO`/`DONE` checkbox directly in the embed. Nested embeds are shown literally
to prevent cycles.

References and embeds both appear in the source's backlinks.

## Linked and unlinked references

Below the outline, **Linked References** lists blocks on other pages that link
to this page or one of its blocks. Results are grouped by source page, with
breadcrumbs showing where each block sits in its outline. Edit a block here
to update its source page.

**Unlinked References** finds plain-text mentions of the page name that are not
yet links. Choose **Link** beside a result to wrap that mention in `[[...]]` in
the source block.

## Tags

A **tag** is a case-insensitive label, not a page:

```markdown
#urgent
#[[in progress]]
```

Type `#` to autocomplete existing tags. To tag a whole page, add a property
such as `tags:: work, [[in progress]]` above its outline. Click a tag to open
its read-only view of matching pages and blocks, grouped by page. A page tag
lists the page once. Its blocks keep their own tags. Tags have no page content,
do not appear in page autocomplete, and do not create page backlinks.

The left sidebar shows frequently used tags with occurrence counts. Tags can be
favourited and renamed; renaming updates their occurrences across the graph.
To find blocks with several tags, or combine a tag with a task state, page
reference, or property, use a [query](query-syntax.md).

## Queries

A **query** is a live filter whose results appear inside its host block:

```markdown
{{query #work TODO}}
{{query (and #urgent (not DONE))}}
```

Queries can filter by tags, page references, `TODO`/`DONE` state, and block or
page properties. Combine filters with `and`, `or`, and `not`. Type `/query`
to insert a query.

Results are read-only and grouped by page. Click a result to navigate to its
source. Task checkboxes update the source block. See [Query syntax](query-syntax.md).

## Tasks and properties

Start a block with `TODO ` or `DONE ` to give it a task state. Click its checkbox
or press `⌘Enter` to switch between `TODO` and `DONE`. On a plain block,
`⌘Enter` first adds `TODO`.

A property is a `key:: value` line. In a block, put property lines after the
block's content:

```markdown
- Prepare the release
  status:: active
  owner:: Alex
```

Properties appear below the rendered block and can be used in queries.
`table-width::` appears only while you edit. Set `background-color::` from
the bullet menu. Knopo never shows it as text.

Unbulleted property lines before the page's first block are page-level
properties:

```markdown
type:: project
status:: active
- First project note
```

Page-level properties can make the page itself appear in a property query.

The optional `title::` property gives an opened page a custom heading, page
breadcrumb, and window/tab title while keeping its existing filename and links.
For example, a journal page can have the heading "Conference notes" and still
appear under its date in the journal feed. Knopo uses the first block's
`title::` if the page-level title is blank or missing.

Links and autocomplete use page names and aliases. Navigation lists keep their
name/date labels.

## Journal

Knopo's home view is a journal with one page per calendar day. It opens at today,
with non-empty future days above and previous days below in reverse chronological
order. Today is always shown, even when empty. You can link to a journal day
or add it to Favourites.

Press `⌘J` from any page or journal day to put the caret in the empty block at
the end of today's notes.
Click a day's heading to open that day on its own page. If you were editing another
block, including one in the right sidebar, Knopo ends that editing session and
commits your changes. Right-click **Journal** in the sidebar and
choose **Jump to Day…** to navigate to another date. Slash commands such as
`/today`, `/tomorrow`, `/yesterday`, and `/date` insert date references.

Knopo treats the journal file `2026_07_21.md` as the page for `2026-07-21`.

## Search, find, and navigation

- **Search** (`⌘K`) searches page names, aliases, and all indexed block text.
  Page matching is fuzzy. Block search matches token prefixes. For example, `log`
  matches `logging` but not `catalog`.
- **Find in Page** (`⌘F`) finds substrings in the visible outline. On the journal
  home it searches all currently rendered days. Use `⌘G` and `⇧⌘G` to move
  between matches.
- **Back** and **Forward** (`⌘[` and `⌘]`) move through navigation history.
  When you return to a page in the main view, Knopo restores the outline block
  that was at the top when you left it in that tab.
- **Favourites** in the left sidebar lists pages and tags together. Drag any
  favourite above or below another to set their order for this graph. When a
  page appears in both Favourites and Recents, only the row you select is
  highlighted. You can clear Recents from the View menu.
- The **right sidebar** holds a stack of page or tag panes for side-by-side
  reference work. Use `⌘`-click or `⇧`-click on internal links and sidebar rows
  to open them there.
- Multiple windows or native tabs can show the same graph or different graphs.
  Views of the same graph share content, index updates, and undo history.
- Choose **Open in New Window** from a page’s ⋯ menu, including on a right-sidebar
  card, or right-click an entry in Recents, Tags, or Favourites. The new window
  starts with both sidebars hidden and keeps any block zoom. Knopo remembers
  the last size and position you used for these windows. Use the toolbar or
  `⌃⌘S` to show the left sidebar.

## Images and PDFs

Drag images or PDFs from Finder into the outline, or copy the files in Finder
and paste them into a block. For images, you can also paste bitmap data or
choose files with `/image`. Knopo stores the files in `assets/` and inserts a
relative Markdown link for each one.

A PDF shows its first page in the outline. Right-click the preview and choose
**Quick Look** to read the whole document.

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
interpret. Headings without a leading dash (`-`) are editable outline blocks.
They keep their original source until edited, then save as `- # Heading`.

Click a property above the outline to edit it. An empty editor shows the
hint `property:: value`. For a `tags::` property, click a tag chip to open its
tag view, or click the label and start typing a tag name to see suggestions.

To add a page property, choose **Add Page Property** from the page menu, or type
`tags:: project` or another `name:: value` line in an empty first block and press
Enter. While editing a property, press Enter to add a line below it. Press Enter
on a blank line to move into the outline. To remove a property, use its
right-click menu.
Other text above the outline remains read-only.

Knopo watches the graph for external file edits and refreshes its index. If an
external edit conflicts with unsaved in-app changes, the last writer wins and
the losing version is saved under `.knopo/conflicts/`.

Knopo saves a couple of seconds after you stop typing and at least every ten
seconds while you type. It saves immediately when you quit or switch apps.
If your edits leave the page as it was at the last save, Knopo skips the write.

The SQLite index at `.knopo/cache.db` is rebuildable from **Graph Settings**. If
you delete it manually, remove its `cache.db-wal` and `cache.db-shm` companions
too, and Knopo rebuilds the index from your Markdown on the next launch.
Back up `.knopo/config.json` with the graph to keep its favourites and settings.

You can keep a graph on an SMB or NFS share but the index runs faster on a local disk.
