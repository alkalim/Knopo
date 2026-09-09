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
    let preferences: Preferences

    /// Bumped whenever index/page data changes so derived views refetch.
    @Published var dataVersion = 0
    /// Incremented when the underlying graph is replaced, so each window's
    /// Navigator can reset its navigation state.
    @Published var graphGeneration = 0
    /// Shared by every All Pages view for this graph and persisted in config.
    @Published private(set) var allPagesCollapsedSections: Set<String> = []

    private var preferenceObservers: Set<AnyCancellable> = []

    private var watcher: FileWatcher?
    private let pageSaveQueue = DispatchQueue(
        label: "io.knopo.page-save", qos: .utility)
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private var pendingCeilings: [String: DispatchWorkItem] = [:]
    let saveDebounce: TimeInterval
    let saveCeiling: TimeInterval
    private var dirtySaveNames: [String: String] = [:]
    private var saveGenerations: [String: UInt64] = [:]
    private var internallySavedStamps: [String: CacheDB.FileStamp] = [:]

    // Memoized journal-home day list (see `journalDays()`): rebuilt only when
    // the day *set* changes, not on every content edit.
    private var journalDayCache: [String] = []
    private var journalDaySignature = ""
    private var journalCacheToday = ""

    // The calendar day the UI is treating as today (see `checkDayRollover`).
    private var currentDay = JournalDate.today().pageName
    private var dayRollover: DispatchWorkItem?
    private var dayObservers: [NSObjectProtocol] = []

    // Global undo (SPEC §13): snapshots of whole-page states; a multi-page
    // operation (rename) is one entry.
    private struct UndoEntry {
        var label: String
        var before: [PageDocument]
        var after: [PageDocument]
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []

    /// Closes the focused block's in-progress typing into an undo entry.
    /// Keystrokes coalesce into one entry per edit session (SPEC §13) and that
    /// entry doesn't exist until the session closes — which normally happens when
    /// focus leaves the block. Undo has to close it first, or it steps past the
    /// edit you just made (and does nothing at all when it's the first edit).
    /// Registered by whichever outline holds focus; a stale registration is
    /// harmless, since closing a session with no open session does nothing.
    var closePendingEdit: (() -> Void)?

    /// Quiet period after the last keystroke before a page is written, and the
    /// longest a page may stay unwritten while editing continues (SPEC §9.3).
    /// The debounce alone has no ceiling — each keystroke pushes it back — so
    /// steady typing could defer a save indefinitely; and typing just slower than
    /// the debounce used to write and reindex the page on *every* character.
    /// Overridable so tests don't have to sleep for seconds.
    convenience init(
        store: GraphStore,
        saveDebounce: TimeInterval = 2,
        saveCeiling: TimeInterval = 10
    ) {
        self.init(
            store: store, preferences: .standard,
            saveDebounce: saveDebounce, saveCeiling: saveCeiling)
    }

    init(
        store: GraphStore,
        preferences: Preferences,
        saveDebounce: TimeInterval = 2,
        saveCeiling: TimeInterval = 10
    ) {
        self.store = store
        self.preferences = preferences
        self.saveDebounce = saveDebounce
        self.saveCeiling = saveCeiling
        allPagesCollapsedSections = Set(store.config.allPagesCollapsedSections)
        preferences.$renderRevision
            .dropFirst()
            .sink { [weak self] _ in self?.dataVersion += 1 }
            .store(in: &preferenceObservers)
        store.onExternalChange = { [weak self] _ in
            self?.dataVersion += 1
        }
        let watcher = FileWatcher(
            paths: [store.pagesDir.path, store.journalsDir.path]
        ) { [weak self] changedPaths in
            guard let self else { return }
            guard self.containsExternalFileChange(changedPaths) else { return }
            // No dataVersion bump here: our own debounced saves trigger this
            // watcher too, and a bump re-renders every visible view. Real
            // external changes bump via `onExternalChange` above.
            _ = try? self.store.handleExternalChanges()
        }
        watcher.start()
        self.watcher = watcher
        startDayRolloverWatch()
    }

    /// Called before this graph session is replaced (File → Open Graph…):
    /// flush unsaved edits and stop watching the old directory.
    func shutdown() {
        flushPendingSaves()
        watcher?.stop()
        watcher = nil
        dayRollover?.cancel()
        dayRollover = nil
        dayObservers.forEach(NotificationCenter.default.removeObserver)
        dayObservers = []
    }

    // MARK: - Day rollover

    /// Keeps journal home on the real calendar day while the app stays open: at
    /// midnight the feed must gain a fresh day for the new today and push the
    /// finished one down (SPEC §10). Nothing else notices — no file changes at
    /// the rollover — so the day boundary is watched explicitly.
    private func startDayRolloverWatch() {
        scheduleDayRollover()
        // Backstops for the scheduled check: a clock or time-zone change (which
        // moves midnight), and returning to the app — e.g. after the Mac slept
        // through the boundary.
        for name in [Notification.Name.NSCalendarDayChanged,
                     NSApplication.didBecomeActiveNotification] {
            dayObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDayRollover() }
            })
        }
    }

    /// Arms a check just after the next local midnight, then re-arms from there.
    private func scheduleDayRollover() {
        dayRollover?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.checkDayRollover()
                self?.scheduleDayRollover()
            }
        }
        dayRollover = work
        // A wall-clock deadline (not `.now() + interval`, which stalls while the
        // machine sleeps), one second past midnight so the day has really turned.
        DispatchQueue.main.asyncAfter(
            wallDeadline: .now() + Self.secondsUntilNextDay() + 1, execute: work
        )
    }

    /// Re-renders journal home when the calendar day has turned. Pending edits
    /// are flushed first: the day just ended stays in the feed only while the
    /// index knows it has blocks, and a debounced save may still be in flight.
    /// `journalDays()` rebuilds itself on a new today; it just needs re-asking.
    func checkDayRollover(now: Date = Date()) {
        let today = JournalDate(date: now).pageName
        guard today != currentDay else { return }
        currentDay = today
        flushPendingSaves()
        dataVersion += 1
    }

    /// Seconds from `now` to the next local midnight. Uses calendar arithmetic,
    /// so DST shifts (including regions where midnight itself is skipped) give a
    /// real boundary rather than a fixed 24 h step.
    static func secondsUntilNextDay(from now: Date = Date()) -> TimeInterval {
        let midnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
        // No match should be impossible; fall back to an hourly re-check.
        guard let midnight else { return 3600 }
        return max(1, midnight.timeIntervalSince(now))
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

    /// Commits an edited document: updates memory, schedules the save
    /// (`saveDebounce`, bounded by `saveCeiling` — SPEC §9.3), and records undo
    /// state.
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

    /// Serializes this synchronous cross-page write behind any debounced edits.
    /// Otherwise an older queued snapshot of the same page could land after the
    /// newly persisted `id::` property and remove it again.
    func persistBlockID(_ id: UUID, inPageNamed name: String) throws {
        flushPendingSaves()
        try store.persistBlockID(id, inPageNamed: name)
        let document = store.page(named: name)
        recordInternalSave(
            of: document, stamp: GraphStore.stamp(of: store.fileURL(forPageNamed: name)))
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
        saveGenerations[key] = saveGenerations[key, default: 0] &+ 1
        dirtySaveNames[key] = name
        pendingSaves[key]?.cancel()
        let debounced = DispatchWorkItem { [weak self] in
            self?.performScheduledSave(key: key)
        }
        pendingSaves[key] = debounced
        DispatchQueue.main.asyncAfter(
            deadline: .now() + saveDebounce, execute: debounced)
        // Scheduled once per dirty run and never pushed back, so the wait is
        // bounded no matter how long typing continues.
        guard pendingCeilings[key] == nil else { return }
        let ceiling = DispatchWorkItem { [weak self] in
            self?.performScheduledSave(key: key)
        }
        pendingCeilings[key] = ceiling
        DispatchQueue.main.asyncAfter(
            deadline: .now() + saveCeiling, execute: ceiling)
    }

    /// Whichever of the two timers fires first saves the page's current state and
    /// stands the other down.
    private func performScheduledSave(key: String) {
        pendingSaves[key]?.cancel()
        pendingSaves[key] = nil
        pendingCeilings[key]?.cancel()
        pendingCeilings[key] = nil
        guard let name = dirtySaveNames[key] else { return }
        enqueuePageSave(
            named: name, key: key, generation: saveGenerations[key, default: 0])
    }

    private func enqueuePageSave(named name: String, key: String, generation: UInt64) {
        guard let snapshot = store.pageSaveSnapshot(named: name) else {
            // A file-less empty stub has nothing to persist.
            dirtySaveNames[key] = nil
            return
        }
        let persistence = store.pagePersistence
        pageSaveQueue.async { [weak self] in
            let result = Result { try persistence.persist(snapshot) }
            DispatchQueue.main.async {
                self?.completePageSave(
                    snapshot, key: key, generation: generation, result: result)
            }
        }
    }

    private func completePageSave(
        _ snapshot: GraphStore.PageSaveSnapshot,
        key: String,
        generation: UInt64,
        result: Result<CacheDB.FileStamp?, Error>
    ) {
        guard case .success(let stamp) = result else { return }
        // Record the stamp even when a newer edit superseded this snapshot: the
        // write still happened, and its FSEvent is still ours. Skipping it here
        // made every superseded save — common while typing — look external and
        // pay for a whole-graph scan that finds nothing.
        recordInternalSave(of: snapshot.document, stamp: stamp)
        let isCurrent = store.finishPageSave(snapshot)
        guard dirtySaveNames[key] != nil,
              saveGenerations[key] == generation,
              isCurrent else { return }
        dirtySaveNames[key] = nil
        dataVersion += 1
    }

    /// Saves one page now and drops its pending debounce — used when a change
    /// must hit the index immediately (a TODO toggle feeding a query re-render).
    private func flushPendingSave(forPage name: String) {
        let key = PageName.key(name)
        flushSaveKeys([key])
    }

    func flushPendingSaves() {
        flushSaveKeys(Set(dirtySaveNames.keys))
    }

    private func flushSaveKeys(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys {
            pendingSaves[key]?.cancel()
            pendingSaves[key] = nil
            pendingCeilings[key]?.cancel()
            pendingCeilings[key] = nil
        }
        let jobs = keys.compactMap { key -> (
            key: String, generation: UInt64, snapshot: GraphStore.PageSaveSnapshot
        )? in
            guard let name = dirtySaveNames[key],
                  let snapshot = store.pageSaveSnapshot(named: name) else {
                dirtySaveNames[key] = nil
                return nil
            }
            return (key, saveGenerations[key, default: 0], snapshot)
        }
        let persistence = store.pagePersistence
        let results = pageSaveQueue.sync {
            jobs.map { job in
                (job, Result { try persistence.persist(job.snapshot) })
            }
        }
        var changed = false
        for (job, result) in results {
            guard case .success(let stamp) = result else { continue }
            recordInternalSave(of: job.snapshot.document, stamp: stamp)
            let isCurrent = store.finishPageSave(job.snapshot)
            guard dirtySaveNames[job.key] != nil,
                  saveGenerations[job.key] == job.generation,
                  isCurrent else { continue }
            dirtySaveNames[job.key] = nil
            changed = true
        }
        if changed { dataVersion += 1 }
    }

    private func recordInternalSave(
        of document: PageDocument, stamp: CacheDB.FileStamp?
    ) {
        guard let stamp else { return }
        internallySavedStamps[canonicalPath(store.fileURL(forPageNamed: document.name))] = stamp
    }

    /// File writes generate FSEvents too. If every changed Markdown path still
    /// has the exact stamp produced by our writer, a graph scan can only confirm
    /// work that just completed. A differing/missing stamp is an external edit.
    private func containsExternalFileChange(_ paths: Set<String>?) -> Bool {
        guard let paths else { return true }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "md" else { continue }
            let canonical = canonicalPath(url)
            guard let expected = internallySavedStamps[canonical],
                  GraphStore.stamp(of: url) == expected else {
                internallySavedStamps[canonical] = nil
                return true
            }
        }
        return false
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Undo / redo

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        closePendingEdit?()
        guard let entry = undoStack.popLast() else { return }
        for doc in entry.before {
            store.updatePage(doc)
            scheduleSave(doc.name)
        }
        flushPendingSaves()
        redoStack.append(entry)
        dataVersion += 1
    }

    func redo() {
        closePendingEdit?()
        guard let entry = redoStack.popLast() else { return }
        for doc in entry.after {
            store.updatePage(doc)
            scheduleSave(doc.name)
        }
        flushPendingSaves()
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

    // MARK: - Graph display settings

    var journalDateFormat: JournalDateFormat { preferences.defaultDateFormat }

    func displayTitle(for pageName: String) -> String {
        JournalDate(pageName: pageName)?.displayName(using: journalDateFormat) ?? pageName
    }

    func displayTitle(for document: PageDocument) -> String {
        document.displayTitle(using: journalDateFormat)
    }

    func rebuildIndex() async throws {
        closePendingEdit?()
        flushPendingSaves()
        let maintenance = store.indexMaintenance
        let onDisk = try await withCheckedThrowingContinuation { continuation in
            pageSaveQueue.async {
                continuation.resume(with: Result { try maintenance.rebuild() })
            }
        }
        store.pruneStaleFavourites(onDisk: onDisk)
        dataVersion += 1
    }

    // MARK: - Content zoom (Cmd +/−/0)

    /// Bumping `dataVersion` makes every open outline (main view + panes) notice
    /// the new `BlockRenderer.zoom` and re-render at the new size.
    func adjustZoom(by step: CGFloat) {
        preferences.zoom += step
    }

    func resetZoom() {
        preferences.zoom = 1
    }

    /// Text density (View ▸ Line Spacing): scales the vertical breathing room
    /// within and between blocks in 10% steps. Like zoom, a `dataVersion` bump
    /// makes every open outline re-render and re-measure at the new spacing.
    func adjustDensity(by step: CGFloat) {
        preferences.density += step
    }

    func resetDensity() {
        preferences.density = 1
    }

    // MARK: - Persisted view layout (SPEC §12)

    func toggleAllPagesSection(_ encoded: String) {
        var collapsed = allPagesCollapsedSections
        if collapsed.contains(encoded) {
            collapsed.remove(encoded)
        } else {
            collapsed.insert(encoded)
        }
        allPagesCollapsedSections = collapsed
        try? store.updateConfig {
            $0.allPagesCollapsedSections = collapsed.sorted()
        }
    }

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
    func journalDays(today: String = JournalDate.today().pageName) -> [String] {
        let signature = (try? store.cache.journalDaySignature()) ?? "?"
        if signature != journalDaySignature || today != journalCacheToday {
            journalDaySignature = signature
            journalCacheToday = today
            var names = [today]
            let existing = (try? store.cache.journalDaysWithContent()) ?? []
            for key in existing where key != today {
                names.append(key)
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
        // A canonical date key is the source of truth for journal identity.
        // Normalize every listing, including cached file-less rows left from
        // earlier in the session, rather than trusting its origin's metadata.
        for index in listings.indices {
            guard let journalDate = JournalDate(pageName: listings[index].nameKey) else { continue }
            listings[index].isJournal = true
            listings[index].journalDate = journalDate.pageName
        }
        return listings.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Fuzzy page-name match for `[[` autocomplete and Cmd+K, ordered by
    /// recency of access (SPEC §6.1).
    func pageNames(matching query: String) -> [String] {
        let listings = allPages()
        let recentKeys = (try? store.cache.recentPageKeys()) ?? []
        let recencyRank: [String: Int] = Dictionary(
            uniqueKeysWithValues: recentKeys.enumerated().map { ($1, $0) }
        )
        func recency(_ key: String) -> Int { recencyRank[key] ?? Int.max }
        if query.isEmpty {
            return listings.sorted { a, b in
                let ra = recency(a.nameKey), rb = recency(b.nameKey)
                return ra != rb ? ra < rb
                    : a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }.map(\.displayName)
        }
        // Rank by match closeness first (exact → prefix → substring → loose
        // subsequence). Within a tier, created regular pages rank above journal
        // days and stubs (uncreated pages a link merely points at), so typing
        // "[[Mar" surfaces Marina/Marine/Mars ahead of a wall of date pages
        // (e.g. `[[Mar 1st, 2026]]` stubs from an unconverted Logseq import).
        // Then recency, then alphabetically.
        func demoted(_ l: PageListing) -> Bool { l.isJournal || !l.fileExists }
        return listings.compactMap { l in matchTier(query: query, in: l.displayName).map { (l, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if demoted(a.0) != demoted(b.0) { return !demoted(a.0) }
                let ra = recency(a.0.nameKey), rb = recency(b.0.nameKey)
                if ra != rb { return ra < rb }
                return a.0.displayName.localizedCaseInsensitiveCompare(b.0.displayName) == .orderedAscending
            }
            .map(\.0.displayName)
    }
}

/// Match closeness of `query` against `candidate`, case-insensitive; nil if no
/// match. Lower is closer: 0 exact, 1 prefix, 2 substring, 3 loose subsequence.
/// Normalizes a page name or query for search: case- *and* accent-insensitive,
/// and locale-independent so ranking is the same in every region.
///
/// Block search folds accents through FTS5's `remove_diacritics 2`, so page-name
/// search has to fold them too - otherwise `cafe` finds a block mentioning Café
/// but not the page named Café.
func searchFolded(_ text: String) -> String {
    // Folding costs ~5x lowercasing, and page names are usually plain ASCII,
    // where the two agree. This is on every row of every keystroke.
    guard text.utf8.contains(where: { $0 >= 0x80 }) else { return text.lowercased() }
    return text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}

func matchTier(query: String, in candidate: String) -> Int? {
    let q = searchFolded(query), c = searchFolded(candidate)
    if c == q { return 0 }
    if c.hasPrefix(q) { return 1 }
    if c.contains(q) { return 2 }
    return fuzzySubsequence(query: q, in: c) ? 3 : nil
}

/// Subsequence fuzzy match, case- and accent-insensitive.
func fuzzyMatch(query: String, in candidate: String) -> Bool {
    fuzzySubsequence(query: searchFolded(query), in: searchFolded(candidate))
}

/// The subsequence test itself, on already-folded input.
private func fuzzySubsequence(query q: String, in c: String) -> Bool {
    var qi = q.startIndex
    for ch in c {
        guard qi < q.endIndex else { return true }
        if ch == q[qi] { qi = q.index(after: qi) }
    }
    return qi == q.endIndex
}
