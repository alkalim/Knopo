# Everseq

A native (AppKit, no Electron) macOS outliner in the Logseq tradition - your notes are blocks, pages are
trees of blocks, and everything lives as plain Markdown files you own. Local-first,
no account, no lock-in: the app is just a fast index and editor over a folder of
`.md` files. Close Everseq and your graph is still a readable, greppable, git-able
directory of Markdown.

![Everseq showing a page with linked references alongside journal and page cards in the right sidebar](docs/screenshot.png)

## Features

- **Outliner editing** - every block is a node: `Enter` splits, `Tab`/`Shift+Tab`
  indent/outdent, `Alt+↑/↓` move, click a bullet to zoom in, click the triangle to
  fold. Markdown renders inline; the focused block shows raw source.
- **Plain Markdown, byte-stable** - each block maps to a line in the file, and an
  untouched block re-serializes exactly as written, so round-tripping never churns
  your files.
- **Page links `[[Page]]`** - with stub pages, link autocomplete, and graph-wide
  rename that rewrites every reference.
- **Block references & embeds** - `((block-id))` to point at a block, `{{embed …}}`
  to transclude a block or page read-only.
- **Tags `#tag`** - labels (not pages), with a generated, click-through tag view.
- **Queries `{{query …}}`** - a live, read-only result list from a small closed
  filter language: tags, page references, task state, and properties combined with
  `and` / `or` / `not`.
- **Journal** - a daily-notes home that scrolls back through previous days.
- **References** - linked and unlinked references surfaced per page.
- **Search & find** - `⌘K` full-text search across the whole graph (SQLite FTS5),
  `⌘F` find within the current view.
- **Right sidebar** - `⌘`/`Shift`-click opens pages and tag views as side-by-side
  cards for reference work.
- **TODO / DONE** blocks and **slash commands** (`/link`, `/date`, `/embed`, …).

Some smaller touches: favourites & recents, content zoom, adjustable line spacing,
and block background colors.

## Why it exists

A fast, low-footprint, files-stay-yours outliner:

- **Your files, forever** - Markdown is the source of truth and the app is
  disposable. The graph stays readable, greppable, git-friendly, and byte-stable,
  so editing never churns your files.
- **Scales without bloating** - the whole graph is never held in RAM; pages load
  on demand, so memory and startup stay flat as the graph grows.
- **Fast everything** - a rebuildable SQLite index (`.everseq/cache.db`) backs
  search, backlinks, tags, and queries, keeping navigation cheap on large graphs.
- **Native, not a browser** - AppKit/SwiftUI, no Electron: small footprint, quick
  launch, and platform-native text editing and scrolling.

## How it compares

|                       | Obsidian | Logseq | Roam Research | Workflowy | Craft | Everseq |
| --------------------- | :------: | :----: | :-----------: | :-------: | :---: | :-----: |
| Open source           | ✗        | ✓      | ✗             | ✗         | ✗     | ✓       |
| Native (no Electron)  | ✗        | ✗      | ✗             | ✗         | ✓     | ✓       |
| Local-first markdown  | ✓        | ✓      | ✗             | ✗         | ✗     | ✓       |
| Outliner (block tree) | ✗        | ✓      | ✓             | ✓         | ✗     | ✓       |
| Block references      | ✓        | ✓      | ✓             | ✓         | ✓     | ✓       |
| Embeds / transclusion | ✓        | ✓      | ✓             | ✓         | ✗     | ✓       |
| Queries               | ✗        | ✓      | ✓             | ✗         | ✗     | ✓       |
| Plugins               | ✓        | ✓      | ✓             | ✗         | ✓     | ✗       |

The closest neighbour is **Logseq** - same outliner model, open source, block
references, embeds, and queries - but Electron. Everseq trades Logseq's
cross-platform reach for a single-platform native app: smaller footprint, faster
launch, and platform-native text editing and scrolling.

## Status

Early but very useable. On-disk conventions may still change.

## Graph layout

A graph is a directory. Everseq lays out and maintains:

```
<graph>/
  pages/         # one Markdown file per page
  journals/      # one file per day
  assets/        # pasted/linked images and files
  .everseq/      # rebuildable cache (SQLite index, config) - safe to delete
```

The Markdown files are the source of truth; `.everseq/` is derived and can be
regenerated at any time.

## Build / test / run

A Swift Package - builds with the Command Line Tools, no Xcode required.

```sh
swift build                                    # build
./scripts/test.sh                              # run the test suite (Swift Testing)
EVERSEQ_GRAPH=/path/to/graph swift run Everseq # run against a graph folder
```

`EVERSEQ_GRAPH` defaults to `~/Documents/Everseq`; the folder is created and seeded
on first launch. To produce a double-clickable `.app`, see `scripts/build-app.sh`.

## Running a downloaded build

This app is not notarized, so macOS Gatekeeper blocks a *downloaded* copy on first
launch. To run it, either:

- strip the quarantine flag - `xattr -dr com.apple.quarantine /path/to/Everseq.app`, or
- open **System Settings → Privacy & Security** and click **Open Anyway**.

On macOS 15 (Sequoia) the old Control-click → Open shortcut no longer bypasses
Gatekeeper for un-notarized apps; use one of the above.

Building from source avoids this entirely - a locally built `.app` isn't
quarantined - but needs the Swift toolchain (the Xcode Command Line Tools).
