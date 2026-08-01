import Foundation
import GRDB

private enum CacheAIPerformanceLog {
    private static let isEnabled =
        ProcessInfo.processInfo.environment["KNOPO_AI_PERF"] == "1"

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func milliseconds(from start: UInt64, to end: UInt64? = nil) -> Double {
        let end = end ?? now()
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    static func emit(
        requestID: String?, event: String, startedAt: UInt64? = nil,
        fields: [String] = []
    ) {
        guard isEnabled, let requestID else { return }
        let timestamp = now()
        var parts = [
            "KNOPO_AI_PERF",
            "request=\(requestID)",
            "event=\(event)",
            "uptime_ms=\(format(Double(timestamp) / 1_000_000))",
        ]
        if let startedAt {
            parts.append("duration_ms=\(format(milliseconds(from: startedAt, to: timestamp)))")
        }
        parts.append(contentsOf: fields)
        print(parts.joined(separator: " "))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// One row of backlink lookup: a block somewhere in the graph that references
/// the page in question (SPEC §9.1).
public struct BacklinkHit: Equatable, Sendable {
    public var blockID: UUID
    public var pageKey: String
    public var pageDisplayName: String
    public var content: String
}

public struct SearchHit: Equatable, Sendable {
    public var blockID: UUID
    public var pageKey: String
    public var pageDisplayName: String
    public var content: String
}

public struct PageListing: Equatable, Sendable {
    public var nameKey: String
    public var displayName: String
    public var isJournal: Bool
    public var journalDate: String?
    public var fileExists: Bool
    public var blockCount: Int

    public init(
        nameKey: String, displayName: String, isJournal: Bool,
        journalDate: String?, fileExists: Bool, blockCount: Int
    ) {
        self.nameKey = nameKey
        self.displayName = displayName
        self.isJournal = isJournal
        self.journalDate = journalDate
        self.fileExists = fileExists
        self.blockCount = blockCount
    }
}

/// The rebuildable index in `.knopo/cache.db` (SPEC §4.1, §9.3, §17).
///
/// Stores, per block: content, structure (parent/position/depth), page refs,
/// block refs, tags, properties, TODO/DONE state, and the containing page's
/// name and journal date — the §17 index-completeness commitment. Deleting the
/// file loses nothing but recents.
public final class CacheDB {
    private let dbQueue: DatabaseQueue

    /// Bumped whenever the *indexing logic* changes (not the schema) so an
    /// existing cache, whose rows were derived by older code, is force-rebuilt
    /// on next open. v2: recognize Logseq `yyyy_MM_dd` journal filenames.
    /// v3: canonicalize date page keys to ISO (cross-spelling journal refs).
    /// v6: recognize the friendly date form `Jun 10th, 2026` as a journal day.
    /// v7: record stable block-content hashes for incremental embeddings.
    public static let indexVersion: Int = 7

    /// The index version this cache was last built with (PRAGMA user_version,
    /// independent of the schema migrator). 0 on a fresh/old database.
    public var indexVersion: Int {
        let value = try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        return value.flatMap { $0 } ?? 0
    }

    public func setIndexVersion(_ version: Int) throws {
        // PRAGMA user_version must run outside a transaction (GRDB's `write`
        // wraps one), or the change is discarded.
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: url.path)
        try migrate()
    }

    /// In-memory database, for tests.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE pages (
                    name_key TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    is_journal INTEGER NOT NULL DEFAULT 0,
                    journal_date TEXT,
                    file_exists INTEGER NOT NULL DEFAULT 1,
                    file_mtime REAL,
                    file_size INTEGER
                );
                CREATE TABLE blocks (
                    id TEXT PRIMARY KEY,
                    page_key TEXT NOT NULL,
                    parent_id TEXT,
                    position INTEGER NOT NULL,
                    depth INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    todo TEXT,
                    collapsed INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX blocks_page ON blocks(page_key);
                CREATE TABLE page_refs (
                    block_id TEXT NOT NULL,
                    page_key TEXT NOT NULL,
                    target_key TEXT NOT NULL
                );
                CREATE INDEX page_refs_target ON page_refs(target_key);
                CREATE INDEX page_refs_page ON page_refs(page_key);
                CREATE TABLE block_refs (
                    block_id TEXT NOT NULL,
                    page_key TEXT NOT NULL,
                    target_id TEXT NOT NULL
                );
                CREATE INDEX block_refs_target ON block_refs(target_id);
                CREATE INDEX block_refs_page ON block_refs(page_key);
                CREATE TABLE tags (
                    block_id TEXT NOT NULL,
                    page_key TEXT NOT NULL,
                    tag TEXT NOT NULL
                );
                CREATE INDEX tags_tag ON tags(tag);
                CREATE INDEX tags_page ON tags(page_key);
                CREATE TABLE props (
                    block_id TEXT NOT NULL,
                    page_key TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE INDEX props_page ON props(page_key);
                CREATE VIRTUAL TABLE blocks_fts USING fts5(
                    content,
                    block_id UNINDEXED,
                    page_key UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TABLE recents (
                    page_key TEXT PRIMARY KEY,
                    opened_at REAL NOT NULL
                );
                """)
        }
        // Property queries (§17) filter by `key`; index it.
        migrator.registerMigration("v2-props-key") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS props_key ON props(key);")
        }
        // Page properties (§4.2): un-bulleted `key:: value` preamble lines. Kept
        // page-scoped (not attached to any block) so a query matches them via the
        // page's first block without conflating them with block properties.
        migrator.registerMigration("v3-page-props") { db in
            try db.execute(sql: """
                CREATE TABLE page_props (
                    page_key TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE INDEX page_props_page ON page_props(page_key);
                CREATE INDEX page_props_key ON page_props(key);
                """)
        }
        // Stubs (§3.2) display with the casing their reference was written in;
        // `target_key` is lowercased, so keep the as-written form beside it.
        migrator.registerMigration("v4-page-refs-display") { db in
            try db.execute(
                sql: "ALTER TABLE page_refs ADD COLUMN target_display TEXT NOT NULL DEFAULT ''")
        }
        // On-device semantic index. Vectors are derived cache data and are kept
        // outside `blocks` so page reindexing can retain unchanged embeddings.
        migrator.registerMigration("v5-block-embeddings") { db in
            try db.execute(sql: """
                ALTER TABLE blocks ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';
                CREATE TABLE block_embeddings (
                    block_id TEXT PRIMARY KEY,
                    page_key TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    dimension INTEGER NOT NULL,
                    vector BLOB NOT NULL
                );
                CREATE INDEX block_embeddings_page ON block_embeddings(page_key);
                CREATE INDEX block_embeddings_model ON block_embeddings(model_id, dimension);
                """)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Page indexing

    public struct FileStamp: Equatable, Sendable {
        public var mtime: Double
        public var size: Int
        public init(mtime: Double, size: Int) {
            self.mtime = mtime
            self.size = size
        }
    }

    /// Replaces all index rows for a page. Pass `stamp` for file-backed pages
    /// so unchanged files can be skipped on the next startup scan.
    public func indexPage(_ page: PageDocument, stamp: FileStamp?) throws {
        try dbQueue.write { db in
            let key = page.nameKey
            // Unpersisted block ids are regenerated when a file is parsed in a
            // later session. Snapshot derived rows before replacing the page so
            // identical content can carry its vector to the new transient id.
            let previousEmbeddings = try Row.fetchAll(db, sql: """
                SELECT block_id, content_hash, model_id, dimension, vector
                FROM block_embeddings WHERE page_key = ?
                """, arguments: [key])
            try Self.deletePageRows(db, key: key)
            let journalDate = JournalDate(pageName: page.name)
            try db.execute(
                sql: """
                    INSERT INTO pages
                    (name_key, display_name, is_journal, journal_date, file_exists, file_mtime, file_size)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    key, page.name, page.isJournal,
                    page.isJournal ? journalDate?.pageName : nil,
                    page.fileExists, stamp?.mtime, stamp?.size,
                ]
            )
            var position = 0
            func walk(_ blocks: [Block], parent: UUID?, depth: Int) throws {
                for block in blocks {
                    var blockID = block.id
                    var bid = blockID.uuidString.lowercased()
                    func insertBlock(orIgnore: Bool) throws {
                        try db.execute(
                            sql: """
                                INSERT \(orIgnore ? "OR IGNORE " : "")INTO blocks
                                (id, page_key, parent_id, position, depth, content, content_hash,
                                 todo, collapsed)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                bid, key, parent?.uuidString.lowercased(), position,
                                depth, block.content, embeddingContentHash(block.content),
                                block.todoState?.rawValue,
                                block.collapsed,
                            ]
                        )
                    }
                    try insertBlock(orIgnore: true)
                    if db.changesCount == 0 {
                        // Two files carry the same persisted `id::`. A bare INSERT
                        // would hit the PRIMARY KEY constraint and abort the whole
                        // sync, so the graph would fail to open. Re-mint a fresh
                        // index id for this later copy: it stays searchable and
                        // structurally intact, while a `((shared-id))` ref resolves
                        // to the first-indexed block. (Caused by copy/pasting a
                        // block's raw Markdown, duplicating a file, or Logseq import.)
                        blockID = UUID()
                        bid = blockID.uuidString.lowercased()
                        try insertBlock(orIgnore: false)
                    }
                    position += 1
                    try db.execute(
                        sql: "INSERT INTO blocks_fts (content, block_id, page_key) VALUES (?, ?, ?)",
                        arguments: [block.content, bid, key]
                    )
                    let refs = RefExtractor.extract(from: block.content)
                    for target in refs.pageRefs {
                        try db.execute(
                            sql: """
                            INSERT INTO page_refs (block_id, page_key, target_key, target_display)
                            VALUES (?, ?, ?, ?)
                            """,
                            arguments: [bid, key, PageName.key(target), target]
                        )
                    }
                    for target in refs.blockRefs {
                        try db.execute(
                            sql: "INSERT INTO block_refs (block_id, page_key, target_id) VALUES (?, ?, ?)",
                            arguments: [bid, key, target.uuidString.lowercased()]
                        )
                    }
                    for tag in refs.tags {
                        try db.execute(
                            sql: "INSERT INTO tags (block_id, page_key, tag) VALUES (?, ?, ?)",
                            arguments: [bid, key, tag]
                        )
                    }
                    for prop in block.properties {
                        try db.execute(
                            sql: "INSERT INTO props (block_id, page_key, key, value) VALUES (?, ?, ?, ?)",
                            arguments: [bid, key, prop.key, prop.value]
                        )
                    }
                    try walk(block.children, parent: blockID, depth: depth + 1)
                }
            }
            try walk(page.blocks, parent: nil, depth: 0)
            // Preamble page properties (un-bulleted `key:: value` lines, the
            // Logseq convention) are page-scoped: stored on their own, not on any
            // block. `{{query key:: value}}` matches them via the page's first
            // block (see `compile`), surfacing the page without polluting block
            // properties. The preamble text itself round-trips untouched.
            for prop in page.preambleProperties {
                try db.execute(
                    sql: "INSERT INTO page_props (page_key, key, value) VALUES (?, ?, ?)",
                    arguments: [key, prop.key, prop.value]
                )
            }
            // Exact id/hash pairs already point at the right block. For new
            // transient ids, copy one prior vector with the same text hash.
            // Duplicate-content blocks are interchangeable here because their
            // derived vectors are identical.
            let currentBlocks = try Row.fetchAll(db, sql: """
                SELECT id, content_hash FROM blocks WHERE page_key = ?
                """, arguments: [key])
            let exactPairs = Set(previousEmbeddings.map { row in
                "\(row["block_id"] as String)\u{0}\(row["content_hash"] as String)"
            })
            var reusableByHash: [String: Row] = [:]
            for row in previousEmbeddings {
                let hash: String = row["content_hash"]
                if reusableByHash[hash] == nil { reusableByHash[hash] = row }
            }
            for block in currentBlocks {
                let id: String = block["id"]
                let hash: String = block["content_hash"]
                guard !exactPairs.contains("\(id)\u{0}\(hash)"),
                      let old = reusableByHash[hash] else { continue }
                let modelID: String = old["model_id"]
                let dimension: Int = old["dimension"]
                let vector: Data = old["vector"]
                try db.execute(sql: """
                    INSERT OR REPLACE INTO block_embeddings
                        (block_id, page_key, content_hash, model_id, dimension, vector)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [id, key, hash, modelID, dimension, vector])
            }
            // Drop deleted blocks and blocks that changed into non-prose. Rows
            // for unchanged ids/content survive this page replacement and need
            // no re-embedding.
            try db.execute(sql: """
                DELETE FROM block_embeddings
                WHERE page_key = ? AND block_id NOT IN
                    (SELECT id FROM blocks WHERE page_key = ?)
                """, arguments: [key, key])
            try db.execute(sql: """
                DELETE FROM block_embeddings
                WHERE page_key = ? AND block_id IN
                    (SELECT id FROM blocks b WHERE b.page_key = ?
                     AND NOT (\(embeddingEligibleSQL(alias: "b"))))
                """, arguments: [key, key])
        }
    }

    public func removePage(key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM block_embeddings WHERE page_key = ?", arguments: [key])
            try Self.deletePageRows(db, key: key)
            try db.execute(sql: "DELETE FROM recents WHERE page_key = ?", arguments: [key])
        }
    }

    private static func deletePageRows(_ db: Database, key: String) throws {
        try db.execute(sql: "DELETE FROM pages WHERE name_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM blocks WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM blocks_fts WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM page_refs WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM block_refs WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM tags WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM props WHERE page_key = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM page_props WHERE page_key = ?", arguments: [key])
    }

    public func fileStamp(forPageKey key: String) throws -> FileStamp? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT file_mtime, file_size FROM pages WHERE name_key = ?",
                arguments: [key]
            )
            guard let row, let mtime: Double = row["file_mtime"],
                  let size: Int = row["file_size"] else { return nil }
            return FileStamp(mtime: mtime, size: size)
        }
    }

    /// All known file stamps in one query — the startup scan and the file
    /// watcher compare every page on disk, and a per-page query each is the
    /// dominant cost of those scans.
    public func fileStamps() throws -> [String: FileStamp] {
        try dbQueue.read { db in
            var stamps: [String: FileStamp] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT name_key, file_mtime, file_size FROM pages")
            for row in rows {
                guard let mtime: Double = row["file_mtime"],
                      let size: Int = row["file_size"] else { continue }
                stamps[row["name_key"]] = FileStamp(mtime: mtime, size: size)
            }
            return stamps
        }
    }

    public func clearAll() throws {
        try dbQueue.write { db in
            for table in ["pages", "blocks", "blocks_fts", "page_refs", "block_refs", "tags", "props", "page_props", "block_embeddings"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: - Pages

    public func allPages() throws -> [PageListing] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.*, (SELECT COUNT(*) FROM blocks b WHERE b.page_key = p.name_key) AS block_count
                FROM pages p ORDER BY p.display_name COLLATE NOCASE
                """).map(Self.listing(from:))
        }
    }

    public func page(key: String) throws -> PageListing? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT p.*, (SELECT COUNT(*) FROM blocks b WHERE b.page_key = p.name_key) AS block_count
                    FROM pages p WHERE p.name_key = ?
                    """,
                arguments: [key]
            ).map(Self.listing(from:))
        }
    }

    /// Journal pages, most recent day first.
    public func journalPages() throws -> [PageListing] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.*, (SELECT COUNT(*) FROM blocks b WHERE b.page_key = p.name_key) AS block_count
                FROM pages p WHERE p.is_journal = 1 AND p.journal_date IS NOT NULL
                ORDER BY p.journal_date DESC
                """).map(Self.listing(from:))
        }
    }

    /// A cheap fingerprint of the *set* of non-empty journal days, so the
    /// journal home can cache its (expensive) day list and only rebuild it when
    /// a day is actually added, deleted, or crosses empty↔non-empty — not on
    /// every keystroke. Far cheaper than `journalPages()`.
    ///
    /// It identifies *which* days are present, not just how many: a sorted count
    /// would miss "one day removed, another added in the same sync window" (the
    /// count is unchanged but the set differs).
    public func journalDaySignature() throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT GROUP_CONCAT(page_key) FROM (
                    SELECT DISTINCT b.page_key AS page_key
                    FROM blocks b JOIN pages p ON p.name_key = b.page_key
                    WHERE p.is_journal = 1 AND p.journal_date IS NOT NULL
                    ORDER BY b.page_key
                )
                """) ?? ""
        }
    }

    /// Page names referenced somewhere but with no file — stubs (SPEC §3.2).
    /// Returns display-cased names as first encountered in a reference (the
    /// bare `MIN(rowid)` makes SQLite pick `target_display` from that row).
    public func stubPageNames() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT target_display, MIN(rowid) FROM page_refs
                WHERE target_key NOT IN (SELECT name_key FROM pages)
                GROUP BY target_key
                ORDER BY target_key
                """)
        }
    }

    private static func listing(from row: Row) -> PageListing {
        PageListing(
            nameKey: row["name_key"],
            displayName: row["display_name"],
            isJournal: row["is_journal"],
            journalDate: row["journal_date"],
            fileExists: row["file_exists"],
            blockCount: row["block_count"]
        )
    }

    // MARK: - Backlinks (SPEC §9)

    /// Blocks anywhere in the graph that reference `pageKey` via `[[...]]`,
    /// plus blocks holding a `((ref))` to one of this page's blocks (§7.5).
    /// Self-references are excluded. O(incoming refs).
    public func backlinks(of pageKey: String) throws -> [BacklinkHit] {
        try dbQueue.read { db in
            let direct = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT b.id, b.page_key, b.content, p.display_name
                    FROM page_refs r
                    JOIN blocks b ON b.id = r.block_id
                    JOIN pages p ON p.name_key = b.page_key
                    WHERE r.target_key = ? AND r.page_key <> ?
                    """,
                arguments: [pageKey, pageKey]
            )
            let viaBlockRefs = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT src.id, src.page_key, src.content, p.display_name
                    FROM block_refs br
                    JOIN blocks tgt ON tgt.id = br.target_id
                    JOIN blocks src ON src.id = br.block_id
                    JOIN pages p ON p.name_key = src.page_key
                    WHERE tgt.page_key = ? AND src.page_key <> ?
                    """,
                arguments: [pageKey, pageKey]
            )
            var seen = Set<String>()
            var hits: [BacklinkHit] = []
            for row in direct + viaBlockRefs {
                let idString: String = row["id"]
                guard !seen.contains(idString), let uuid = UUID(uuidString: idString) else { continue }
                seen.insert(idString)
                hits.append(BacklinkHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"]
                ))
            }
            return hits.sorted { ($0.pageDisplayName, $0.content) < ($1.pageDisplayName, $1.content) }
        }
    }

    private static func breadcrumb(_ db: Database, blockID: String) throws -> [String] {
        var crumbs: [String] = []
        var cursor: String? = blockID
        var hops = 0
        while let id = cursor, hops < 64 {
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_id, content FROM blocks WHERE id = ?",
                arguments: [id]
            )
            guard let row else { break }
            if id != blockID { crumbs.append(row["content"]) }
            cursor = row["parent_id"]
            hops += 1
        }
        return crumbs.reversed()
    }

    /// Ancestor breadcrumb for one block (outermost first), looked up on
    /// demand. Reference lists no longer walk ancestors for every hit up
    /// front; each row fetches only its own breadcrumb when it renders.
    public func breadcrumb(ofBlock id: UUID) throws -> [String] {
        try dbQueue.read { db in
            try Self.breadcrumb(db, blockID: id.uuidString.lowercased())
        }
    }

    /// Blocks containing the page's name as plain text without brackets
    /// (case-insensitive, word-boundary). SPEC §9.2.
    public func unlinkedReferences(toPageNamed name: String) throws -> [SearchHit] {
        let candidates = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.block_id, f.page_key, b.content, p.display_name
                    FROM blocks_fts f
                    JOIN blocks b ON b.id = f.block_id
                    JOIN pages p ON p.name_key = f.page_key
                    WHERE blocks_fts MATCH ? AND f.page_key <> ?
                    LIMIT 500
                    """,
                arguments: [ftsPhrase(name), PageName.key(name)]
            )
        }
        let pattern = "(?<![\\[\\w#])\(NSRegularExpression.escapedPattern(for: name))(?![\\]\\w])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return [] }
        return candidates.compactMap { row in
            let content: String = row["content"]
            let range = NSRange(content.startIndex..., in: content)
            guard regex.firstMatch(in: content, range: range) != nil,
                  let uuid = UUID(uuidString: row["block_id"]) else { return nil }
            return SearchHit(
                blockID: uuid,
                pageKey: row["page_key"],
                pageDisplayName: row["display_name"],
                content: content
            )
        }
    }

    /// Cheap probe for whether the Unlinked References section is worth
    /// showing: true if any block mentions the page name in the full-text
    /// index. This is the fast half of `unlinkedReferences` (no row fetch, no
    /// word-boundary regex), so the collapsed header costs almost nothing and
    /// the full scan runs only when the user expands the section. May
    /// over-report in the rare case where every candidate fails the precise
    /// word-boundary filter (header shows, expands to nothing).
    public func hasUnlinkedReferences(toPageNamed name: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM blocks_fts
                    WHERE blocks_fts MATCH ? AND page_key <> ?
                )
                """, arguments: [ftsPhrase(name), PageName.key(name)]) ?? false
        }
    }

    // MARK: - Tags (SPEC §8)

    public func allTags() throws -> [(tag: String, count: Int)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                // Most-used first so the sidebar's capped list keeps the
                // tags that matter; alphabetical breaks ties.
                sql: "SELECT tag, COUNT(*) AS n FROM tags GROUP BY tag ORDER BY n DESC, tag"
            ).map { ($0["tag"], $0["n"]) }
        }
    }

    /// All blocks carrying a tag, for the generated tag view.
    public func blocks(taggedWith tag: String) throws -> [BacklinkHit] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT b.id, b.page_key, b.content, p.display_name
                    FROM tags t
                    JOIN blocks b ON b.id = t.block_id
                    JOIN pages p ON p.name_key = b.page_key
                    WHERE t.tag = ?
                    """,
                arguments: [tag.lowercased()]
            )
            return rows.compactMap { row -> BacklinkHit? in
                guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                return BacklinkHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"]
                )
            }.sorted { ($0.pageDisplayName, $0.content) < ($1.pageDisplayName, $1.content) }
        }
    }

    // MARK: - Queries (§17)

    /// Runs a `{{query …}}` expression: returns the matching blocks (capped at
    /// `limit`, ordered by page) plus the full match count, so the UI can show
    /// "N of M". `excluding` drops the query's own host block from its results.
    public func runQuery(
        _ expr: QueryExpr, excluding excluded: UUID? = nil, limit: Int
    ) throws -> (hits: [BacklinkHit], total: Int) {
        let compiled = Self.compile(expr)
        var whereSQL = "(\(compiled.sql))"
        var whereArgs = compiled.args
        if let excluded {
            whereSQL += " AND b.id <> ?"
            whereArgs.append(excluded.uuidString.lowercased())
        }
        let pagePred = Self.compilePage(expr)
        return try dbQueue.read { db in
            // Block-level matches.
            let blockTotal = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM blocks b WHERE \(whereSQL)",
                arguments: StatementArguments(whereArgs)) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.id, b.page_key, b.content, p.display_name
                FROM blocks b
                JOIN pages p ON p.name_key = b.page_key
                WHERE \(whereSQL)
                -- Journal days newest-first (journal_date DESC puts non-journal
                -- pages, with NULL dates, last), then other pages alphabetically.
                ORDER BY p.journal_date DESC, p.display_name COLLATE NOCASE,
                         b.position, b.content
                LIMIT ?
                """, arguments: StatementArguments(whereArgs + [limit]))
            var hits = rows.compactMap { row -> BacklinkHit? in
                guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                return BacklinkHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"])
            }
            var seenPages = Set(hits.map(\.pageKey))

            // Page-level matches: pages that satisfy a pure page-property query
            // via their preamble properties. These surface the page itself — even
            // one with no blocks (the Logseq page-properties layout) — so a
            // `{{query type:: person}}` lists every person page. A page already
            // present as a block hit isn't repeated.
            var pageTotal = 0
            if let pagePred {
                let pageRows = try Row.fetchAll(db, sql: """
                    SELECT p.name_key, p.display_name
                    FROM pages p
                    WHERE (\(pagePred.sql)) AND p.file_exists = 1
                    ORDER BY p.journal_date DESC, p.display_name COLLATE NOCASE
                    """, arguments: StatementArguments(pagePred.args))
                for row in pageRows {
                    let key: String = row["name_key"]
                    guard !seenPages.contains(key) else { continue }
                    seenPages.insert(key)
                    pageTotal += 1
                    if hits.count < limit {
                        hits.append(BacklinkHit(
                            blockID: Self.pageHitBlockID,
                            pageKey: key,
                            pageDisplayName: row["display_name"],
                            content: ""))
                    }
                }
            }
            return (hits, blockTotal + pageTotal)
        }
    }

    /// Compiles a `QueryExpr` to a parameterized SQL predicate over block `b`.
    /// Every node maps to a known clause — no free-form SQL, no injection.
    private static func compile(_ expr: QueryExpr) -> (sql: String, args: [DatabaseValueConvertible]) {
        switch expr {
        case .and(let subs):
            guard !subs.isEmpty else { return ("1", []) }
            let parts = subs.map(compile)
            return ("(" + parts.map(\.sql).joined(separator: " AND ") + ")", parts.flatMap(\.args))
        case .or(let subs):
            guard !subs.isEmpty else { return ("0", []) }
            let parts = subs.map(compile)
            return ("(" + parts.map(\.sql).joined(separator: " OR ") + ")", parts.flatMap(\.args))
        case .not(let inner):
            let c = compile(inner)
            return ("(NOT \(c.sql))", c.args)
        case .tag(let tag):
            return ("EXISTS (SELECT 1 FROM tags x WHERE x.block_id = b.id AND x.tag = ?)",
                    [tag.lowercased()])
        case .pageRef(let name):
            return ("EXISTS (SELECT 1 FROM page_refs x WHERE x.block_id = b.id AND x.target_key = ?)",
                    [PageName.key(name)])
        case .task(let states):
            guard !states.isEmpty else { return ("0", []) }
            let marks = databaseQuestionMarks(count: states.count)
            // `IS NOT NULL` first so the clause is a true boolean (not SQL NULL)
            // for task-less blocks — otherwise `(not DONE)` would drop them.
            return ("(b.todo IS NOT NULL AND b.todo IN (\(marks)))", states.map { $0.rawValue })
        case .property(let key, let value):
            // A block's *own* property. Page properties (preamble `key:: value`,
            // which may belong to a page with no blocks at all) are matched
            // separately at the page level — see `compilePage` / `runQuery`.
            if let value {
                return ("EXISTS (SELECT 1 FROM props x WHERE x.block_id = b.id AND x.key = ? AND x.value = ?)",
                        [key, value])
            }
            return ("EXISTS (SELECT 1 FROM props x WHERE x.block_id = b.id AND x.key = ?)", [key])
        }
    }

    /// Sentinel block id for a *page-level* query hit — a page surfaced by a
    /// page-property match rather than a specific block. Such a hit carries empty
    /// content and renders as the page's name, so this id is never navigated to.
    static let pageHitBlockID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Compiles the *page-level* reading of a query: which pages match purely by
    /// their page properties (preamble `key:: value` lines). Returns nil unless
    /// the query is built solely from property terms (with `and`/`or`) — anything
    /// block-specific (tags, refs, tasks, `not`) can't be decided from page
    /// properties alone, so those queries yield block matches only.
    private static func compilePage(_ expr: QueryExpr) -> (sql: String, args: [DatabaseValueConvertible])? {
        switch expr {
        case .property(let key, let value):
            if let value {
                return ("EXISTS (SELECT 1 FROM page_props pp WHERE pp.page_key = p.name_key AND pp.key = ? AND pp.value = ?)",
                        [key, value])
            }
            return ("EXISTS (SELECT 1 FROM page_props pp WHERE pp.page_key = p.name_key AND pp.key = ?)", [key])
        case .and(let subs):
            let parts = subs.map(compilePage)
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            let ps = parts.compactMap { $0 }
            return ("(" + ps.map(\.sql).joined(separator: " AND ") + ")", ps.flatMap(\.args))
        case .or(let subs):
            let parts = subs.map(compilePage)
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            let ps = parts.compactMap { $0 }
            return ("(" + ps.map(\.sql).joined(separator: " OR ") + ")", ps.flatMap(\.args))
        case .not, .tag, .pageRef, .task:
            return nil
        }
    }

    /// Existing tags matching a prefix, for `#` autocomplete.
    public func tags(withPrefix prefix: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT tag FROM tags WHERE tag LIKE ? ESCAPE '\\' ORDER BY tag LIMIT 50",
                arguments: [likePrefix(prefix.lowercased())]
            )
        }
    }

    // MARK: - Block refs

    /// Where does this block live? For `((ref))` resolution and navigation.
    public func locateBlock(_ id: UUID) throws -> (pageKey: String, content: String)? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT page_key, content FROM blocks WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ).map { ($0["page_key"], $0["content"]) }
        }
    }

    /// The DFS-preorder position recorded for a block (its `position` column).
    /// Lets a block be relocated in a freshly-parsed page when its volatile id
    /// no longer matches the index (SPEC §7.1).
    public func position(ofBlock id: UUID) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT position FROM blocks WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    /// How many blocks reference each of the given block ids (SPEC §7.4).
    public func incomingRefCount(forBlockIDs ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try dbQueue.read { db in
            let marks = databaseQuestionMarks(count: ids.count)
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM block_refs WHERE target_id IN (\(marks))",
                arguments: StatementArguments(ids.map { $0.uuidString.lowercased() })
            ) ?? 0
        }
    }

    /// Full-text block search for `((` autocomplete and Cmd+K.
    public func searchBlocks(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return try searchBlocks(matching: ftsPrefixQuery(q), limit: limit)
    }

    /// Exact phrase search used by Ask's planned lexical queries. This remains
    /// separate from Cmd+K's token-prefix behavior.
    public func searchBlocks(exactPhrase phrase: String, limit: Int = 50) throws -> [SearchHit] {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        return try searchBlocks(matching: ftsPhrase(phrase), limit: limit, eligibleOnly: true)
    }

    /// Broad recall channel for Ask. The terms have already been selected by
    /// local query analysis; unlike the normal multiword FTS query, any one
    /// of them may match. Multiword values remain exact phrases.
    public func searchBlocks(anyOf terms: [String], limit: Int = 50) throws -> [SearchHit] {
        let query = ftsAnyQuery(terms)
        guard !query.isEmpty else { return [] }
        return try searchBlocks(matching: query, limit: limit, eligibleOnly: true)
    }

    private func searchBlocks(
        matching query: String, limit: Int, eligibleOnly: Bool = false
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let eligibility = eligibleOnly ? "AND (\(embeddingEligibleSQL(alias: "b")))" : ""
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.block_id, f.page_key, b.content, p.display_name
                    FROM blocks_fts f
                    JOIN blocks b ON b.id = f.block_id
                    JOIN pages p ON p.name_key = f.page_key
                    WHERE blocks_fts MATCH ?
                    \(eligibility)
                    ORDER BY rank LIMIT ?
                    """,
                arguments: [query, limit]
            ).compactMap { row in
                guard let uuid = UUID(uuidString: row["block_id"]) else { return nil }
                return SearchHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"]
                )
            }
        }
    }

    /// Direct structural context for an Ask evidence block. Each returned row
    /// keeps its own id so generated citations can point to the block that
    /// actually contains the supporting evidence sentence.
    public func contextBlocks(around blockID: UUID, childLimit: Int = 2) throws -> [SearchHit] {
        guard childLimit >= 0 else { return [] }
        return try dbQueue.read { db in
            guard let focus = try Row.fetchOne(db, sql: """
                SELECT b.parent_id, b.page_key, p.display_name
                FROM blocks b JOIN pages p ON p.name_key = b.page_key
                WHERE b.id = ?
                """, arguments: [blockID.uuidString.lowercased()]) else { return [] }
            let pageKey: String = focus["page_key"]
            let displayName: String = focus["display_name"]
            var rows: [Row] = []
            if let parentID: String = focus["parent_id"],
               let parent = try Row.fetchOne(db, sql: """
                   SELECT id, content FROM blocks WHERE id = ?
                   """, arguments: [parentID]) {
                rows.append(parent)
            }
            if childLimit > 0 {
                rows += try Row.fetchAll(db, sql: """
                    SELECT id, content FROM blocks
                    WHERE parent_id = ? ORDER BY position LIMIT ?
                    """, arguments: [blockID.uuidString.lowercased(), childLimit])
            }
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return SearchHit(
                    blockID: id, pageKey: pageKey,
                    pageDisplayName: displayName, content: row["content"])
            }
        }
    }

    // MARK: - On-device semantic index

    /// Missing or stale prose embeddings, in stable graph order. Fenced code,
    /// horizontal rules, empty blocks, and property-only blocks are excluded as
    /// retrieval noise. `modelID` invalidates vectors when Apple replaces the
    /// selected on-device embedding model.
    public func pendingEmbeddingInputs(
        modelID: String, limit: Int = 32
    ) throws -> [EmbeddingInput] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.id, b.content, b.content_hash
                FROM blocks b
                LEFT JOIN block_embeddings e ON e.block_id = b.id
                WHERE (\(embeddingEligibleSQL(alias: "b")))
                  AND (e.block_id IS NULL OR e.content_hash <> b.content_hash OR e.model_id <> ?)
                ORDER BY b.page_key, b.position
                LIMIT ?
                """, arguments: [modelID, limit]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    return EmbeddingInput(
                        blockID: id, content: row["content"], contentHash: row["content_hash"])
                }
        }
    }

    public func embeddingIndexStatus(modelID: String) throws -> EmbeddingIndexStatus {
        try dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM blocks b WHERE \(embeddingEligibleSQL(alias: "b"))
                """) ?? 0
            let completed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM blocks b JOIN block_embeddings e ON e.block_id = b.id
                WHERE (\(embeddingEligibleSQL(alias: "b")))
                  AND e.content_hash = b.content_hash AND e.model_id = ?
                """, arguments: [modelID]) ?? 0
            return EmbeddingIndexStatus(completed: completed, total: total)
        }
    }

    /// Tight page-sized query text for the Related surface. It uses the same
    /// prose filter as backfill and caps input before NaturalLanguage's own
    /// token truncation.
    public func embeddingText(forPageKey pageKey: String, characterLimit: Int = 4_000) throws -> String {
        guard characterLimit > 0 else { return "" }
        return try dbQueue.read { db in
            let contents = try String.fetchAll(db, sql: """
                SELECT b.content FROM blocks b
                WHERE b.page_key = ? AND (\(embeddingEligibleSQL(alias: "b")))
                ORDER BY b.position
                """, arguments: [pageKey])
            var result = ""
            for content in contents {
                let separator = result.isEmpty ? "" : "\n"
                let room = characterLimit - result.count - separator.count
                guard room > 0 else { break }
                result += separator + String(content.prefix(room))
            }
            return result
        }
    }

    /// Commits a vector only if the indexed block still has the content that
    /// was embedded. This closes the race with a save or external edit while a
    /// background embedding calculation is in flight.
    public func storeEmbedding(
        _ vector: [Float], for input: EmbeddingInput, modelID: String
    ) throws {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return }
        try writeEmbedding(
            vectorData(vector), dimension: vector.count, input: input, modelID: modelID)
    }

    /// Marks text the current system model could not represent. It is still
    /// retried after either the text or model revision changes, without making
    /// every background backfill spin forever on the same block.
    public func skipEmbedding(_ input: EmbeddingInput, modelID: String) throws {
        try writeEmbedding(Data(), dimension: 0, input: input, modelID: modelID)
    }

    private func writeEmbedding(
        _ data: Data, dimension: Int, input: EmbeddingInput, modelID: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO block_embeddings
                    (block_id, page_key, content_hash, model_id, dimension, vector)
                SELECT id, page_key, content_hash, ?, ?, ? FROM blocks
                WHERE id = ? AND content_hash = ?
                """, arguments: [
                    modelID, dimension, data,
                    input.blockID.uuidString.lowercased(), input.contentHash,
                ])
        }
    }

    /// Brute-force cosine kNN over a capped number of on-device vectors. Typical
    /// graphs are tens of thousands of blocks; revisit the 100k cap only if real
    /// graph sizes make a SQLite vector extension worthwhile.
    public func semanticSearch(
        vector query: [Float], modelID: String, limit: Int = 50,
        excludingPageKey: String? = nil, excludingBlockID: UUID? = nil,
        minimumScore: Float? = nil, performanceRequestID: String? = nil,
        performanceQueryIndex: Int? = nil
    ) throws -> [SemanticHit] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let totalStarted = CacheAIPerformanceLog.now()
        var initialFields = ["dimension=\(query.count)"]
        if let performanceQueryIndex {
            initialFields.append("query_index=\(performanceQueryIndex)")
        }
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.started",
            fields: initialFields)
        let sqliteStarted = CacheAIPerformanceLog.now()
        let rows = try dbQueue.read { db in
            var predicate = "e.model_id = ? AND e.dimension = ?"
            var args: [DatabaseValueConvertible] = [modelID, query.count]
            if let excludingPageKey {
                predicate += " AND b.page_key <> ?"
                args.append(excludingPageKey)
            }
            if let excludingBlockID {
                predicate += " AND b.id <> ?"
                args.append(excludingBlockID.uuidString.lowercased())
            }
            return try Row.fetchAll(db, sql: """
                SELECT b.id, b.page_key, b.content, p.display_name, e.vector
                FROM block_embeddings e
                JOIN blocks b ON b.id = e.block_id
                JOIN pages p ON p.name_key = b.page_key
                WHERE \(predicate)
                LIMIT 100000
                """, arguments: StatementArguments(args))
        }
        var commonFields = ["rows=\(rows.count)", "dimension=\(query.count)"]
        if let performanceQueryIndex {
            commonFields.append("query_index=\(performanceQueryIndex)")
        }
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.sqlite_complete",
            startedAt: sqliteStarted, fields: commonFields)
        let decodeStarted = CacheAIPerformanceLog.now()
        var hits: [(hit: SearchHit, vector: [Float])] = []
        hits.reserveCapacity(rows.count)
        var vectorBytes = 0
        for row in rows {
            let data: Data = row["vector"]
            vectorBytes += data.count
            guard let id = UUID(uuidString: row["id"]),
                  let vector = decodeVector(data), vector.count == query.count else { continue }
            hits.append((SearchHit(
                blockID: id, pageKey: row["page_key"],
                pageDisplayName: row["display_name"], content: row["content"]), vector))
        }
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.decode_complete",
            startedAt: decodeStarted,
            fields: commonFields + [
                "decoded=\(hits.count)", "vector_bytes=\(vectorBytes)",
            ])
        let rankStarted = CacheAIPerformanceLog.now()
        let ranked = SemanticRanker.nearest(
            to: query, among: hits.map { ($0.hit.blockID, $0.vector) }, limit: limit
        )
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.rank_complete",
            startedAt: rankStarted,
            fields: commonFields + ["ranked=\(ranked.count)"])
        let materializeStarted = CacheAIPerformanceLog.now()
        let hitsByID = Dictionary(
            hits.map { ($0.hit.blockID, $0.hit) },
            uniquingKeysWith: { first, _ in first })
        let result: [SemanticHit] = ranked.compactMap { ranked in
            guard minimumScore.map({ ranked.score >= $0 }) ?? true,
                  let hit = hitsByID[ranked.id] else { return nil }
            return SemanticHit(hit: hit, score: ranked.score)
        }
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.materialize_complete",
            startedAt: materializeStarted,
            fields: commonFields + ["results=\(result.count)"])
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "semantic.complete",
            startedAt: totalStarted,
            fields: commonFields + ["results=\(result.count)"])
        return result
    }

    /// Fuses one raw FTS query and one semantic query for Cmd+K. Ask uses the
    /// separately focused retrieval path below.
    public func retrieve(
        _ query: String, semanticVector: [Float]?, modelID: String?, limit: Int = 20
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let lexical = (try? searchBlocks(query, limit: max(50, limit * 4))) ?? []
        let semantic: [SemanticHit]
        if let semanticVector, let modelID {
            semantic = try semanticSearch(
                vector: semanticVector, modelID: modelID, limit: max(50, limit * 4))
        } else {
            semantic = []
        }
        let byID = Dictionary(
            (lexical + semantic.map(\.hit)).map { ($0.blockID, $0) },
            uniquingKeysWith: { first, _ in first })
        return SemanticRanker.fuse(
            lexical: lexical.map(\.blockID), semantic: semantic.map(\.hit.blockID), limit: limit
        ).compactMap { byID[$0] }
    }

    /// Ask-specific candidate generation from an already focused local query.
    /// There is intentionally no natural-language question parameter:
    /// conversational framing cannot accidentally leak back into retrieval.
    public func retrieveFocused(
        phrases: [String], lexicalTerms: [String], semanticVector: [Float]?,
        modelID: String?, limit: Int = 80, performanceRequestID: String? = nil
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let totalStarted = CacheAIPerformanceLog.now()
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "retrieval.focused_started",
            fields: [
                "phrases=\(phrases.count)",
                "terms=\(lexicalTerms.count)",
                "semantic_queries=\(semanticVector == nil ? 0 : 1)",
            ])
        var rankedLists: [(ids: [UUID], weight: Double)] = []
        var hitsByID: [UUID: SearchHit] = [:]
        func add(_ hits: [SearchHit], weight: Double) {
            guard !hits.isEmpty else { return }
            for hit in hits where hitsByID[hit.blockID] == nil { hitsByID[hit.blockID] = hit }
            rankedLists.append((ids: hits.map(\.blockID), weight: weight))
        }
        for (index, phrase) in phrases.enumerated() {
            let exactStarted = CacheAIPerformanceLog.now()
            let exact = try searchBlocks(exactPhrase: phrase, limit: 40)
            CacheAIPerformanceLog.emit(
                requestID: performanceRequestID, event: "retrieval.fts_exact",
                startedAt: exactStarted,
                fields: [
                    "query_index=\(index)", "query_utf8=\(phrase.utf8.count)",
                    "results=\(exact.count)",
                ])
            add(exact, weight: 1.8)
            let prefixStarted = CacheAIPerformanceLog.now()
            let prefix = try searchBlocks(
                matching: ftsPrefixQuery(phrase), limit: 40, eligibleOnly: true)
            CacheAIPerformanceLog.emit(
                requestID: performanceRequestID, event: "retrieval.fts_prefix",
                startedAt: prefixStarted,
                fields: [
                    "query_index=\(index)", "query_utf8=\(phrase.utf8.count)",
                    "results=\(prefix.count)",
                ])
            add(prefix, weight: 1.25)
        }
        let termsStarted = CacheAIPerformanceLog.now()
        let termHits = try searchBlocks(anyOf: lexicalTerms, limit: 60)
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "retrieval.fts_terms",
            startedAt: termsStarted,
            fields: ["terms=\(lexicalTerms.count)", "results=\(termHits.count)"])
        add(termHits, weight: 0.7)
        if let modelID, let semanticVector {
            add(try semanticSearch(
                vector: semanticVector, modelID: modelID, limit: 60, minimumScore: 0.15,
                performanceRequestID: performanceRequestID,
                performanceQueryIndex: 0)
                .map(\.hit), weight: 1.25)
        }
        let fusionStarted = CacheAIPerformanceLog.now()
        let fused = SemanticRanker.fuse(rankedLists: rankedLists, limit: limit)
            .compactMap { hitsByID[$0] }
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "retrieval.fusion_complete",
            startedAt: fusionStarted,
            fields: ["ranked_lists=\(rankedLists.count)", "results=\(fused.count)"])
        CacheAIPerformanceLog.emit(
            requestID: performanceRequestID, event: "retrieval.focused_complete",
            startedAt: totalStarted,
            fields: [
                "phrases=\(phrases.count)",
                "terms=\(lexicalTerms.count)",
                "semantic_queries=\(semanticVector == nil ? 0 : 1)",
                "results=\(fused.count)",
            ])
        return fused
    }

    // MARK: - Recents (SPEC §11.2)

    public func recordVisit(pageKey: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO recents (page_key, opened_at) VALUES (?, ?)",
                arguments: [pageKey, Date().timeIntervalSince1970]
            )
            // Keep only the most recent 20 distinct pages.
            try db.execute(sql: """
                DELETE FROM recents WHERE page_key NOT IN
                (SELECT page_key FROM recents ORDER BY opened_at DESC LIMIT 20)
                """)
        }
    }

    public func recentPageKeys() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT page_key FROM recents ORDER BY opened_at DESC LIMIT 20")
        }
    }

    public func clearRecents() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM recents")
        }
    }

    public func renameInRecents(oldKey: String, newKey: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE OR REPLACE recents SET page_key = ? WHERE page_key = ?",
                arguments: [newKey, oldKey]
            )
        }
    }

    // MARK: - Rename support

    /// Page keys of every page holding a `[[target]]` reference.
    public func pagesReferencing(pageKey: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT page_key FROM page_refs WHERE target_key = ?",
                arguments: [pageKey]
            )
        }
    }

    /// Page keys of every page using a tag.
    public func pagesUsingTag(_ tag: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT page_key FROM tags WHERE tag = ?",
                arguments: [tag.lowercased()]
            )
        }
    }
}

