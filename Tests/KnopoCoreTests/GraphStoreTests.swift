import Testing
import Foundation
@testable import KnopoCore

@Suite struct GraphStoreTests {

    /// A conflict copy's filename must carry the Gregorian year whatever the
    /// region's calendar is - a Buddhist calendar would write 2569 (phase 2c).
    @Test func conflictFilenameStampIsGregorianAndASCII() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 10
        comps.hour = 14; comps.minute = 30; comps.second = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let date = cal.date(from: comps)!

        expectEqual(GraphStore.conflictStamp(for: date), "20260610-143005")

        // What the pin prevents: the same pattern under a Buddhist calendar.
        let unpinned = DateFormatter()
        unpinned.locale = Locale(identifier: "th_TH@calendar=buddhist")
        unpinned.dateFormat = "yyyyMMdd-HHmmss"
        expectTrue(unpinned.string(from: date).hasPrefix("2569"))
    }
    /// A save whose serialized text matches what is already on disk must not
    /// rewrite the file: every rewrite is a fresh version on file-versioning
    /// cloud storage, and a whole-page reindex besides.
    @Test func savingUnchangedContentDoesNotRewriteTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-noop-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)

        var doc = try store.createPage(named: "Notes")
        doc.blocks[0].content = "settled"
        store.updatePage(doc)
        try store.savePage(named: "Notes")
        let url = store.fileURL(forPageNamed: "Notes")
        let firstWrite = try #require(GraphStore.stamp(of: url))

        // A save with no net change (typed and undone, say): same text, so the
        // file must be left exactly as it was.
        store.updatePage(doc)
        try store.savePage(named: "Notes")
        expectEqual(GraphStore.stamp(of: url), firstWrite)

        // A real change still writes.
        // Different *length* too, so the comparison cannot pass on mtime alone.
        doc.blocks[0].content = "changed, and rather longer than before"
        store.updatePage(doc)
        try store.savePage(named: "Notes")
        expectTrue(GraphStore.stamp(of: url) != firstWrite)
        let text = try String(contentsOf: url, encoding: .utf8)
        expectTrue(text.contains("rather longer"))
    }

    @Test func staleSaveSnapshotDoesNotMarkNewerEditsClean() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-stale-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)

        var doc = try store.createPage(named: "Notes")
        doc.blocks[0].content = "first"
        store.updatePage(doc)
        let stale = try #require(store.pageSaveSnapshot(named: "Notes"))

        doc.blocks[0].content = "second"
        store.updatePage(doc)
        _ = try store.persistPageSnapshot(stale)

        expectFalse(store.finishPageSave(stale))
        let current = store.page(named: "Notes")
        expectEqual(current.blocks[0].content, "second")
        expectTrue(current.isDirty)

        let latest = try #require(store.pageSaveSnapshot(named: "Notes"))
        _ = try store.persistPageSnapshot(latest)
        expectTrue(store.finishPageSave(latest))
        expectFalse(store.page(named: "Notes").isDirty)
        let saved = try String(contentsOf: store.fileURL(forPageNamed: "Notes"), encoding: .utf8)
        expectTrue(saved.contains("second"))
    }


    private func makeGraph(_ files: [String: String], journals: [String: String] = [:]) throws -> GraphStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-test-\(UUID().uuidString)")
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
        // Breadcrumb is now looked up on demand (not carried on every hit); a
        // top-level source block has no ancestors.
        if let id = backlinks.first?.blockID {
            expectEqual(try store.cache.breadcrumb(ofBlock: id), [])
        }
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

    @Test func duplicateBlockIDsDoNotBreakIndexing() throws {
        // Two files sharing the same persisted id:: (copy/paste, file dup, or a
        // Logseq import) must not abort the sync — the graph has to open, and
        // both blocks stay searchable. (`blocks.id` is a PRIMARY KEY; a naive
        // insert would throw and `GraphStore.init` would fail.)
        let id = "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f"
        let store = try makeGraph([
            "First": "- alpha block\n  id:: \(id)\n",
            "Second": "- beta block\n  id:: \(id)\n",
        ])
        // Both blocks indexed and findable despite the id clash.
        expectEqual(try store.cache.searchBlocks("alpha block").count, 1)
        expectEqual(try store.cache.searchBlocks("beta block").count, 1)
        // The shared id still resolves (to the first-indexed copy).
        expectNotNil(store.resolveBlock(UUID(uuidString: id)!))
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

    @Test func resolveBlockByVolatileIndexID() throws {
        // A query hit carries the *index* block id. Un-persisted blocks get a
        // fresh random id on every parse, so that id won't match a freshly
        // loaded page — `resolveBlock` must relocate by preorder position.
        let store = try makeGraph(["Tasks": "- TODO buy milk\n- DONE call mom\n"])
        let hits = try store.cache.runQuery(QueryParser.parse("TODO")!, limit: 10).hits
        expectEqual(hits.count, 1)
        let resolved = store.resolveBlock(hits[0].blockID)
        expectEqual(resolved?.pageName, "Tasks")
        expectEqual(resolved?.block.content, "TODO buy milk")
        // The resolved block's id is the live in-memory one (usable for edits),
        // not the volatile index id we looked up with.
        expectEqual(store.page(named: "Tasks").blocks.path(to: resolved!.block.id) != nil, true)
    }

    @Test func stubPages() throws {
        let store = try makeGraph(["A": "- mentions [[Ghost Page]]\n"])
        expectEqual(try store.cache.stubPageNames(), ["Ghost Page"])
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
        expectEqual(try store.cache.stubPageNames(), ["Doomed"])
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
        expectEqual(
            store.page(named: "2026-06-10").displayTitle(using: JournalDateFormat(rawValue: "MMM d{ordinal}, yyyy"), locale: Locale(identifier: "en_US")),
            "Jun 10th, 2026")
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
        expectEqual(day.displayTitle(using: JournalDateFormat(rawValue: "MMM d{ordinal}, yyyy"), locale: Locale(identifier: "en_US")), "Jun 10th, 2026")
        // No stub created for the ISO spelling.
        expectEqual(try store.cache.stubPageNames(), [])
    }

    @Test func nativeJournalWinsOverLogseqDuplicate() throws {
        // The same day exists as both a native `2026-06-10.md` and a Logseq
        // `2026_06_10.md`. The native file wins: the day is one page keyed on the
        // ISO date, navigating it loads the native content, and the Logseq file is
        // ignored (not indexed as a second page) but left untouched on disk.
        let store = try makeGraph([:], journals: [
            "2026-06-10": "- native day\n",
            "2026_06_10": "- logseq day\n",
        ])
        let journals = try store.cache.journalPages()
        expectEqual(journals.count, 1)
        expectEqual(journals.first?.nameKey, "2026-06-10")
        expectEqual(store.page(named: "2026-06-10").blocks.first?.content, "native day")
        expectTrue(FileManager.default.fileExists(
            atPath: store.journalsDir.appendingPathComponent("2026_06_10.md").path))
    }

    @Test func dateKeysCanonicalize() {
        expectEqual(PageName.key("2026_06_10"), "2026-06-10")
        expectEqual(PageName.key("2026-06-10"), "2026-06-10")
        // The friendly display / Logseq reference form folds to the same day.
        expectEqual(PageName.key("Jun 10th, 2026"), "2026-06-10")
        expectEqual(PageName.key("June 10th, 2026"), "2026-06-10") // full month name
        expectEqual(PageName.key("Mar 1st, 2026"), "2026-03-01")   // ordinal suffix
        expectEqual(PageName.key("Dec 23rd, 2025"), "2025-12-23")
        expectEqual(PageName.key("Project X"), "project x")        // non-dates unchanged
        expectNil(JournalDate(pageName: "Mar 32nd, 2026"))         // invalid day rejected
        expectNil(JournalDate(pageName: "Foo 10th, 2026"))         // not a month
    }

    @Test func friendlyReferenceResolvesToJournal() throws {
        // A note references a journal day in Logseq's friendly form; the day has
        // a real (underscore-named) file. The reference resolves to that day
        // rather than becoming a separate stub, and the backlink lights up.
        let store = try makeGraph(
            ["Note": "- met her on [[Jun 10th, 2026]]\n"],
            journals: ["2026_06_10": "- the imported day\n"]
        )
        expectEqual(try store.cache.backlinks(of: PageName.key("Jun 10th, 2026")).count, 1)
        expectEqual(try store.cache.stubPageNames(), [])
        let day = store.page(named: "Jun 10th, 2026")
        expectTrue(day.fileExists)
        expectEqual(day.blocks.first?.content, "the imported day")
    }

    @Test func persistBlockIDWritesIdProperty() throws {
        let store = try makeGraph(["P": "- target block\n"])
        let doc = store.page(named: "P")
        let blockID = doc.blocks[0].id
        try store.persistBlockID(blockID, inPageNamed: "P")
        let text = try String(contentsOf: store.fileURL(forPageNamed: "P"), encoding: .utf8)
        expectEqual(text, "- target block\n  id:: \(blockID.uuidString.lowercased())\n")
    }

    @Test func persistBlockIDFromSearchHitPersistsAndResolves() throws {
        // The autocomplete flow: `((` search returns an id from the *index*,
        // where an un-persisted block gets a fresh random id on each parse — so
        // the id won't match a freshly-loaded page. persistBlockID must still
        // write `id::` (matching the inserted `((id))`) and resolveBlock find it.
        let store = try makeGraph(["P": "- a\n- the memorable target\n  - child\n"])
        let hits = try store.cache.searchBlocks("memorable target")
        expectNotNil(hits.first)
        guard let hit = hits.first else { return }
        try store.persistBlockID(hit.blockID, inPageNamed: hit.pageDisplayName)

        let text = try String(contentsOf: store.fileURL(forPageNamed: "P"), encoding: .utf8)
        expectTrue(text.contains("id:: \(hit.blockID.uuidString.lowercased())"))
        let resolved = store.resolveBlock(hit.blockID)
        expectEqual(resolved?.block.content, "the memorable target")
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

    @Test func indexMaintenanceRebuildsPagesAndPreservesRecents() throws {
        let store = try makeGraph(["A": "- alpha\n", "B": "- beta\n"])
        try store.cache.recordVisit(pageKey: "a")
        try store.indexMaintenance.rebuild()
        let rebuiltSize = try #require(store.indexMaintenance.sizeOnDisk())
        try store.indexMaintenance.rebuild()

        expectEqual(Set(try store.cache.allPages().map(\.displayName)), Set(["A", "B"]))
        expectEqual(try store.cache.searchBlocks("alpha").first?.pageDisplayName, "A")
        expectEqual(try store.cache.recentPageKeys(), ["a"])
        expectTrue(rebuiltSize > 0)
        expectEqual(store.indexMaintenance.sizeOnDisk(), Optional(rebuiltSize))
    }
}
