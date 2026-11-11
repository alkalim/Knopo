import Foundation
import GRDB
import Testing
@testable import KnopoCore

@Suite struct PageTagTests {
    @Test func parsesLogseqSpellingsAndRenamesOnlyMatchingNames() {
        let source = "Work, [[Multi Word]], #urgent #[[Other Tag]], work"
        expectEqual(PageTagValue.tokens(in: source).map(\.name),
                    ["work", "multi word", "urgent", "other tag", "work"])
        expectEqual(PageTagValue.rename("work", to: "office", in: source),
                    "office, [[Multi Word]], #urgent #[[Other Tag]], office")
        expectEqual(PageTagValue.rename("urgent", to: "very urgent", in: source),
                    "Work, [[Multi Word]], #[[very urgent]] #[[Other Tag]], work")
        expectEqual(PageTagValue.rename("multi word", to: "new name", in: "[[  Multi Word  ]], keep"),
                    "[[  new name  ]], keep")
    }

    @Test func pageTagsStayPageScopedAcrossEditsRenameAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-page-tags-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let source = "tags:: Work, [[Multi Word]], work\r\nstatus:: open\r\n# Heading\r\n- body #work\r\n"
        let parsed = PageParser.parse(source)
        var doc = PageDocument(name: "Tagged", blocks: parsed.blocks, preamble: parsed.preamble)
        store.updatePage(doc)
        try store.savePage(named: doc.name)
        expectEqual(try store.cache.tags(withPrefix: "multi"), ["multi word"])
        expectEqual(try store.cache.pages(taggedWith: "WORK").map(\.pageDisplayName), ["Tagged"])
        expectEqual(try store.cache.blocks(taggedWith: "work").count, 1)
        expectEqual(try store.cache.allTags().first?.count, 2)
        expectEqual(try String(contentsOf: store.fileURL(forPageNamed: doc.name), encoding: .utf8), source)
        try store.renameTag(from: "work", to: "office")
        expectEqual(try store.cache.pagesUsingTag("work"), [])
        expectEqual(try store.cache.pages(taggedWith: "office").count, 1)
        expectEqual(try store.cache.blocks(taggedWith: "office").count, 1)
        let renamed = try String(contentsOf: store.fileURL(forPageNamed: doc.name), encoding: .utf8)
        expectTrue(renamed.hasPrefix("tags:: office, [[Multi Word]], office\r\nstatus:: open\r\n# Heading\r\n"))
        doc = store.page(named: doc.name)
        doc.setPreambleProperty(at: 0, to: nil)
        store.updatePage(doc)
        try store.savePage(named: doc.name)
        expectEqual(try store.cache.pages(taggedWith: "office").count, 0)
        expectEqual(try store.cache.tags(withPrefix: "multi"), [])
        try store.cache.removePage(key: doc.nameKey)
        expectTrue(try store.cache.allTags().isEmpty)
    }

    @Test func propertiesOnlyPageAndFencedExample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-tags-only-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CacheDB(url: root.appendingPathComponent("cache.db"))
        let page = PageDocument(name: "Only", preamble: "tags:: lone\n```\ntags:: example\n```\n", fileExists: true)
        try cache.indexPage(page, stamp: nil)
        expectEqual(try cache.pages(taggedWith: "lone").count, 1)
        expectEqual(try cache.blocks(taggedWith: "lone").count, 0)
        expectEqual(try cache.tags(withPrefix: "example"), [])
        expectEqual(try cache.runQuery(.tag("lone"), limit: 20).total, 1)
    }

    @Test func migrationBackfillsExistingPageProperties() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-tags-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.db")
        do {
            let cache = try CacheDB(url: url)
            try cache.indexPage(PageDocument(name: "Old", preamble: "tags:: Work, work, [[Team A]]\n", fileExists: true), stamp: nil)
        }
        do {
            let db = try DatabaseQueue(path: url.path)
            try db.write {
                try $0.execute(sql: "DROP TABLE page_tags")
                try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8-page-tags'")
            }
        }
        let upgraded = try CacheDB(url: url)
        expectEqual(try upgraded.pages(taggedWith: "work").map(\.pageDisplayName), ["Old"])
        expectEqual(try upgraded.allTags().map(\.tag), ["team a", "work"])
        expectEqual(try upgraded.allTags().map(\.count), [1, 1])
    }
}
