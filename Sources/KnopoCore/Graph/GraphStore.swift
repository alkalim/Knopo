import CryptoKit
import Foundation

/// English is the library's default; the app localizes these cases at its own
/// boundary (`NSAlert(for:)`), so the engine never reads `Bundle.main`.
public enum GraphError: LocalizedError {
    case invalidPageName(String)
    case pageAlreadyExists(String)
    case pageNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPageName(let n): return "Invalid page name: “\(n)”"
        case .pageAlreadyExists(let n): return "A page named “\(n)” already exists"
        case .pageNotFound(let n): return "No page named “\(n)”"
        }
    }
}

/// A graph: a directory on disk containing all pages of one knowledge base
/// (SPEC §2, §4.1). Owns file IO, the cache index, and config; pages are the
/// source of truth, everything else is derived.
public final class GraphStore {
    /// The sendable, rebuildable portion of a graph. It owns no loaded pages or
    /// authoritative config, so AppState can run maintenance off the main actor.
    public struct IndexMaintenance: Sendable {
        private let root: URL
        private let cache: CacheDB

        fileprivate init(root: URL, cache: CacheDB) {
            self.root = root
            self.cache = cache
        }

        @discardableResult
        public func rebuild() throws -> Set<String> {
            let onDisk = try GraphStore.synchronizeIndexFiles(
                at: root, cache: cache, force: true)
            try cache.setIndexVersion(CacheDB.indexVersion)
            return onDisk
        }

        /// Logical SQLite database size. Unlike filesystem allocation for the
        /// WAL/SHM sidecars, this is stable across equivalent rebuilds.
        public func sizeOnDisk() -> Int64? {
            cache.logicalSize()
        }
    }

    /// Immutable input for page persistence. `revision` ties a completed write
    /// back to the in-memory version it came from, so a slow older save cannot
    /// mark newer edits clean.
    public struct PageSaveSnapshot: Sendable {
        public let document: PageDocument
        fileprivate let revision: UInt64
    }

    /// The thread-safe half of GraphStore persistence. It owns no loaded-page or
    /// configuration state, so AppState can use it from its serial save queue.
    public final class PagePersistence: @unchecked Sendable {
        private let root: URL
        private let cache: CacheDB
        /// Digest of the text last written for each page key, so a save that
        /// serializes to what is already on disk writes nothing. Typing a
        /// character and deleting it again, or any save with no net change,
        /// would otherwise rewrite the whole file and reindex the whole page —
        /// and each rewrite is a new version for file-versioning cloud storage.
        private let writtenLock = NSLock()
        private var writtenDigests: [String: SHA256Digest] = [:]

        fileprivate init(root: URL, cache: CacheDB) {
            self.root = root
            self.cache = cache
        }

        @discardableResult
        public func persist(
            _ snapshot: PageSaveSnapshot
        ) throws -> CacheDB.FileStamp? {
            var doc = snapshot.document
            let text = PageSerializer.serialize(preamble: doc.preamble, blocks: doc.blocks)
            let directory = doc.isJournal
                ? GraphStore.journalsDir(at: root) : GraphStore.pagesDir(at: root)
            let url = directory
                .appendingPathComponent(PageName.fileName(for: doc.name))
            let data = Data(text.utf8)
            let digest = SHA256.hash(data: data)

            writtenLock.lock()
            let unchanged = writtenDigests[doc.nameKey] == digest
            writtenLock.unlock()
            // Only trust the digest while the file it describes is still there:
            // a page deleted or restored behind our back must be rewritten.
            if unchanged, let stamp = GraphStore.stamp(of: url) { return stamp }

            try data.write(to: url, options: .atomic)
            writtenLock.lock()
            writtenDigests[doc.nameKey] = digest
            writtenLock.unlock()

            doc.fileExists = true
            doc.isDirty = false
            let stamp = GraphStore.stamp(of: url)
            try cache.indexPage(doc, stamp: stamp)
            return stamp
        }

        /// Forgets a page's digest — after a rename or delete, where the next
        /// write targets a different file (or the same name means something new).
        func forget(pageKey: String) {
            writtenLock.lock()
            writtenDigests[pageKey] = nil
            writtenLock.unlock()
        }
    }

