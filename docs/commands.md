# Knopo commands

This page lists slash commands, autocomplete controls, keyboard shortcuts, and
the main pointer actions. See the [user guide](features.md) for the concepts and
[Query syntax](query-syntax.md) for query expressions.

Shortcut symbols follow macOS conventions: `⌘` Command, `⌥` Option, `⇧` Shift,
and `⌃` Control.

## Slash commands

Type `/` at the beginning of a block or after whitespace. Continue typing to
filter the menu, then use `↑`/`↓` and `Enter` or `Tab` to choose a command. The
typed `/` and filter text are replaced by the command's result. Press `Esc` to
close the menu without running a command.

| Command | Result |
|---|---|
| `/today` | Inserts a page reference to today's journal. |
| `/tomorrow` | Inserts a page reference to tomorrow's journal. |
| `/yesterday` | Inserts a page reference to yesterday's journal. |
| `/date` | Opens a calendar and inserts a reference to the chosen day. |
| `/quote` | Adds `> ` to the start of the block. It does nothing if the prefix is already present. |
| `/code-block` | Inserts a fenced code block and places the caret after the opening backticks, ready for an optional language name. |
| `/link` | Opens a label-and-URL panel and inserts `[label](url)`. A URL on the clipboard is prefilled when possible. |
| `/image` | Opens an image picker, copies the selected images into `assets/`, and inserts image Markdown. Multiple selection is allowed. |
| `/page-embed` | Inserts a page-embed skeleton and immediately opens page autocomplete. |
| `/block-embed` | Inserts a block-embed skeleton and immediately opens block search. |
| `/query` | Inserts `{{query }}` with the caret ready for a filter. |

Typing `/embed` shows both embed commands.

For `/link`, `/date`, and `/image`, cancelling the panel or picker inserts
nothing; the slash trigger has already been consumed.

## Autocomplete and popovers

| Trigger | Purpose |
|---|---|
| `[[` | Find a page or create a reference to a new stub page. |
| `((` | Search block content and insert a block reference. Type search text after the trigger before choosing. |
| `#` | Complete an existing tag. Use `#[[` for a multi-word tag. |
| `/` | Find a slash command. |

While an autocomplete menu is open:

| Key | Action |
|---|---|
| `↑` / `↓` | Move through results. |
| `Enter` or `Tab` | Choose the highlighted result. |
| `Esc` | Close the menu. |

Backslash-escaped triggers such as `\[[`, `\((`, `\#`, and `\/` do not open
autocomplete.

The link panel uses `Tab` to move between Label and URL, `Enter` to insert, and
`Esc` to cancel. The date picker uses `Enter` to insert the selected day,
double-click to insert a day immediately, and `Esc` to cancel.

## Editing a block

These commands apply while the text caret is inside a block.

| Shortcut | Action |
|---|---|
| `Enter` | Split at the caret and create a sibling block below. Inside a fenced code block or a table, insert a newline instead — in a table that adds a row, and a second `Enter` on the resulting blank row leaves the table. |
| `⇧Enter` | Insert a newline inside the current block. |
| `Tab` | Indent the block under the sibling above. Inside a fenced code block, insert a tab. |
| `⇧Tab` | Outdent the block. Inside a fenced code block, remove one leading tab or up to two spaces from the line. |
| `⌥↑` / `⌥↓` | Move the block and its subtree among its siblings. |
| `⌘Enter` | Add `TODO` to a plain block, or toggle an existing `TODO`/`DONE` state. |
| `⌘B` | Wrap the selection in `**` for bold, or insert an empty bold pair. |
| `⌘I` | Wrap the selection in `*` for italics, or insert an empty italic pair. |
| `Esc` | Leave text editing and select the block. |
| `Backspace` at the start | Merge into the previous block. If the block is empty, delete it and focus the previous block. |
| `Delete` at the end | Pull the next leaf block's content into this block when it can be merged safely. |
| `↑` on the first visual line | Focus the previous visible block. |
| `↓` on the last visual line | Focus the next visible block. |
| `⌘C` with no text selected | Copy the current block and its subtree as indented Markdown. |

