import Foundation
import Testing
@testable import Knopo
import KnopoCore

@Suite struct PageAliasNavigationTests {
    @MainActor
    @Test func anOpenStubFollowsItsNewOwnerThroughRenameAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-live-nav-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.navigate(to: .page(name: "AI"))
        _ = app.document(for: "AI")
        nav.navigate(to: .allPages)
        nav.navigate(to: .page(name: "AI"))
        nav.openInRightSidebar(.page(name: "Owner"))
        var owner = app.document(for: "Owner")
        owner.blocks[0].content = "owner content"
        owner.blocks[0].properties = [BlockProperty(key: "alias", value: "AI")]
        app.commit(owner)
        app.flushPendingSaves()
        #expect(nav.current == .page(name: "Owner"))
        #expect(nav.rightPanes.first?.target == .page(name: "Owner"))
        nav.goBack()
        nav.goBack()
        #expect(nav.current == .page(name: "Owner"))
        try nav.renamePage(from: "AI", to: "Renamed")
        #expect(nav.current == .page(name: "Renamed"))
        #expect(nav.rightPanes.first?.target == .page(name: "Renamed"))
        try nav.deletePage(named: "AI")
        #expect(nav.current == .journalHome)
        #expect(nav.rightPanes.isEmpty)
    }

    @MainActor
    @Test func dateSpellingsAppearAsNormalPageSuggestions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-date-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let doc = PageDocument(name: "2026_06_10", blocks: [Block(content: "journal")], isJournal: true)
        store.updatePage(doc)
        try store.savePage(named: doc.name)
        let app = AppState(store: store)
        defer { app.shutdown() }
        for query in ["2026-06-10", "Jun 10th, 2026"] {
            #expect(app.pageExists(named: query))
            #expect(app.pageNames(matching: query).first == "2026_06_10")
        }
        let nav = Navigator(app: app)
        nav.navigateToNewPage(named: "2026-06-10")
        #expect(nav.focusFirstBlock == nav.current.pageName)
    }

    @MainActor
    @Test func navigatingToTheCurrentTargetKeepsThePendingSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-noop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store, saveDebounce: 60, saveCeiling: 120)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.navigate(to: .page(name: "Owner"))
        var doc = app.document(for: "Owner")
        doc.blocks[0].content = "pending edit"
        doc.blocks[0].properties = [BlockProperty(key: "alias", value: "AI")]
        app.commit(doc)
        nav.navigate(to: nav.current)
        #expect(app.document(for: "Owner").isDirty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(forPageNamed: "Owner").path))
        nav.navigate(to: .page(name: "AI"))
        #expect(nav.current == .page(name: "Owner"))
        #expect(!app.document(for: "Owner").isDirty)
        #expect(app.pageExists(named: "AI"))
    }

    @MainActor
    @Test func aliasesShareNavigationAndAppearInSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-alias-nav-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.openInRightSidebar(.page(name: "AI"))
        var doc = try store.createPage(named: "Artificial Intelligence")
        doc.blocks[0].properties = [BlockProperty(key: "alias", value: "AI, Machine Intelligence")]
        app.commit(doc)
        // Navigation flushes the pending property edit before resolving the name.
        nav.navigate(to: .page(name: "ai"))
        #expect(nav.current == .page(name: "Artificial Intelligence"))
        #expect(app.pageNames(matching: "AI").first == "AI")
        #expect(app.pageNames(matching: "Machine").contains("Machine Intelligence"))
        #expect(!app.pageNames(matching: "").contains("AI"))
        #expect(!app.pageNames(matching: "").contains("Machine Intelligence"))
        #expect(app.pageNames(matching: "").filter { $0 == doc.name }.count == 1)
        #expect(app.pageExists(named: "aI"))
        #expect(!app.allPages().contains { $0.displayName == "AI" })
        #expect(app.document(for: "AI").blocks[0].id == doc.blocks[0].id)
        #expect(app.displayTitle(for: "AI") == "AI")
        nav.openInRightSidebar(.page(name: "AI"))
        nav.openInRightSidebar(.page(name: "Artificial Intelligence"))
        #expect(nav.rightPanes.count == 1)
        #expect(nav.rightPanes.first?.target == .page(name: "Artificial Intelligence"))
        #expect(try store.cache.recentPageKeys().first == "artificial intelligence")
    }
}