    public let root: URL
    public let cache: CacheDB
    public let pagePersistence: PagePersistence
    public private(set) var config: GraphConfig

    /// In-memory documents (parsed on demand). Key = normalized page name.
    private var loaded: [String: PageDocument] = [:]
    private var loadedRevisions: [String: UInt64] = [:]

    /// Called after pages change on disk behind the app's back (external edits).
    public var onExternalChange: ((Set<String>) -> Void)?

    public var pagesDir: URL { Self.pagesDir(at: root) }
    public var journalsDir: URL { Self.journalsDir(at: root) }
    public var dotDir: URL { root.appendingPathComponent(".knopo", isDirectory: true) }
    public var assetsDir: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var configURL: URL { dotDir.appendingPathComponent("config.json") }
    public var conflictsDir: URL { dotDir.appendingPathComponent("conflicts", isDirectory: true) }
    public var indexMaintenance: IndexMaintenance {
        IndexMaintenance(root: root, cache: cache)
    }

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for dir in [Self.pagesDir(at: root), Self.journalsDir(at: root),
                    root.appendingPathComponent(".knopo", isDirectory: true)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let cache = try CacheDB(url: root.appendingPathComponent(".knopo/cache.db"))
        self.cache = cache
        self.pagePersistence = PagePersistence(root: root, cache: cache)
        self.config = GraphConfig.load(from: root.appendingPathComponent(".knopo/config.json"))
        // A cache built by older indexing logic is fully rebuilt (incremental
        // sync would otherwise skip unchanged files and keep stale rows).
        let staleIndex = cache.indexVersion != CacheDB.indexVersion
        try synchronizeIndex(force: staleIndex)
        if staleIndex { try cache.setIndexVersion(CacheDB.indexVersion) }
    }

    // MARK: - Index synchronization

    /// Walks pages/ and journals/, (re)indexing files whose (mtime, size)
    /// changed since last indexed, and dropping index rows for deleted files.
    /// With an intact cache this touches no file contents — the <3s cold-start
    /// path (SPEC §14).
    public func synchronizeIndex(force: Bool = false) throws {
        let onDisk = try Self.synchronizeIndexFiles(at: root, cache: cache, force: force)
        pruneStaleFavourites(onDisk: onDisk)
    }

    /// Removes favourites whose files disappeared. Rebuild runs its file walk
    /// off the main actor and then calls this config-owning part on AppState.
    public func pruneStaleFavourites(onDisk: Set<String>) {
        // A favourite may point at a journal stub (today), so only drop ones
        // that are neither on disk nor valid journal dates.
        let before = config.favourites
        config.favourites.removeAll { name in
            !onDisk.contains(PageName.key(name)) && JournalDate(pageName: name) == nil
        }
        if config.favourites != before { try? saveConfig() }
    }

    /// Shared file synchronization for startup, external force-sync, and the
    /// user-triggered rebuild. Returns the on-disk keys for config cleanup.
    private static func synchronizeIndexFiles(
        at root: URL, cache: CacheDB, force: Bool
    ) throws -> Set<String> {
        if force { try cache.clearAll() }
        let known = force ? [:] : try cache.fileStamps()
        var onDisk = Set<String>()
        for (url, name, key, isJournal) in resolvedFiles(at: root) {
            onDisk.insert(key)
            guard let stamp = Self.stamp(of: url) else { continue }
            if !force, known[key] == stamp { continue }
            let doc = Self.read(url: url, name: name, isJournal: isJournal)
            try cache.indexPage(doc, stamp: stamp)
        }
        for listing in try cache.allPages() where !onDisk.contains(listing.nameKey) {
            try cache.removePage(key: listing.nameKey)
        }
        return onDisk
    }

    private static func pagesDir(at root: URL) -> URL {
        root.appendingPathComponent("pages", isDirectory: true)
    }

    private static func journalsDir(at root: URL) -> URL {
        root.appendingPathComponent("journals", isDirectory: true)
    }

