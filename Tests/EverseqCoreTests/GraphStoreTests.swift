import Testing
import Foundation
@testable import EverseqCore

@Suite struct GraphStoreTests {

    private func makeGraph(_ files: [String: String], journals: [String: String] = [:]) throws -> GraphStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("everseq-test-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("journals"), withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(
                to: root.appendingPathComponent("pages/\(PageName.fileName(for: name))")
            )
        }
        for (name, text) in journals {
            try Data(text.utf8).write(
                to: root.appendingPathComponent("journals/\(PageName.fileName(for: name))")
            )
        }
        return try GraphStore(root: root)
    }

    @Test func indexAndBacklinks() throws {
        let store = try makeGraph([
            "Project X": "- the project\n- TODO ship it #urgent\n",
            "Notes": "- thinking about [[Project X]] today\n  - nested detail\n- unrelated\n",
        ])
        let backlinks = try store.cache.backlinks(of: "project x")
        expectEqual(backlinks.count, 1)
        expectEqual(backlinks.first?.pageDisplayName, "Notes")
        expectEqual(backlinks.first?.content, "thinking about [[Project X]] today")
        expectEqual(backlinks.first?.breadcrumb, [])
    }

    @Test func blockRefCountsAsPageBacklink() throws {
        // A ((ref)) to block B counts as a linked reference to B's page (§7.5).
        let id = "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f"
        let store = try makeGraph([
            "Source": "- referenced block\n  id:: \(id)\n",
            "Quoter": "- see ((\(id)))\n",
        ])
        let backlinks = try store.cache.backlinks(of: "source")
        expectEqual(backlinks.count, 1)
        expectEqual(backlinks.first?.pageDisplayName, "Quoter")
    }

    @Test func selfReferencesExcluded() throws {
        let store = try makeGraph(["Self": "- I link to [[Self]]\n"])
        expectEqual(try store.cache.backlinks(of: "self").count, 0)
    }

    @Test func tagsIndexedNotBacklinked() throws {
        let store = try makeGraph([
            "A": "- #urgent things and #[[Multi Word]] stuff\n",
            "urgent": "- a page that shares a tag's name\n",
        ])
        // Tag occurrences never appear in linked references (§8.2).
        expectEqual(try store.cache.backlinks(of: "urgent").count, 0)
        let tags = try store.cache.allTags()
        expectEqual(tags.map(\.tag).sorted(), ["multi word", "urgent"])
        let tagged = try store.cache.blocks(taggedWith: "Urgent")
        expectEqual(tagged.count, 1)
        expectEqual(tagged.first?.pageDisplayName, "A")
    }

    @Test func stubPages() throws {
        let store = try makeGraph(["A": "- mentions [[Ghost Page]]\n"])
        expectEqual(try store.cache.stubPageKeys(), ["ghost page"])
        let stub = store.page(named: "Ghost Page")
        expectFalse(stub.fileExists)
        // Saving an empty stub creates no file (lazy creation).
        try store.savePage(named: "Ghost Page")
        expectFalse(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "Ghost Page").path))
        // Adding content materializes the file.
        var doc = store.page(named: "Ghost Page")
        doc.blocks = [Block(content: "now real")]
        store.updatePage(doc)
        try store.savePage(named: "Ghost Page")
        expectTrue(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "Ghost Page").path))
    }

    @Test func renamePageRewritesRefs() throws {
        let store = try makeGraph([
            "Old Name": "- content\n",
            "Refers": "- see [[old name]] and [[Old Name]]\n- tag form #[[Old Name]] stays\n",
        ])
        try store.renamePage(from: "Old Name", to: "New Name")
        let refers = store.page(named: "Refers")
        expectEqual(refers.blocks[0].content, "see [[New Name]] and [[New Name]]")
        // The #[[...]] tag is a tag, not a page ref — untouched (§8).
        expectEqual(refers.blocks[1].content, "tag form #[[Old Name]] stays")
        expectFalse(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "Old Name").path))
        expectTrue(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "New Name").path))
        expectEqual(try store.cache.backlinks(of: "new name").count, 1)
    }

    @Test func renameLoadedPageKeepsBlocks() throws {
        // Reproduces the live-editing case: the page is loaded in memory, so its
        // blocks keep the same ids the index holds. Re-indexing under the new
        // key must not collide on the globally-unique block id (it used to throw
        // "UNIQUE constraint failed: blocks.id" and drop the page to a stub).
        let store = try makeGraph([:])
        _ = try store.createPage(named: "Test Page")
        var doc = store.page(named: "Test Page")
        doc.blocks[0].content = "New block"
        store.updatePage(doc)
        try store.savePage(named: "Test Page") // loaded ids == indexed ids

        try store.renamePage(from: "Test Page", to: "Renamed Page")

        let renamed = store.page(named: "Renamed Page")
        expectEqual(renamed.blocks.map(\.content), ["New block"])
        expectTrue(renamed.fileExists)
        expectTrue(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "Renamed Page").path))
        expectFalse(FileManager.default.fileExists(
            atPath: store.fileURL(forPageNamed: "Test Page").path))
        // The block is indexed under the new page and reachable.
        let hit = try store.cache.searchBlocks("New block").first
        expectEqual(hit?.pageDisplayName, "Renamed Page")
    }

    @Test func renameFollowsFavourites() throws {
        let store = try makeGraph(["Fav": "- x\n"])
        try store.updateConfig { $0.toggleFavourite("Fav") }
        try store.renamePage(from: "Fav", to: "Fav2")
        expectEqual(store.config.favourites, ["Fav2"])
    }

    @Test func renameTag() throws {
        let store = try makeGraph([
            "A": "- has #wip marker\n- bracket #[[wip]] too\n- but #wip-extra differs\n",
        ])
        try store.renameTag(from: "wip", to: "in-progress")
        let a = store.page(named: "A")
        expectEqual(a.blocks[0].content, "has #in-progress marker")
        expectEqual(a.blocks[1].content, "bracket #in-progress too")
        expectEqual(a.blocks[2].content, "but #wip-extra differs")
    }

    @Test func deletePageRemovesIndexAndFavourite() throws {
        let store = try makeGraph(["Doomed": "- bye\n", "Other": "- [[Doomed]]\n"])
        try store.updateConfig { $0.toggleFavourite("Doomed") }
        try store.deletePage(named: "Doomed")
        expectNil(try store.cache.page(key: "doomed"))
        expectEqual(store.config.favourites, [])
        // Now a stub again (still referenced from Other).
        expectEqual(try store.cache.stubPageKeys(), ["doomed"])
    }

    @Test func searchBlocks() throws {
        let store = try makeGraph([
            "Alpha": "- the quick brown fox\n",
            "Beta": "- quicksilver thoughts\n",
        ])
        let hits = try store.cache.searchBlocks("quick")
        expectEqual(hits.count, 2) // prefix match covers both
        let exact = try store.cache.searchBlocks("quick brown")
        expectEqual(exact.count, 1)
        expectEqual(exact.first?.pageDisplayName, "Alpha")
    }

    @Test func unlinkedReferences() throws {
        let store = try makeGraph([
            "Project X": "- self\n",
            "Mentions": "- talked about project x in standup\n- already linked [[Project X]]\n",
        ])
        let unlinked = try store.cache.unlinkedReferences(toPageNamed: "Project X")
        expectEqual(unlinked.count, 1)
        expectEqual(unlinked.first?.content, "talked about project x in standup")
    }

    @Test func recents() throws {
        let store = try makeGraph(["A": "- a\n", "B": "- b\n"])
        try store.cache.recordVisit(pageKey: "a")
        try store.cache.recordVisit(pageKey: "b")
        try store.cache.recordVisit(pageKey: "a")
        expectEqual(try store.cache.recentPageKeys(), ["a", "b"])
        try store.cache.clearRecents()
        expectEqual(try store.cache.recentPageKeys(), [])
    }

    @Test func externalChangeReloadsAndConflicts() throws {
        let store = try makeGraph(["Shared": "- original\n"])
        // Dirty in-memory edit.
        var doc = store.page(named: "Shared")
        doc.blocks[0].content = "my unsaved edit"
        store.updatePage(doc)
        // External writer changes the file (different mtime/size).
        let url = store.fileURL(forPageNamed: "Shared")
        try Data("- external edit wins\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let affected = try store.handleExternalChanges()
        expectEqual(affected, ["shared"])
        expectEqual(store.page(named: "Shared").blocks[0].content, "external edit wins")
        // Losing version saved to conflicts.
        let conflicts = (try? FileManager.default.contentsOfDirectory(
            at: store.conflictsDir, includingPropertiesForKeys: nil)) ?? []
        expectEqual(conflicts.count, 1)
        let saved = try String(contentsOf: conflicts[0], encoding: .utf8)
        expectTrue(saved.contains("my unsaved edit"))
    }

    @Test func incomingRefCount() throws {
        let id = "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f"
        let store = try makeGraph([
            "Source": "- target\n  id:: \(id)\n",
            "R1": "- ((\(id)))\n",
            "R2": "- also ((\(id))) and again ((\(id)))\n",
        ])
        expectEqual(try store.cache.incomingRefCount(forBlockIDs: [UUID(uuidString: id)!]), 3)
    }

    @Test func journalIndexing() throws {
        let store = try makeGraph([:], journals: [
            "2026-06-10": "- yesterday's note linking [[2026-06-11]]\n",
            "2026-06-11": "- today\n",
        ])
        let journals = try store.cache.journalPages()
        expectEqual(journals.map(\.nameKey), ["2026-06-11", "2026-06-10"])
        expectEqual(try store.cache.backlinks(of: "2026-06-11").count, 1)
        expectEqual(store.page(named: "2026-06-10").displayTitle, "Jun 10th, 2026")
    }

    @Test func isoReferenceResolvesToUnderscoreJournal() throws {
        // A Logseq-style underscore journal, referenced by ISO from a page.
        let store = try makeGraph(
            ["Note": "- see [[2026-06-10]] for context\n"],
            journals: ["2026_06_10": "- the imported day\n"]
        )
        // The date key is canonical, so the ISO reference and the underscore
        // file are one identity: the journal has a backlink from Note.
        // Both spellings normalize to the same canonical key (callers always
        // pass PageName.key), so backlinks resolve regardless of how the day
        // was spelled in the reference or the filename.
        expectEqual(try store.cache.backlinks(of: PageName.key("2026-06-10")).count, 1)
        expectEqual(try store.cache.backlinks(of: PageName.key("2026_06_10")).count, 1)
        // Navigating the ISO reference loads the real underscore file, not a stub.
        let day = store.page(named: "2026-06-10")
        expectTrue(day.fileExists)
        expectEqual(day.blocks.first?.content, "the imported day")
        expectEqual(day.displayTitle, "Jun 10th, 2026")
        // No stub created for the ISO spelling.
        expectEqual(try store.cache.stubPageKeys(), [])
    }

    @Test func dateKeysCanonicalize() {
        expectEqual(PageName.key("2026_06_10"), "2026-06-10")
        expectEqual(PageName.key("2026-06-10"), "2026-06-10")
        expectEqual(PageName.key("Project X"), "project x") // non-dates unchanged
    }

    @Test func persistBlockIDWritesIdProperty() throws {
        let store = try makeGraph(["P": "- target block\n"])
        let doc = store.page(named: "P")
        let blockID = doc.blocks[0].id
        try store.persistBlockID(blockID, inPageNamed: "P")
        let text = try String(contentsOf: store.fileURL(forPageNamed: "P"), encoding: .utf8)
        expectEqual(text, "- target block\n  id:: \(blockID.uuidString.lowercased())\n")
    }

    @Test func incrementalSyncSkipsUnchangedFiles() throws {
        let store = try makeGraph(["A": "- a\n"])
        // Second sync with same stamps re-touches nothing (no error = pass);
        // force rebuild re-creates the index from files.
        try store.synchronizeIndex()
        try store.synchronizeIndex(force: true)
        expectEqual(try store.cache.allPages().count, 1)
        expectEqual(try store.cache.allPages().first?.displayName, "A")
    }
}
