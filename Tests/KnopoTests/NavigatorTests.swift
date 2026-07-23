import Foundation
import Testing
@testable import Knopo
import KnopoCore

@Suite struct NavigatorTests {
    @MainActor
    @Test func allPagesCollapseStatePersistsPerGraph() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-all-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        try store.updateConfig {
            $0.allPagesCollapsedSections = ["journal"]
        }
        let app = AppState(store: store)
        defer { app.shutdown() }

        #expect(app.allPagesCollapsedSections == ["journal"])
        app.toggleAllPagesSection("pages")
        app.toggleAllPagesSection("journal")

        #expect(app.allPagesCollapsedSections == ["pages"])
        #expect(store.config.allPagesCollapsedSections == ["pages"])
        #expect(
            GraphConfig.load(from: store.configURL).allPagesCollapsedSections
                == ["pages"]
        )
    }

    @MainActor
    @Test func renamePageUpdatesRightSidebarTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-navigator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Old Name")
        page.blocks[0].content = "Kept content"
        store.updatePage(page)
        try store.savePage(named: page.name)

        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let zoom = page.blocks[0].id
        nav.rightPanes = [
            RightPane(target: .page(name: "Old Name", zoom: zoom), collapsed: true),
            RightPane(target: .page(name: "old name")),
            RightPane(target: .page(name: "Other Page")),
        ]

        try nav.renamePage(from: "Old Name", to: "New Name")

        #expect(nav.rightPanes.count == 3)
        #expect(nav.rightPanes[0].target == .page(name: "New Name", zoom: zoom))
        #expect(nav.rightPanes[0].collapsed)
        #expect(nav.rightPanes[1].target == .page(name: "New Name"))
        #expect(nav.rightPanes[2].target == .page(name: "Other Page"))
        #expect(app.document(for: "New Name").blocks.map(\.content) == ["Kept content"])
    }
}
