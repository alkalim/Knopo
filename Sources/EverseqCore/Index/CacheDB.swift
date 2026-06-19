import Foundation
import GRDB

/// One row of backlink lookup: a block somewhere in the graph that references
/// the page in question (SPEC §9.1).
public struct BacklinkHit: Equatable, Sendable {
    public var blockID: UUID
    public var pageKey: String
    public var pageDisplayName: String
    public var content: String
    /// Contents of ancestor blocks, outermost first (breadcrumb).
    public var breadcrumb: [String]
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

/// The rebuildable index in `.everseq/cache.db` (SPEC §4.1, §9.3, §17).
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
    public static let indexVersion: Int = 3

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
                    let bid = block.id.uuidString.lowercased()
                    try db.execute(
                        sql: """
                            INSERT INTO blocks
                            (id, page_key, parent_id, position, depth, content, todo, collapsed)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            bid, key, parent?.uuidString.lowercased(), position,
                            depth, block.content, block.todoState?.rawValue,
                            block.collapsed,
                        ]
                    )
                    position += 1
                    try db.execute(
                        sql: "INSERT INTO blocks_fts (content, block_id, page_key) VALUES (?, ?, ?)",
                        arguments: [block.content, bid, key]
                    )
                    let refs = RefExtractor.extract(from: block.content)
                    for target in refs.pageRefs {
                        try db.execute(
                            sql: "INSERT INTO page_refs (block_id, page_key, target_key) VALUES (?, ?, ?)",
                            arguments: [bid, key, PageName.key(target)]
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
                    try walk(block.children, parent: block.id, depth: depth + 1)
                }
            }
            try walk(page.blocks, parent: nil, depth: 0)
        }
    }

    public func removePage(key: String) throws {
        try dbQueue.write { db in
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

    public func clearAll() throws {
        try dbQueue.write { db in
            for table in ["pages", "blocks", "blocks_fts", "page_refs", "block_refs", "tags", "props"] {
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
    /// every keystroke. A single aggregate, far cheaper than `journalPages()`.
    public func journalDaySignature() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT b.page_key)
                FROM blocks b JOIN pages p ON p.name_key = b.page_key
                WHERE p.is_journal = 1 AND p.journal_date IS NOT NULL
                """) ?? 0
        }
    }

    /// Page names referenced somewhere but with no file — stubs (SPEC §3.2).
    /// Returns display-cased names as first encountered in a reference.
    public func stubPageKeys() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT target_key FROM page_refs
                WHERE target_key NOT IN (SELECT name_key FROM pages)
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
                    content: row["content"],
                    breadcrumb: try Self.breadcrumb(db, blockID: idString)
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
            return try rows.compactMap { row -> BacklinkHit? in
                guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                return BacklinkHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"],
                    breadcrumb: try Self.breadcrumb(db, blockID: row["id"])
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
        return try dbQueue.read { db in
            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM blocks b WHERE \(whereSQL)",
                arguments: StatementArguments(whereArgs)) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.id, b.page_key, b.content, p.display_name
                FROM blocks b
                JOIN pages p ON p.name_key = b.page_key
                WHERE \(whereSQL)
                ORDER BY p.display_name, b.position, b.content
                LIMIT ?
                """, arguments: StatementArguments(whereArgs + [limit]))
            let hits = try rows.compactMap { row -> BacklinkHit? in
                guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                return BacklinkHit(
                    blockID: uuid,
                    pageKey: row["page_key"],
                    pageDisplayName: row["display_name"],
                    content: row["content"],
                    breadcrumb: try Self.breadcrumb(db, blockID: row["id"]))
            }
            return (hits, total)
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
            if let value {
                return ("EXISTS (SELECT 1 FROM props x WHERE x.block_id = b.id AND x.key = ? AND x.value = ?)",
                        [key, value])
            }
            return ("EXISTS (SELECT 1 FROM props x WHERE x.block_id = b.id AND x.key = ?)", [key])
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
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.block_id, f.page_key, b.content, p.display_name
                    FROM blocks_fts f
                    JOIN blocks b ON b.id = f.block_id
                    JOIN pages p ON p.name_key = f.page_key
                    WHERE blocks_fts MATCH ?
                    ORDER BY rank LIMIT ?
                    """,
                arguments: [ftsPrefixQuery(q), limit]
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

func likePrefix(_ input: String) -> String {
    let escaped = input
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return escaped + "%"
}