private func vectorData(_ vector: [Float]) -> Data {
    var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
    for value in vector {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func decodeVector(_ data: Data) -> [Float]? {
    let width = MemoryLayout<UInt32>.size
    guard !data.isEmpty, data.count.isMultiple(of: width) else { return nil }
    var vector = Array(repeating: Float.zero, count: data.count / width)
    _ = vector.withUnsafeMutableBytes { destination in
        data.copyBytes(to: destination)
    }
    #if _endian(big)
    for index in vector.indices {
        vector[index] = Float(bitPattern: vector[index].bitPattern.byteSwapped)
    }
    #endif
    return vector
}

// MARK: - FTS query helpers

/// Quotes user input as an FTS5 phrase with prefix matching on the last token.
func ftsPrefixQuery(_ input: String) -> String {
    let tokens = input
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
    guard !tokens.isEmpty else { return "\"\"" }
    var quoted = tokens.map { "\"\($0)\"" }
    quoted[quoted.count - 1] += "*"
    return quoted.joined(separator: " ")
}

/// Quotes a page name as an exact FTS5 phrase.
func ftsPhrase(_ input: String) -> String {
    "\"" + input.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// OR query over locally selected terms. Values are quoted as phrases so
/// punctuation is data rather than FTS syntax; duplicates are removed without
/// disturbing the analyzer's priority order.
func ftsAnyQuery(_ inputs: [String]) -> String {
    var seen = Set<String>()
    var phrases: [String] = []
    for input in inputs {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else { continue }
        phrases.append(ftsPhrase(trimmed))
    }
    return phrases.joined(separator: " OR ")
}

func likePrefix(_ input: String) -> String {
    let escaped = input
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return escaped + "%"
}
