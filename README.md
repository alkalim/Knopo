# Everseq

A native macOS outliner in the Logseq tradition — your notes are blocks, pages are
trees of blocks, and everything lives as plain Markdown files you own. Local-first,
no account, no lock-in: the app is an index and editor over a folder of `.md` files.

## Status

Early. Single-developer project; APIs and on-disk conventions may still change.

## Build / test / run

A Swift Package — builds with the Command Line Tools, no Xcode required.

```sh
swift build                                   # build
./scripts/test.sh                             # run the test suite (Swift Testing)
EVERSEQ_GRAPH=/path/to/graph swift run Everseq # run against a graph folder
```

`EVERSEQ_GRAPH` defaults to `~/Documents/Everseq`; the folder is created and seeded
on first launch. To produce a double-clickable `.app`, see `scripts/build-app.sh`.

## Why it exists

A fast, low-footprint, files-stay-yours outliner: the graph is never held in RAM as
a whole — pages load on demand and a rebuildable SQLite index (`.everseq/cache.db`)
backs search, backlinks, tags, and queries.

## License

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). If you run a modified
version as a network service, you must offer its source to users.

"Everseq" and its logo are trademarks of the project author; the AGPL covers the
code, not the name or branding.
