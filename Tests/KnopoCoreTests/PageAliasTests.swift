import Foundation
import GRDB
import Testing
@testable import KnopoCore

@Suite struct PageAliasTests {
    private func page(_ name: String, _ text: String) -> PageDocument {
        let parsed = PageParser.parse(text)
        return PageDocument(name: name, blocks: parsed.blocks, preamble: parsed.preamble,
                            fileExists: true)
    }

    @Test func parsesPageAliasesWithoutChangingSource() {
        let text = "alias:: AI, [[Machine Intelligence]], [[Doe, Jane]], ai, , Bad#Name, 2026-11-06\r\n"
            + "- alias:: First, Artificial Intelligence\r\n- alias:: Not a page alias\r\n"
        let doc = page("Artificial Intelligence", text)
        expectEqual(doc.aliases, ["AI", "Machine Intelligence", "Doe, Jane", "First"])
        expectEqual(PageSerializer.serialize(preamble: doc.preamble, blocks: doc.blocks), text)
    }

    @Test func resolvesReferencesRegardlessOfIndexOrder() throws {
        let cache = try CacheDB()
        let source = page("Notes", "- [[AI]] and [[Artificial Intelligence]]\n- {{embed [[ai]]}}\n"
                          + "- #[[AI]]\n- `[[AI]]`\n")
        try cache.indexPage(source, stamp: nil)
        expectTrue(try cache.stubPageNames().contains("AI"))
        try cache.indexPage(page("Artificial Intelligence", "alias:: AI\n- [[AI]]\n"), stamp: nil)
        expectEqual(try cache.canonicalPageKey(for: "aI"), "artificial intelligence")
        expectTrue(try cache.stubPageNames().isEmpty)
        expectEqual(try cache.backlinks(of: "AI").map(\.blockID), Array(source.blocks.prefix(2)).map(\.id))
        expectEqual(try cache.backlinks(of: "artificial intelligence").count, 2)
        for name in ["AI", "Artificial Intelligence"] {
            let result = try cache.runQuery(.pageRef(name), limit: 50)
            expectEqual(result.total, 3) // Queries include the owning page's self-reference.
        }
        expectEqual(try cache.blocks(taggedWith: "ai").count, 1)
        expectEqual(try cache.aliasListings().map(\.displayName), ["AI"])
        expectEqual(try cache.aliasListings().map(\.nameKey), ["artificial intelligence"])
    }

    @Test func bracketedAliasesRequireCommaSeparators() {
        let doc = page("Owner", "alias:: [[Machine Intelligence]] extra, Valid, [[AI]]suffix, [[Doe, Jane]] , Last\n")
        expectEqual(doc.aliases, ["Valid", "Doe, Jane", "Last"])
        expectEqual(page("Owner", "alias:: [[AI]]   \n").aliases, ["AI"])
        expectTrue(page("Owner", "alias:: [[AI]] [[Other]]\n").aliases.isEmpty)
    }

    @Test func inlineAliasEditsPreservePageTagsTitleAndFencedExamples() throws {
        let cache = try CacheDB()
        let source = "title:: Display title\r\ntags:: work\r\nalias:: Before\r\n"
            + "```\r\nalias:: Example\r\n```\r\n- body\r\n  title:: Legacy title\r\n"
        var owner = page("Owner", source)
        try cache.indexPage(owner, stamp: nil)
        expectEqual(owner.aliases, ["Before"])
        expectEqual(owner.displayTitle(using: .default), "Display title")

        expectTrue(owner.setPreambleProperty(at: 2, to: BlockProperty(key: "alias", value: "After")))
        try cache.indexPage(owner, stamp: nil)
        expectEqual(try cache.canonicalPageKey(for: "Before"), "before")
        expectEqual(try cache.canonicalPageKey(for: "After"), "owner")
        expectEqual(try cache.canonicalPageKey(for: "Example"), "example")
        expectEqual(try cache.pages(taggedWith: "work").map(\.pageDisplayName), ["Owner"])
        expectEqual(PageSerializer.serialize(preamble: owner.preamble, blocks: owner.blocks),
                    source.replacingOccurrences(of: "alias:: Before", with: "alias:: After"))

        expectTrue(owner.setPreambleProperty(at: 2, to: nil))
        try cache.indexPage(owner, stamp: nil)
        expectTrue(try cache.aliasListings().isEmpty)
        expectEqual(try cache.pages(taggedWith: "work").count, 1)
        try cache.clearAll()
        expectTrue(try cache.pages(taggedWith: "work").isEmpty)
    }