Standard macOS text commands such as `⌘X`, `⌘C`, `⌘V`, and `⌘A` work on a text
selection. Pasting Markdown list structure creates a corresponding block tree;
plain multiline text creates one block per line. Multiline paste stays inside a
quote, fenced-code, or table block, and pasting table-shaped text keeps it in
one block.

Typing any of these opening markers over selected text wraps it and keeps the
inner text selected: `[`, backtick, `*`, `~`, `=`, or `$`. Press the marker a
second time to double it. For example, `*` twice produces bold markers.

## Selecting whole blocks

Press `Esc` from the editor, or `⇧`-click/`⌘`-click block content, to work with
whole blocks rather than text.

| Shortcut | Action |
|---|---|
| `↑` / `↓` | Move the single-block selection to the previous or next visible block. |
| `⇧↑` / `⇧↓` | Extend or shrink a contiguous selection. |
| `⌥↑` / `⌥↓` | Move the selected blocks as one unit. |
| `Enter` | Edit the selected block. |
| `Tab` / `⇧Tab` | Indent or outdent the selected blocks. |
| `Delete` | Delete the selection and its selected subtrees. |
| `⌘C` | Copy selected blocks as Markdown. |
| `⌘V` | Paste blocks after the selection. |
| `⌘A` | Select all visible blocks in the outline. |
| `Esc` | Clear block selection. |

A multi-block indent or move requires the top-level selected blocks to be
contiguous siblings. If a parent and one of its descendants are selected, the
parent is the moving unit and carries its subtree.

## Navigation and windows

| Shortcut | Action |
|---|---|
| `⌘K` | Search pages and blocks across the graph. |
| `⌘F` | Find text in the current page or visible journal days. Repeating it focuses and selects the find text. |
| `⌘G` | Go to the next find match. |
| `⇧⌘G` | Go to the previous find match. |
| `⌘J` | Go to today: opens the journal home and puts the caret in today's last block, ready to type — from another page, or from another day in the feed. It never navigates away from the journal, so repeat presses don't bounce between views. Click a day's heading to open that day's own page. |
| `⌘[` / `⌘]` | Go back or forward in navigation history. |
| `⌘O` | Choose or create a graph folder for the focused window. |
| `⌘T` | Open a new native tab using the last-used graph. |
| `⌘N` | Open a new window using the last-used graph. |
| `⌘Enter` in Search | Open the highlighted search result in the right sidebar. |
| `⌘`-click or `⇧`-click an internal link or sidebar row | Open it in the right sidebar. |

The **View > Close All Right Panes** menu command closes the entire right-sidebar
stack. Each pane also has actions to close the other panes or open its content
in the main view.

## Undo, display, and spacing

| Shortcut | Action |
|---|---|
| `⌘Z` | Undo. |
| `⇧⌘Z` | Redo. |
| `⌘+` | Increase outline content size. |
| `⌘-` | Decrease outline content size. |
| `⌘0` | Reset outline content size. |
| `⌃⌘=` | Increase line spacing. |
| `⌃⌘-` | Decrease line spacing. |
| `⌃⌘0` | Reset line spacing. |

The View menu also controls page-link brackets, content font weight, and clearing
recent pages.

## Pointer and context-menu actions

| Action | Result |
|---|---|
| Click a bullet | Zoom into that block. |
| Click a disclosure triangle | Collapse or expand the block's children. |
| Drag a bullet between rows | Move the block or current block selection before the row below the gap. |
| Drag a bullet onto a row | Make the dragged block or selection that row's first child. |
| Right-click a bullet | Copy a block reference, copy subtree Markdown, choose a background color, or delete. |
| Click a page reference, block reference, embed row, query result, or tag result | Navigate to its source. |
| Double-click a linked-reference block | Edit that backlink in place. Use its arrow button to navigate to the source block. |
| `⌘`-click or `⇧`-click navigable content | Open it in the right sidebar. |
| Drag image files from Finder | Import the images and insert blocks at the drop location. |
| Drag a rendered image's right-edge handle | Resize it while preserving its aspect ratio. |

Dropping onto a collapsed block expands it. Hovering a drag over a collapsed
block briefly also opens it so you can target descendants.