    private static func pageFiles(at root: URL) -> [(url: URL, isJournal: Bool)] {
        let fm = FileManager.default
        func list(_ dir: URL, journal: Bool) -> [(URL, Bool)] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "md" }
                .map { ($0, journal) }
        }
        return list(pagesDir(at: root), journal: false)
            + list(journalsDir(at: root), journal: true)
    }

    /// `pageFiles()` with journal identity resolved. `PageName.key` already folds
    /// a Logseq `2026_03_01` and a native `2026-03-01` onto the same canonical ISO
    /// key, so when both files exist for one day this keeps only the native one
    /// (the Logseq file is ignored, SPEC §10) — otherwise directory order would
    /// decide which spelling backs the day. Regular pages pass through unchanged.
    /// `name` is the on-disk stem (so `page(named:)`/`savePage` reach the real
    /// file); `key` is what the index and the `loaded` cache key on.
    private static func resolvedFiles(
        at root: URL
    ) -> [(url: URL, name: String, key: String, isJournal: Bool)] {
        var regular: [(url: URL, name: String, key: String, isJournal: Bool)] = []
        var journals: [String: (url: URL, name: String, native: Bool)] = [:]
        for (url, isJournal) in pageFiles(at: root) {
            guard let name = PageName.name(fromFileName: url.lastPathComponent) else { continue }
            guard isJournal, let date = JournalDate(pageName: name) else {
                regular.append((url, name, PageName.key(name), isJournal))
                continue
            }
            let key = PageName.key(date.pageName)
            let native = url.lastPathComponent == PageName.fileName(for: date.pageName)
            if let existing = journals[key] {
                if native && !existing.native { journals[key] = (url, name, native) }
            } else {
                journals[key] = (url, name, native)
            }
        }
        return regular + journals.map { (key, j) in (j.url, j.name, key, true) }
    }

    public static func stamp(of url: URL) -> CacheDB.FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return CacheDB.FileStamp(mtime: mtime.timeIntervalSince1970, size: size)
    }

    private static func read(url: URL, name: String, isJournal: Bool) -> PageDocument {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = PageParser.parse(text)
        return PageDocument(
            name: name, blocks: parsed.blocks, preamble: parsed.preamble,
            isJournal: isJournal, fileExists: true
        )
    }

    // MARK: - Page access

    public func fileURL(forPageNamed name: String) -> URL {
        let isJournal = JournalDate(pageName: name) != nil
        return (isJournal ? journalsDir : pagesDir)
            .appendingPathComponent(PageName.fileName(for: name))
    }

    /// Loads a page, or materializes an in-memory stub if no file exists.
    /// Every navigable name resolves: real pages, stubs, journal days.
    public func page(named name: String) -> PageDocument {
        let key = PageName.key(name)
        if let doc = loaded[key] { return doc }
        // Resolve to the on-disk display name for this key. This is what maps a
        // canonical date key back to the actual file — e.g. an ISO reference
        // `2026-06-10` to the imported journal file `2026_06_10.md`.
        let resolvedName = (try? cache.page(key: key))?.displayName ?? name
        let url = fileURL(forPageNamed: resolvedName)
        let doc: PageDocument
        if FileManager.default.fileExists(atPath: url.path) {
            doc = Self.read(url: url, name: resolvedName,
                            isJournal: JournalDate(pageName: resolvedName) != nil)
        } else {
            // New page/stub. A journal stub canonicalizes to its ISO name, so a
            // freshly-created journal gets an ISO filename.
            let newName = JournalDate(pageName: name)?.pageName ?? name
            doc = PageDocument(
                name: newName, blocks: [Block(content: "")],
                isJournal: JournalDate(pageName: newName) != nil, fileExists: false
            )
        }
        loaded[key] = doc
        return doc
    }

    public func isLoaded(_ name: String) -> Bool { loaded[PageName.key(name)] != nil }

    /// Replaces the in-memory document (marks dirty). Call `savePage` to flush.
    public func updatePage(_ doc: PageDocument) {
        var d = doc
        d.isDirty = true
        loaded[d.nameKey] = d
        loadedRevisions[d.nameKey, default: 0] &+= 1
    }

    /// Serializes and writes the page, then reindexes it. Stubs with no real
    /// content stay file-less (lazy creation, SPEC §3.2, §10).
    public func savePage(named name: String) throws {
        guard let snapshot = pageSaveSnapshot(named: name) else { return }
        _ = try persistPageSnapshot(snapshot)
        finishPageSave(snapshot)
    }

    /// Captures only main-thread-owned state. The returned value is independent
    /// of `loaded` and can be serialized/indexed by a background writer.
    public func pageSaveSnapshot(named name: String) -> PageSaveSnapshot? {
        let key = PageName.key(name)
        guard let doc = loaded[key] else { return nil }
        if !doc.fileExists && doc.isEffectivelyEmpty {
            // Empty journal days and reference stubs remain file-less (§10).
            return nil
        }
        return PageSaveSnapshot(
            document: doc, revision: loadedRevisions[key, default: 0])
    }

    /// Performs no access to mutable in-memory graph state: only immutable paths,
    /// the supplied value snapshot, and CacheDB's thread-safe writer are touched.
    /// AppState serializes calls to preserve file-write order.
    @discardableResult
    public func persistPageSnapshot(
        _ snapshot: PageSaveSnapshot
    ) throws -> CacheDB.FileStamp? {
        try pagePersistence.persist(snapshot)
    }

    /// Reconciles a completed snapshot with the live document. Returns true only
    /// when no edit superseded the snapshot.
    @discardableResult
    public func finishPageSave(_ snapshot: PageSaveSnapshot) -> Bool {
        let key = snapshot.document.nameKey
        guard var current = loaded[key] else { return false }
        current.fileExists = true
        let isCurrent = loadedRevisions[key, default: 0] == snapshot.revision
        if isCurrent { current.isDirty = false }
        loaded[key] = current
        return isCurrent
    }

    public func createPage(named name: String) throws -> PageDocument {
        guard PageName.isValid(name) else { throw GraphError.invalidPageName(name) }
        let key = PageName.key(name)
        if let existing = try cache.page(key: key), existing.fileExists {
            throw GraphError.pageAlreadyExists(name)
        }
        var doc = page(named: name)
        if doc.blocks.isEmpty { doc.blocks = [Block(content: "")] }
        loaded[key] = doc
        return doc
    }

    /// Moves the page's file to the OS trash (SPEC §13). Incoming `[[refs]]`
    /// now point at a stub; incoming `((refs))` go broken.
    public func deletePage(named name: String) throws {
        let key = PageName.key(name)
        // Trash the actual backing file, which for an imported journal may be a
        // Logseq `2026_03_01.md` rather than the canonical `2026-03-01.md`.
        let resolvedName = (try? cache.page(key: key))?.displayName ?? name
        let url = fileURL(forPageNamed: resolvedName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        loaded.removeValue(forKey: key)
        loadedRevisions.removeValue(forKey: key)
        pagePersistence.forget(pageKey: key)
        try cache.removePage(key: key)
        config.removeFavourite(name)
        try saveConfig()
    }

    // MARK: - Block references

    /// Marks a block's id as persisted (so `((id))` stays durable) and saves
    /// its page. (SPEC §7.1)
    public func persistBlockID(_ blockID: UUID, inPageNamed name: String) throws {
        var doc = page(named: name)
        if let path = doc.blocks.path(to: blockID) {
            doc.blocks.update(at: path) { $0.idPersisted = true }
        } else if let position = try cache.position(ofBlock: blockID),
                  let path = doc.blocks.path(atPreorderPosition: position) {
            // The id handed to us came from the index, where un-persisted blocks
            // get a fresh random id on every parse — so it won't match this
            // freshly-loaded page. Relocate the block by its structural position
            // and force it to adopt the referenced id, so the just-inserted
            // `((id))` / `{{embed ((id))}}` stays resolvable.
            doc.blocks.update(at: path) {
                $0 = Block(id: blockID, content: $0.content, children: $0.children,
                           collapsed: $0.collapsed, idPersisted: true,
                           properties: $0.properties, raw: nil)
            }
        } else {
            return
        }
        updatePage(doc)
        try savePage(named: name)
    }

    /// Resolves a block id to (page, content), preferring in-memory documents.
    public func resolveBlock(_ id: UUID) -> (pageName: String, block: Block)? {
        for (_, doc) in loaded {
            if let path = doc.blocks.path(to: id), let block = doc.blocks.block(at: path) {
                return (doc.name, block)
            }
        }
        if let hit = (try? cache.locateBlock(id)) ?? nil {
            let doc = page(named: (try? cache.page(key: hit.pageKey))?.displayName ?? hit.pageKey)
            // Direct id match (a persisted `id::`), else relocate by the index's
            // preorder position: an un-persisted block gets a fresh random id on
            // every parse, so the index id won't match this freshly-loaded page
            // (SPEC §7.1). Same idiom as `persistBlockID`.
            var path = doc.blocks.path(to: id)
            if path == nil, let position = (try? cache.position(ofBlock: id)) ?? nil {
                path = doc.blocks.path(atPreorderPosition: position)
            }
            if let path, let block = doc.blocks.block(at: path) {
                return (doc.name, block)
            }
        }
        return nil
    }

    // MARK: - Rename (SPEC §6.2)

    /// Rewrites every `[[old]]` to `[[new]]` across the graph (case-insensitive,
    /// not touching `#[[...]]` tags), renames the file, follows favourites.
    /// Returns the keys of all modified pages (for UI refresh / undo grouping).
    @discardableResult
    public func renamePage(from oldName: String, to newName: String) throws -> Set<String> {
        guard PageName.isValid(newName) else { throw GraphError.invalidPageName(newName) }
        let oldKey = PageName.key(oldName)
        let newKey = PageName.key(newName)
        if oldKey != newKey, let existing = try cache.page(key: newKey), existing.fileExists {
            throw GraphError.pageAlreadyExists(newName)
        }

        var touched: Set<String> = []
        let pattern = "(?<!#)\\[\\[\\s*" + NSRegularExpression.escapedPattern(for: oldName)
            + "\\s*\\]\\]"
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for sourceKey in try cache.pagesReferencing(pageKey: oldKey) where sourceKey != oldKey {
            guard let display = try cache.page(key: sourceKey)?.displayName else { continue }
            var doc = page(named: display)
            if rewriteBlocks(&doc.blocks, regex: regex, replacement: "[[\(newName)]]") {
                updatePage(doc)
                try savePage(named: doc.name)
                touched.insert(sourceKey)
            }
        }

        // Rename the page itself (file + in-memory + index + config).
        var doc = page(named: oldName)
        _ = rewriteBlocks(&doc.blocks, regex: regex, replacement: "[[\(newName)]]") // self-refs
        let oldURL = fileURL(forPageNamed: doc.name)
        let renamedRevision = loadedRevisions.removeValue(forKey: oldKey) ?? 0
        loaded.removeValue(forKey: oldKey)
        pagePersistence.forget(pageKey: oldKey)
        doc.name = newName
        doc.isJournal = JournalDate(pageName: newName) != nil
        loaded[newKey] = doc
        loadedRevisions[newKey] = renamedRevision &+ 1
        // Clear the old page from the index *before* re-indexing the same blocks
        // under the new key. Block ids are globally unique (`blocks.id` PRIMARY
        // KEY); a loaded page keeps its ids across the rename, so re-indexing
        // while the old rows survive collides ("UNIQUE constraint: blocks.id").
        try cache.removePage(key: oldKey)
        if doc.fileExists {
            let newURL = fileURL(forPageNamed: newName)
            if FileManager.default.fileExists(atPath: oldURL.path), oldURL != newURL {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            }
            updatePage(doc)
            try savePage(named: newName) // writes the file and re-indexes under newKey
        }
        try cache.renameInRecents(oldKey: oldKey, newKey: newKey)
        config.renameFavourite(from: oldName, to: newName)
        try saveConfig()
        touched.insert(oldKey)
        touched.insert(newKey)
        return touched
    }

    /// Rewrites `#old` / `#[[old]]` to the new tag everywhere (SPEC §8.2).
    @discardableResult
    public func renameTag(from oldTag: String, to newTag: String) throws -> Set<String> {
        let old = oldTag.lowercased()
        let new = newTag.lowercased()
        let replacement = new.contains(where: { $0.isWhitespace }) ? "#[[\(new)]]" : "#\(new)"
        let word = "#" + NSRegularExpression.escapedPattern(for: old) + "(?![\\w-])"
        let bracketed = "#\\[\\[\\s*" + NSRegularExpression.escapedPattern(for: old) + "\\s*\\]\\]"
        let regex = try NSRegularExpression(
            pattern: "(?:\(bracketed))|(?:\(word))", options: [.caseInsensitive]
        )
        var touched: Set<String> = []
        for sourceKey in try cache.pagesUsingTag(old) {
            guard let display = try cache.page(key: sourceKey)?.displayName else { continue }
            var doc = page(named: display)
            if rewriteBlocks(&doc.blocks, regex: regex, replacement: replacement) {
                updatePage(doc)
                try savePage(named: doc.name)
                touched.insert(sourceKey)
            }
        }
        // A favourited tag follows the rename (§11.1, extended to tags).
        if config.isFavouriteTag(old) {
            config.renameFavouriteTag(from: old, to: new)
            try saveConfig()
        }
        return touched
    }

    private func rewriteBlocks(
        _ blocks: inout [Block], regex: NSRegularExpression, replacement: String
    ) -> Bool {
        var changed = false
        for i in blocks.indices {
            let content = blocks[i].content
            let range = NSRange(content.startIndex..., in: content)
            if regex.firstMatch(in: content, range: range) != nil {
                blocks[i].content = regex.stringByReplacingMatches(
                    in: content, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
                changed = true
            }
            if rewriteBlocks(&blocks[i].children, regex: regex, replacement: replacement) {
                changed = true
            }
        }
        return changed
    }

    // MARK: - External changes (SPEC §4.2)

    /// Reloads pages whose files changed externally. If a page has unsaved
    /// in-memory edits, last-writer-wins: the on-disk version (newer) wins and
    /// the losing in-memory version is saved to `.knopo/conflicts/`.
    /// Returns the set of affected page keys.
    @discardableResult
    public func handleExternalChanges() throws -> Set<String> {
        var affected = Set<String>()
        var onDisk = Set<String>()
        let knownStamps = try cache.fileStamps()
        for (url, name, key, isJournal) in Self.resolvedFiles(at: root) {
            onDisk.insert(key)
            guard let stamp = Self.stamp(of: url) else { continue }
            if knownStamps[key] == stamp { continue }

            if let inMemory = loaded[key], inMemory.isDirty {
                try saveConflictCopy(of: inMemory)
            }
            let doc = Self.read(url: url, name: name, isJournal: isJournal)
            loaded[key] = doc
            loadedRevisions[key, default: 0] &+= 1
            // The file changed outside the app: whatever we last wrote is moot.
            pagePersistence.forget(pageKey: key)
            try cache.indexPage(doc, stamp: stamp)
            affected.insert(key)
        }
        for listing in try cache.allPages() where listing.fileExists && !onDisk.contains(listing.nameKey) {
            try cache.removePage(key: listing.nameKey)
            loaded.removeValue(forKey: listing.nameKey)
            loadedRevisions.removeValue(forKey: listing.nameKey)
            affected.insert(listing.nameKey)
        }
        if !affected.isEmpty { onExternalChange?(affected) }
        return affected
    }

    private func saveConflictCopy(of doc: PageDocument) throws {
        try FileManager.default.createDirectory(at: conflictsDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stampStr = formatter.string(from: Date())
        let fileName = PageName.fileName(for: doc.name)
            .replacingOccurrences(of: ".md", with: "-\(stampStr).md")
        let text = PageSerializer.serialize(preamble: doc.preamble, blocks: doc.blocks)
        try Data(text.utf8).write(
            to: conflictsDir.appendingPathComponent(fileName), options: .atomic
        )
    }

    // MARK: - Config

    public func saveConfig() throws {
        try config.save(to: configURL)
    }

    public func updateConfig(_ transform: (inout GraphConfig) -> Void) throws {
        let previous = config
        transform(&config)
        do {
            try saveConfig()
        } catch {
            config = previous
            throw error
        }
    }
}