    @Test func incrementalAliasEditsUpdateExistingReferences() throws {
        let cache = try CacheDB()
        var owner = page("Owner", "alias:: Before\n- alias:: First\n- normal\n")
        try cache.indexPage(owner, stamp: nil)
        try cache.indexPage(page("Notes", "- [[Before]]\n- [[After]]\n- [[First]]\n- [[Second]]\n"), stamp: nil)
        owner.preamble = "alias:: After\n"
        owner.blocks[0].properties = [BlockProperty(key: "alias", value: "Second")]
        try cache.indexPage(owner, stamp: nil)
        expectEqual(cache.indexStats.incremental, 1)
        expectEqual(try cache.canonicalPageKey(for: "Before"), "before")
        expectEqual(try cache.canonicalPageKey(for: "First"), "first")
        expectEqual(try cache.backlinks(of: "owner").map(\.content), ["[[After]]", "[[Second]]"])
        expectEqual(Set(try cache.stubPageNames()), ["Before", "First"])
        owner.preamble = ""
        owner.blocks.removeFirst()
        try cache.indexPage(owner, stamp: nil)
        expectTrue(try cache.aliasListings().isEmpty)
        expectTrue(try cache.backlinks(of: "owner").isEmpty)
    }

    @Test func collisionsAreDeterministicAndRecoverWhenRemoved() throws {
        let cache = try CacheDB()
        try cache.indexPage(page("One", "alias:: Shared, Two\n"), stamp: nil)
        try cache.indexPage(page("Two", "alias:: Shared, One\n"), stamp: nil)
        expectEqual(try cache.canonicalPageKey(for: "Shared"), "shared")
        expectEqual(try cache.canonicalPageKey(for: "One"), "one")
        expectEqual(try cache.canonicalPageKey(for: "Two"), "two")
        expectTrue(try cache.aliasListings().isEmpty)
        try cache.removePage(key: "two")
        expectEqual(try cache.canonicalPageKey(for: "Shared"), "one")
        try cache.indexPage(page("Shared", "- real page\n"), stamp: nil)
        expectEqual(try cache.canonicalPageKey(for: "Shared"), "shared")
        try cache.removePage(key: "shared")
        expectEqual(try cache.canonicalPageKey(for: "Shared"), "one")
        try cache.clearAll()
        expectTrue(try cache.aliasListings().isEmpty)
    }

