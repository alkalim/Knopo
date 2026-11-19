# Knopo

A native macOS outliner inspired by Logseq - your notes are blocks, pages are
trees of blocks, and everything lives as plain Markdown files you own. Local-first,
no account and no lock-in. The app is just a fast index and editor over a folder of
`.md` files.

![Knopo showing a film-noir research page - an outline with a live query and tags - with a journal entry and a film page open as cards in the right sidebar](docs/screenshot.png)

## Features

- **Outliner editing** - every block is a node: `Enter` splits, `Tab`/`Shift+Tab`
  indent/outdent, `Alt+↑/↓` move, click a bullet to zoom in, click the triangle to
  fold. Markdown renders inline; the focused block shows raw source.
- **Plain Markdown** - blocks map directly to Markdown bullets. Unchanged blocks
  stay exactly as written, so round-tripping produces no unnecessary file changes.
- **Page links `[[Page]]`** - with stub pages, link autocomplete, and graph-wide
  rename that rewrites every reference.
- **Block references & embeds** - `((block-id))` to point at a block, `{{embed …}}`
  to transclude a block or page read-only.
- **Tags `#tag`** - labels, with a generated click-through tag view.
- **Queries `{{query …}}`** - a live, read-only result list from a small closed
  filter language: tags, page references, task state, and properties combined with
  `and` / `or` / `not`.
- **Tables** - GitHub-style pipe tables render as a real grid, fitted to the
  window (or to their content, per table), with links and tags live inside cells.
- **Journal** - a daily-notes home that scrolls back through previous days.
- **References** - linked and unlinked references surfaced per page.
- **Search & find** - `⌘K` full-text search across the whole graph (SQLite FTS5),
  `⌘F` find within the current view.
- **Right sidebar** - `⌘`/`Shift`-click opens pages and tag views as side-by-side
  cards.
- **Windows & tabs** - open several graphs at once, each in its own native window
  or tab (`⌘T` for a tab, **Open Graph…** to repoint one). The same graph open in
  two places stays in sync.
- **TODO / DONE** blocks and **slash commands** (`/link`, `/date`, `/embed`, …).

Some smaller things: favourites & recents, content zoom, adjustable text display, block background colors, and more.

See the [user guide](docs/features.md) for full documentation.

## Why it exists

Knopo uses Logseq's block model without copying all of its design choices.
Quality and stability take priority over feature count. Each feature is chosen
and reviewed on its own merits, rather than added just because another app has it.

- **Markdown files** - Markdown is the source of truth and the app is
  disposable. The graph stays readable, greppable, git-friendly, byte-stable.
- **On-demand loading** - the whole graph is never held in memory; pages load
  on demand, so memory and startup stay flat as the graph grows.
- **Indexed navigation** - a rebuildable SQLite index (`.knopo/cache.db`) backs
  search, backlinks, tags and queries, keeping navigation cheap on large graphs.
- **A real text editor** - Knopo uses AppKit and SwiftUI. The block you're editing
  is an actual macOS text view, so typing feels like it does everywhere else on
  the Mac. Web-based editors rebuild native behaviour by hand and rarely nail it.
- **Small and quick** - no bundled browser, so it's a few megabytes, launches
  instantly, stays light on memory and battery for something you keep open all
  day.
- **Fits the system** - real macOS window tabs, dark mode, accent color,
  accessibility settings that follow the moment you change them.

## How it compares

|                       | Obsidian | Logseq | Roam Res. | Workflowy | &nbsp;&nbsp;&nbsp;&nbsp;Craft&nbsp;&nbsp;&nbsp;&nbsp; | &nbsp;&nbsp;&nbsp;&nbsp;Knopo&nbsp;&nbsp;&nbsp;&nbsp; |
| --------------------- | :------: | :----: | :-----------: | :-------: | :---: | :-----: |
| Open source           | ✗        | ✓      | ✗             | ✗         | ✗     | **✓**       |
| Native (no Electron)  | ✗        | ✗      | ✗             | ✗         | ✓     | **✓**       |
| Local-first markdown  | ✓        | ✓      | ✗             | ✗         | ✗     | **✓**       |
| Outliner (block tree) | ✗        | ✓      | ✓             | ✓         | ✗     | **✓**       |
| Block references      | ✓        | ✓      | ✓             | ✓         | ✓     | **✓**       |
| Embeds / transclusion | ✓        | ✓      | ✓             | ✓         | ✗     | **✓**       |
| Queries               | ✗        | ✓      | ✓             | ✗         | ✗     | **✓**       |
| Plugins               | ✓        | ✓      | ✓             | ✗         | ✓     | ✗       |

The closest neighbour is **Logseq** - same outliner model, open source, block
references, embeds, and queries - but Electron. Knopo uses native macOS components
and is macOS-only.

## Status

Early but very useable. On-disk conventions may still change.

## Graph layout

A graph is a directory:

```
<graph>/
  pages/         # one Markdown file per page
  journals/      # one file per day
  assets/        # pasted/linked images and files
  .knopo/        # rebuildable cache (SQLite index, config) - safe to delete
```

The Markdown files are the source of truth; `.knopo/` is derived and can be
regenerated at any time.

## Build / test / run

A Swift Package - builds, runs and tests with the Command Line Tools, no Xcode
required.

```sh
swift build                                    # build
./scripts/test.sh                              # run the test suite (Swift Testing)
KNOPO_GRAPH=/path/to/graph swift run Knopo     # run against a graph folder
```

`KNOPO_GRAPH` defaults to `~/Documents/Knopo`; the folder is created and seeded
on first launch. To produce a double-clickable `.app`, run
`./scripts/build-app.sh release` - that step needs Xcode, for the app icon only.

## Translating

The interface is English and picks up any language you add. To add one, see
[Localization/README.md](Localization/README.md).

## Running a downloaded build

This app is not notarized, so macOS Gatekeeper blocks a *downloaded* copy on first
launch. To run it, either:

- strip the quarantine flag - `sudo xattr -dr com.apple.quarantine /path/to/Knopo.app`, or
- open **System Settings → Privacy & Security** and click **Open Anyway**.

On macOS 15 (Sequoia) the old Control-click → Open shortcut no longer bypasses
Gatekeeper for un-notarized apps; use one of the above.

Building from source avoids this entirely - a locally built `.app` isn't
quarantined - but needs the Swift toolchain (the Xcode Command Line Tools).
