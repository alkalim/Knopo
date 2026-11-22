import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarSelectionTests {
    @Test func favouriteAndRecentSelectIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        var page = app.store.page(named: "Alpine")
        page.blocks = [Block(content: "Trail notes")]
        app.store.updatePage(page)
        try app.store.savePage(named: page.name)
        app.toggleFavourite(page.name)
        app.recordVisit(toPageNamed: page.name)
        let nav = Navigator(app: app)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let host = NSHostingView(rootView: Sidebar().environmentObject(app).environmentObject(nav)
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        window.layoutIfNeeded()
        let list = try #require(table(in: host))
        try await waitUntil { list.selectedRow >= 0 }
        let journal = list.selectedRow

        nav.navigate(to: .page(name: page.name))
        try await waitUntil { list.selectedRow > journal }
        let favourite = list.selectedRow
        // With one favourite, one recent and no tags, the recent is the last row.
        let recent = list.numberOfRows - 1
        try #require(favourite < recent)
        let history = nav.backTitles
        list.selectRowIndexes(IndexSet(integer: journal), byExtendingSelection: false)
        list.selectRowIndexes(IndexSet(integer: recent), byExtendingSelection: false)
        // Reopening Favourites must leave the selected copy in Recents.
        let count = list.numberOfRows
        defaults.set(false, forKey: "sidebar.favouritesExpanded")
        try await waitUntil { list.numberOfRows < count }
        defaults.set(true, forKey: "sidebar.favouritesExpanded")
        try await waitUntil { list.numberOfRows == count }
        #expect(list.selectedRowIndexes == IndexSet(integer: recent))
        #expect(nav.backTitles == history)
        list.selectRowIndexes(IndexSet(integer: favourite), byExtendingSelection: false)
        try await waitUntil { nav.current == .page(name: page.name) }
        #expect(list.selectedRowIndexes == IndexSet(integer: favourite))
        list.selectRowIndexes(IndexSet(integer: journal), byExtendingSelection: false)
        host.layoutSubtreeIfNeeded()
        #expect(list.selectedRow == journal)
        #expect(nav.current == .page(name: page.name))
        try await waitUntil { nav.current == .journalHome }
        nav.goBack()
        try await waitUntil { list.selectedRowIndexes == IndexSet(integer: favourite) }

        list.selectRowIndexes(IndexSet(integer: journal), byExtendingSelection: false)
        nav.navigate(to: .allPages)
        try await waitUntil { list.selectedRow == journal + 1 }
        #expect(nav.current == .allPages)
    }
}