    @Test func graphLoadsAndSavesOneDocumentThroughEitherName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        _ = store.page(named: "AI") // An earlier empty stub must not hide a new alias.
        var owner = page("Artificial Intelligence", "alias:: AI\n- original\n")
        store.updatePage(owner)
        try store.savePage(named: owner.name)
        owner = store.page(named: "AI")
        expectEqual(owner.name, "Artificial Intelligence")
        owner.blocks[0].content = "edited through alias"
        store.updatePage(owner)
        try store.savePage(named: "AI")
        expectEqual(store.page(named: "Artificial Intelligence").blocks[0].content, "edited through alias")
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL(forPageNamed: "AI").path))
        #expect(throws: GraphError.self) { try store.createPage(named: "ai") }
        var source = page("Notes", "- [[AI]] and [[Artificial Intelligence]]\n")
        store.updatePage(source)
        try store.savePage(named: source.name)
        #expect(throws: GraphError.self) { try store.renamePage(from: "Notes", to: "AI") }
        try store.renamePage(from: "AI", to: "Intelligence")
        expectEqual(store.page(named: "AI").name, "Intelligence")
        source = store.page(named: "Notes")
        expectEqual(source.blocks[0].content, "[[AI]] and [[Intelligence]]")
        let reopened = try GraphStore(root: root)
        expectEqual(reopened.page(named: "ai").name, "Intelligence")
        expectEqual(try reopened.cache.backlinks(of: "intelligence").count, 1)
    }

    @Test(arguments: [false, true])
    func editedStubOnlyShadowsAnAliasWhileItHasContent(keepContent: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-dirty-stub-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var stub = store.page(named: "AI")
        stub.blocks[0].content = "unsaved content"
        store.updatePage(stub)
        if !keepContent {
            stub.blocks[0].content = ""
            store.updatePage(stub)
            try store.savePage(named: "AI")
        }
        store.updatePage(page("Owner", "alias:: AI\n- owner content\n"))
        try store.savePage(named: "Owner")
        expectEqual(store.canonicalPageName(for: "AI"), keepContent ? "AI" : "Owner")
        expectEqual(store.page(named: "AI").blocks[0].content,
                    keepContent ? "unsaved content" : "owner content")
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL(forPageNamed: "AI").path))
    }

    @Test func migrationBackfillsAliasesWithoutReindexingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.db")
        do {
            let cache = try CacheDB(url: url)
            try cache.indexPage(page("Owner", "alias:: Preamble\n- alias:: First\n- alias:: Later\n"), stamp: nil)
        }
        do {
            let db = try DatabaseQueue(path: url.path)
            try db.write { db in
                try db.execute(sql: "DROP VIEW effective_page_aliases")
                try db.execute(sql: "DROP TABLE page_aliases")
                try db.execute(sql: """
                    DELETE FROM grdb_migrations
                    WHERE identifier = 'v8-page-aliases'
                    """)
            }
        }
        let upgraded = try CacheDB(url: url)
        expectEqual(try upgraded.canonicalPageKey(for: "Preamble"), "owner")
        expectEqual(try upgraded.canonicalPageKey(for: "First"), "owner")
        expectEqual(try upgraded.canonicalPageKey(for: "Later"), "later")
        expectEqual(upgraded.indexStats.full, 0)
    }

    @Test func ownAliasCanBecomeThePageName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-rename-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        store.updatePage(page("Artificial Intelligence", "alias:: AI, Machine Intelligence\n- body\n"))
        try store.savePage(named: "Artificial Intelligence")
        store.updatePage(page("Notes", "- [[AI]] and [[Artificial Intelligence]]\n"))
        try store.savePage(named: "Notes")
        try store.renamePage(from: "Artificial Intelligence", to: "AI")
        expectEqual(store.page(named: "Machine Intelligence").name, "AI")
        expectEqual(store.page(named: "AI").aliases, ["Machine Intelligence"])
        expectEqual(store.page(named: "Notes").blocks[0].content, "[[AI]] and [[AI]]")
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL(forPageNamed: "Artificial Intelligence").path))
    }

    @Test func renamingThroughAnAliasToTheCurrentNameWritesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-noop-rename-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        store.updatePage(page("Owner", "alias:: AI\n- body\n"))
        try store.savePage(named: "Owner")
        store.updatePage(page("Notes", "- [[owner]] and [[ Owner ]]\n"))
        try store.savePage(named: "Notes")
        let url = store.fileURL(forPageNamed: "Notes")
        let before = try Data(contentsOf: url)
        let stats = store.cache.indexStats
        expectTrue(try store.renamePage(from: "AI", to: "Owner").isEmpty)
        expectEqual(try Data(contentsOf: url), before)
        expectEqual(store.cache.indexStats, stats)
    }

    @Test func pageExistenceUsesIdentityRatherThanFuzzyDisplayMatches() throws {
        let cache = try CacheDB()
        try cache.indexPage(page("2026_06_10", "- journal\n"), stamp: nil)
        try cache.indexPage(page("Owner", "alias:: AI\n- [[Ghost Page]]\n"), stamp: nil)
        expectTrue(try cache.hasPage(named: "2026-06-10"))
        expectTrue(try cache.hasPage(named: "Jun 10th, 2026"))
        expectTrue(try cache.hasPage(named: "aI"))
        expectTrue(try cache.hasPage(named: "ghost page"))
        expectFalse(try cache.hasPage(named: "Missing"))
    }
}
