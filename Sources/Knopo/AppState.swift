import SwiftUI
import Combine
import KnopoCore

/// The shared, per-graph model: one open graph, its index, undo, and debounced
/// saves. Navigation (current page, history, panes, search) is *not* here — it
/// lives in `Navigator`, one per window/tab, so tabs are independent views of
/// this one graph.
@MainActor
final class AppState: ObservableObject {
    let store: GraphStore

    /// Bumped whenever index/page data changes so derived views refetch.
    @Published var dataVersion = 0
    /// Incremented when the underlying graph is replaced, so each window's
    /// Navigator can reset its navigation state.
    @Published var graphGeneration = 0

    /// Show faint `[[ ]]` around page references (per-app viewing preference).
    /// Mirrors UserDefaults, which `BlockRenderer` reads.
    @Published var showPageRefBrackets: Bool = UserDefaults.standard.bool(
        forKey: BlockRenderer.pageRefBracketsKey
    ) {
        didSet {
            UserDefaults.standard.set(showPageRefBrackets, forKey: BlockRenderer.pageRefBracketsKey)
            dataVersion += 1
        }
    }

    private var watcher: FileWatcher?
    private var pendingSaves: [String: DispatchWorkItem] = [:]

    // Memoized journal-home day list (see `journalDays()`): rebuilt only when
    // the day *set* changes, not on every content edit.
    private var journalDayCache: [String] = []
    private var journalDaySignature = ""
    private var journalCacheToday = ""

    // Global undo (SPEC §13): snapshots of whole-page states; a multi-page
    // operation (rename) is one entry.
    private struct UndoEntry {
        var label: String
        var before: [PageDocument]
        var after: [PageDocument]
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []

