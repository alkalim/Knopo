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
    /// Nil until the background semantic model starts; then tracks its
    /// rebuildable, per-block cache progress for Related/search UI.
    @Published private(set) var embeddingIndexStatus: EmbeddingIndexStatus?
    /// Bumped after embedding batches so Related surfaces can refresh as the
    /// first-run index fills without tying themselves to every progress label.
    @Published private(set) var semanticDataVersion = 0
    @Published private(set) var semanticUnavailableReason: String?
    /// Shared by every All Pages view for this graph and persisted in config.
    @Published private(set) var allPagesCollapsedSections: Set<String> = []

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
    private let localAI: OnDeviceAIService
    private var localAIStarted = false
    private var embeddingBackfillTask: Task<Void, Never>?
    private var embeddingBackfillGeneration = 0

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

    init(store: GraphStore) {
        self.store = store
        self.localAI = OnDeviceAIService(cache: store.cache)
        allPagesCollapsedSections = Set(store.config.allPagesCollapsedSections)
        store.onExternalChange = { [weak self] _ in
            self?.dataVersion += 1
            self?.restartEmbeddingBackfillIfStarted()
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
        startDayRolloverWatch()
    }

    /// Called before this graph session is replaced (File → Open Graph…):
    /// flush unsaved edits and stop watching the old directory.
    func shutdown() {
        flushPendingSaves()
        embeddingBackfillTask?.cancel()
        embeddingBackfillTask = nil
        watcher?.stop()
        watcher = nil
        dayRollover?.cancel()
        dayRollover = nil
        dayObservers.forEach(NotificationCenter.default.removeObserver)
        dayObservers = []
    }

    // MARK: - On-device AI

    /// Starts the potentially slow first-run embedding fill. MainWindow calls
    /// this after appearing so GraphStore construction and app launch remain
    /// synchronous and fast; all model work stays off the main actor.
    func startLocalAI() {
        guard !localAIStarted else { return }
        localAIStarted = true
        restartEmbeddingBackfillIfStarted()
    }

    private func restartEmbeddingBackfillIfStarted() {
        guard localAIStarted else { return }
        embeddingBackfillTask?.cancel()
        embeddingBackfillGeneration += 1
        let generation = embeddingBackfillGeneration
        let service = localAI
        semanticUnavailableReason = nil
        embeddingBackfillTask = Task { [weak self] in
            let unavailableReason = await service.backfill { [weak self] status in
                guard let self, self.embeddingBackfillGeneration == generation else { return }
                let completedChanged = self.embeddingIndexStatus?.completed != status.completed
                self.embeddingIndexStatus = status
                if completedChanged { self.semanticDataVersion += 1 }
            }
            guard let self, self.embeddingBackfillGeneration == generation else { return }
            self.semanticUnavailableReason = unavailableReason
            self.embeddingBackfillTask = nil
        }
    }

    func retrieve(_ query: String, limit: Int = 20) async -> [SearchHit] {
        startLocalAI()
        return await localAI.retrieve(query, limit: limit)
    }

    func related(
        toPageNamed name: String, blockID: UUID? = nil, limit: Int = 6
    ) async -> [SemanticHit] {
        startLocalAI()
        let blockText = blockID.flatMap { store.resolveBlock($0)?.block.content }
        return await localAI.related(
            toPageKey: PageName.key(name), blockID: blockID,
            blockText: blockText, limit: limit)
    }

    func askAvailability() async -> AskAvailability {
        await localAI.askAvailability()
    }

    func answerNotesQuestion(_ question: String) async throws -> GroundedAnswer {
        let requestID = String(UUID().uuidString.prefix(8)).lowercased()
        let submittedAt = AIPerformanceLog.now()
        AIPerformanceLog.emit(
            requestID: requestID, event: "request.submitted",
            fields: ["question_utf8=\(question.utf8.count)"])
        startLocalAI()
        return try await localAI.answer(
            question, requestID: requestID, submittedAt: submittedAt)
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
            self.restartEmbeddingBackfillIfStarted()
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
        restartEmbeddingBackfillIfStarted()
    }

    func flushPendingSaves() {
        let savedAny = !pendingSaves.isEmpty
        for (key, work) in pendingSaves {
            work.cancel()
            if let doc = storeLoadedDoc(key) {
                try? store.savePage(named: doc.name)
            }
        }
        if savedAny {
            dataVersion += 1
            restartEmbeddingBackfillIfStarted()
        }
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
        closePendingEdit?()
        guard let entry = undoStack.popLast() else { return }
        for doc in entry.before {
            store.updatePage(doc)
            try? store.savePage(named: doc.name)
        }
        redoStack.append(entry)
        dataVersion += 1
        restartEmbeddingBackfillIfStarted()
    }

    func redo() {
        closePendingEdit?()
        guard let entry = redoStack.popLast() else { return }
        for doc in entry.after {
            store.updatePage(doc)
            try? store.savePage(named: doc.name)
        }
        undoStack.append(entry)
        dataVersion += 1
        restartEmbeddingBackfillIfStarted()
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
        restartEmbeddingBackfillIfStarted()
        return true
    }

    /// Renames a tag across the graph. Flushes pending edits first for the same
    /// reason as `renamePage` (the rewrite is index-driven).
    func renameTag(from old: String, to new: String) throws {
        flushPendingSaves()
        _ = try store.renameTag(from: old, to: new)
        dataVersion += 1
        restartEmbeddingBackfillIfStarted()
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

    /// Body-text font weight (View ▸ Font Weight). Stored (not a passthrough to
    /// the `BlockRenderer` global) so the menu's radio state is observable and
    /// its checkmark tracks the selection; the didSet feeds the render-time
    /// global and, like zoom/density, bumps `dataVersion` so every open outline
    /// re-renders at the new weight.
    @Published var contentWeight: BlockRenderer.ContentWeight = BlockRenderer.contentWeight {
        didSet {
            guard contentWeight != oldValue else { return }
            BlockRenderer.contentWeight = contentWeight   // persists + render source
            dataVersion += 1
        }
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