    init(store: GraphStore) {
        self.store = store
        store.onExternalChange = { [weak self] _ in
            self?.dataVersion += 1
        }
        let watcher = FileWatcher(
            paths: [store.pagesDir.path, store.journalsDir.path]
        ) { [weak self] in
            guard let self else { return }
            // No dataVersion bump here: our own debounced saves trigger this
            // watcher too, and a bump re-renders every visible view. Real
            // external changes bump via `onExternalChange` above.
            _ = try? self.store.handleExternalChanges()
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Called before this graph session is replaced (File → Open Graph…):
    /// flush unsaved edits and stop watching the old directory.
    func shutdown() {
        flushPendingSaves()
        watcher?.stop()
        watcher = nil
    }

    /// Resolves a block target (empty page name + zoom id) to its page, via the
    /// index. Used by per-window navigation.
    func resolvePageName(forZoom id: UUID) -> String? {
        store.resolveBlock(id)?.pageName
    }

    func recordVisit(toPageNamed name: String) {
        try? store.cache.recordVisit(pageKey: PageName.key(name))
        dataVersion += 1
    }

    // MARK: - Documents and editing

    func document(for name: String) -> PageDocument {
        store.page(named: name)
    }

    /// Commits an edited document: updates memory, schedules a debounced save
    /// (~300 ms, SPEC §9.3), and records undo state.
    func commit(_ doc: PageDocument, undoLabel: String? = nil) {
        if let undoLabel {
            let before = store.page(named: doc.name)
            pushUndo(UndoEntry(label: undoLabel, before: [before], after: [doc]))
        }
        store.updatePage(doc)
        scheduleSave(doc.name)
    }

    /// Commit with explicit before-state (callers that batch many keystrokes
    /// into one undo step capture `before` when the edit session starts).
    func commit(_ doc: PageDocument, undoLabel: String, before: PageDocument) {
        pushUndo(UndoEntry(label: undoLabel, before: [before], after: [doc]))
        store.updatePage(doc)
        scheduleSave(doc.name)
    }

    /// Toggles a block's TODO/DONE state wherever the block lives — the block
    /// clicked in a query result or embed may belong to another page. Saves
    /// immediately (not on the debounce) so `cache.runQuery` reflects the change
    /// before the caller re-renders. Returns false if the block can't be
    /// resolved or carries no task marker.
    @discardableResult
    func toggleTodo(blockID: UUID) -> Bool {
        // `resolveBlock` relocates volatile query-result ids to the live block,
        // so use *its* id (matches the loaded doc), not the passed-in one.
        guard let resolved = store.resolveBlock(blockID),
              let state = resolved.block.todoState else { return false }
        var doc = document(for: resolved.pageName)
        guard let path = doc.blocks.path(to: resolved.block.id) else { return false }
        let rest = String(resolved.block.content.dropFirst(state.rawValue.count))
        doc.blocks.update(at: path) { $0.content = state.toggled.rawValue + rest }
        commit(doc, undoLabel: state == .todo ? "Mark Done" : "Mark Todo")
        flushPendingSave(forPage: doc.name)
        return true
    }

    private func scheduleSave(_ name: String) {
        let key = PageName.key(name)
        pendingSaves[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSaves[key] = nil
            try? self.store.savePage(named: name)
            self.dataVersion += 1
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Saves one page now and drops its pending debounce — used when a change
    /// must hit the index immediately (a TODO toggle feeding a query re-render).
    private func flushPendingSave(forPage name: String) {
        let key = PageName.key(name)
        pendingSaves[key]?.cancel()
        pendingSaves[key] = nil
        try? store.savePage(named: name)
        dataVersion += 1
    }

    func flushPendingSaves() {
        for (key, work) in pendingSaves {
            work.cancel()
            if let doc = storeLoadedDoc(key) {
                try? store.savePage(named: doc.name)
            }
        }
        if !pendingSaves.isEmpty { dataVersion += 1 }
        pendingSaves = [:]
    }

    private func storeLoadedDoc(_ key: String) -> PageDocument? {
        store.isLoaded(key) ? store.page(named: key) : nil
    }

    // MARK: - Undo / redo

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        for doc in entry.before {
            store.updatePage(doc)
            try? store.savePage(named: doc.name)
        }
        redoStack.append(entry)
        dataVersion += 1
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        for doc in entry.after {
            store.updatePage(doc)
            try? store.savePage(named: doc.name)
        }
        undoStack.append(entry)
        dataVersion += 1
    }

    // MARK: - Page operations

    /// Renames a page across the graph. Returns true so callers (the focused
    /// window) can update their own current target; navigation isn't this
    /// object's concern.
    @discardableResult
    func renamePage(from old: String, to new: String) throws -> Bool {
        // Flush debounced edits first: the rewrite picks its targets from the
        // index (`cache.pagesReferencing`), so an unsaved page that just gained
        // a `[[old]]` reference would otherwise be skipped.
        flushPendingSaves()
        _ = try store.renamePage(from: old, to: new)
        dataVersion += 1
        return true
    }

    /// Renames a tag across the graph. Flushes pending edits first for the same
    /// reason as `renamePage` (the rewrite is index-driven).
    func renameTag(from old: String, to new: String) throws {
        flushPendingSaves()
        _ = try store.renameTag(from: old, to: new)
        dataVersion += 1
    }

    func deletePage(named name: String) throws {
        try store.deletePage(named: name)
        dataVersion += 1
    }

    func toggleFavourite(_ name: String) {
        try? store.updateConfig { $0.toggleFavourite(name) }
        dataVersion += 1
    }

    func toggleFavouriteTag(_ tag: String) {
        try? store.updateConfig { $0.toggleFavouriteTag(tag) }
        dataVersion += 1
    }

    // MARK: - Content zoom (Cmd +/−/0)

    /// Bumping `dataVersion` makes every open outline (main view + panes) notice
    /// the new `BlockRenderer.zoom` and re-render at the new size.
    func adjustZoom(by step: CGFloat) {
        let next = (BlockRenderer.zoom + step)
        BlockRenderer.zoom = min(max(next, BlockRenderer.minZoom), BlockRenderer.maxZoom)
        dataVersion += 1
    }

    func resetZoom() {
        guard BlockRenderer.zoom != 1 else { return }
        BlockRenderer.zoom = 1
        dataVersion += 1
    }

    /// Text density (View ▸ Line Spacing): scales the vertical breathing room
    /// within and between blocks in 10% steps. Like zoom, a `dataVersion` bump
    /// makes every open outline re-render and re-measure at the new spacing.
    func adjustDensity(by step: CGFloat) {
        let next = (BlockRenderer.density + step)
        BlockRenderer.density = min(max(next, BlockRenderer.minDensity), BlockRenderer.maxDensity)
        dataVersion += 1
    }

    func resetDensity() {
        guard BlockRenderer.density != 1 else { return }
        BlockRenderer.density = 1
        dataVersion += 1
    }

    // MARK: - Right-sidebar layout (SPEC §12)

    /// Encoded open panes, persisted per graph. No `dataVersion` bump — this is
    /// pure layout, not graph data, so it shouldn't trigger view rebuilds.
    func persistRightPanes(_ encoded: [String]) {
        try? store.updateConfig { $0.rightPanes = encoded }
    }

    func persistRightPaneFraction(_ fraction: CGFloat?) {
        try? store.updateConfig { $0.rightPaneFraction = fraction.map(Double.init) }
    }

    // MARK: - Derived lists (sidebar)

    var favourites: [String] { store.config.favourites }

    var favouriteTags: [String] { store.config.favouriteTags }

    var recents: [String] {
        let keys = (try? store.cache.recentPageKeys()) ?? []
        return keys.compactMap { key in
            (try? store.cache.page(key: key))?.displayName
                ?? (JournalDate(pageName: key) != nil ? key : nil)
        }
    }

    var allTags: [(tag: String, count: Int)] {
        (try? store.cache.allTags()) ?? []
    }

    /// Journal home days: today first, then existing non-empty days, newest
    /// first (SPEC §10). Memoized — the (relatively expensive) `journalPages()`
    /// scan runs only when the day *set* changes (a day added, deleted, or
    /// crossing empty↔non-empty), detected via a cheap signature, rather than on
    /// every keystroke. Also rebuilds when the calendar day rolls over.
    func journalDays() -> [String] {
        let today = JournalDate.today().pageName
        let signature = (try? store.cache.journalDaySignature()) ?? "?"
        if signature != journalDaySignature || today != journalCacheToday {
            journalDaySignature = signature
            journalCacheToday = today
            var names = [today]
            let existing = (try? store.cache.journalPages()) ?? []
            for page in existing where page.nameKey != today && page.blockCount > 0 {
                names.append(page.nameKey)
            }
            journalDayCache = names
        }
        return journalDayCache
    }

    func allPages() -> [PageListing] {
        var listings = (try? store.cache.allPages()) ?? []
        let stubNames = (try? store.cache.stubPageNames()) ?? []
        listings += stubNames.map {
            PageListing(nameKey: PageName.key($0), displayName: $0, isJournal: false,
                        journalDate: nil, fileExists: false, blockCount: 0)
        }
        return listings.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Fuzzy page-name match for `[[` autocomplete and Cmd+K, ordered by
    /// recency of access (SPEC §6.1).
    func pageNames(matching query: String) -> [String] {
        let pages = allPages().map(\.displayName)
        let recentKeys = (try? store.cache.recentPageKeys()) ?? []
        let recencyRank: [String: Int] = Dictionary(
            uniqueKeysWithValues: recentKeys.enumerated().map { ($1, $0) }
        )
        func recency(_ name: String) -> Int { recencyRank[PageName.key(name)] ?? Int.max }
        if query.isEmpty {
            return pages.sorted { a, b in
                let ra = recency(a), rb = recency(b)
                return ra != rb ? ra < rb : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        // Rank by match closeness first (exact → prefix → substring → loose
        // subsequence), then recency, then alphabetically — so the page you
        // typed doesn't sit below more-distant fuzzy matches.
        return pages.compactMap { name in matchTier(query: query, in: name).map { (name, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let ra = recency(a.0), rb = recency(b.0)
                return ra != rb ? ra < rb : a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
            .map(\.0)
    }
}

/// Match closeness of `query` against `candidate`, case-insensitive; nil if no
/// match. Lower is closer: 0 exact, 1 prefix, 2 substring, 3 loose subsequence.
func matchTier(query: String, in candidate: String) -> Int? {
    let q = query.lowercased(), c = candidate.lowercased()
    if c == q { return 0 }
    if c.hasPrefix(q) { return 1 }
    if c.contains(q) { return 2 }
    return fuzzyMatch(query: q, in: c) ? 3 : nil
}

/// Subsequence fuzzy match, case-insensitive.
func fuzzyMatch(query: String, in candidate: String) -> Bool {
    let q = query.lowercased()
    let c = candidate.lowercased()
    var qi = q.startIndex
    for ch in c {
        guard qi < q.endIndex else { return true }
        if ch == q[qi] { qi = q.index(after: qi) }
    }
    return qi == q.endIndex
}
