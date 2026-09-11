import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

/// `⌘J` in the journal feed (SPEC §10): every press puts the caret in today's
/// writing block and shows it. Runs the real view in an offscreen window - what
/// is on screen afterwards, and whether today's editor is there to take the
/// request at all, is not something a test of `Navigator` can see.
@MainActor
@Suite struct JournalNavigationTests {

    /// The feed in a window: today with `todayBlocks` blocks, then older days.
    @MainActor private struct Rig {
        let app: AppState
        let nav: Navigator
        let host: NSView
        let window: NSWindow
        let scroll: NSScrollView

        /// Let SwiftUI updates, deferred focus and lazy layout settle.
        func settle() async throws {
            for _ in 0..<10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func rig(todayBlocks: Int) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-nav-\(UUID().uuidString)")
        let store = try GraphStore(root: root)
        let today = JournalDate.today()
        for offset in 0..<15 {
            var doc = store.page(named: today.adding(days: -offset).pageName)
            doc.blocks = (0..<(offset == 0 ? todayBlocks : 8))
                .map { Block(content: "Entry \(offset), block \($0)") }
            store.updatePage(doc)
            try store.savePage(named: doc.name)
        }
        let app = AppState(store: store)
        let nav = Navigator(app: app)
        let host = NSHostingView(
            rootView: JournalView().environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let scroll = descendants(host, of: NSScrollView.self)[0]
        return Rig(app: app, nav: nav, host: host, window: window, scroll: scroll)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants($0, of: type) }
    }

    /// The pages the feed has an outline for; the lazy stack drops the far ones.
    private func loadedPages(in host: NSView) -> [String] {
        descendants(host, of: OutlineTableView.self)
            .compactMap { ($0.delegate as? OutlineEditorController)?.pageName }
    }

    /// Which page's outline an editor sits in, via its table's controller.
    private func outlinePage(of editor: NSView) -> String? {
        var view: NSView? = editor
        while let current = view {
            if let table = current as? OutlineTableView {
                return (table.delegate as? OutlineEditorController)?.pageName
            }
            view = current.superview
        }
        return nil
    }

    /// Opening a search hit is a reading action, today's journal included. Its
    /// automatic writing focus must not replace the reveal.
    @Test(arguments: [0, -1])
    func searchResultKeepsTheJournalBlockHighlighted(dayOffset: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let day = JournalDate.today().adding(days: dayOffset).pageName
        var doc = store.page(named: day)
        doc.blocks = (0..<40).map { Block(content: "Journal entry \($0)") }
        doc.blocks[1].content = "Needle in the journal"
        store.updatePage(doc)
        try store.savePage(named: day)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let hit = try #require(store.cache.searchBlocks("Needle", limit: 20).first)
        nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: hit.blockID,
                            content: hit.content, inSidebar: false)

        let host = NSHostingView(rootView: PageScreen(pageName: day)
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        // A subsequent presentation must not belatedly take the caret either.
        app.dataVersion += 1
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: false)
            as? OutlineRowCell)
        #expect(cell.isFlashing)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 1)))
        #expect(!(window.firstResponder is BlockEditorTextView))
        #expect(app.document(for: day).blocks.count == 40)
    }

    /// Navigation in the whole window. The feed being left may already hold an
    /// outline for the day being opened.
    @Test(arguments: [true, false])
    func searchBetweenJournalPagesHighlightsEachDestination(startInFeed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-transition-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let days = (0..<3).map { JournalDate.today().adding(days: -$0).pageName }
        for day in days {
            var doc = store.page(named: day)
            doc.blocks = (0..<8).map { Block(content: "Entry \($0) on \(day)") }
            doc.blocks[1].content = "Needle on \(day)"
            store.updatePage(doc)
            try store.savePage(named: day)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        if !startInFeed { nav.navigate(to: .page(name: days[0])) }
        let host = NSHostingView(rootView: MainWindow(graphName: "Test", openGraphSettings: {})
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async throws {
            for _ in 0..<10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await settle()
        for day in [days[1], days[0], days[2], days[1]] {
            let hit = try #require(store.cache.searchBlocks("Needle", limit: 20)
                .first { $0.pageDisplayName == day })
            nav.searchPresented = true
            try await settle()
            nav.searchPresented = false
            nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: hit.blockID,
                                content: hit.content, inSidebar: false)
            try await settle()
            #expect(nav.current == .page(name: day))
            let table = try #require(descendants(host, of: OutlineTableView.self).first {
                ($0.delegate as? OutlineEditorController)?.pageName == day
            })
            let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: false)
                as? OutlineRowCell)
            #expect(cell.isFlashing, "Destination: \(day), starting in feed: \(startInFeed)")
            #expect(table.visibleRect.intersects(table.rect(ofRow: 1)))
        }
    }

    /// A day that fits arrives whole: stopping as soon as the caret's own row is
    /// on screen would push the title and the blocks above it off the top.
    @Test func shortcutShowsTheWholeDayWhenItFits() async throws {
        let rig = try rig(todayBlocks: 6)
        defer { rig.app.shutdown() }
        try await rig.settle()
        // Read an older entry, once the caret's reveal request has lapsed.
        try await Task.sleep(for: .milliseconds(600))
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 3_000))
        rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
        try await rig.settle()
        #expect(rig.scroll.documentVisibleRect.minY > 1_000)

        rig.nav.goToJournal()
        try await rig.settle()
        let editor = try #require(rig.window.firstResponder as? BlockEditorTextView)
        #expect(outlinePage(of: editor) == JournalDate.today().pageName)
        #expect(!editor.visibleRect.isEmpty)
        // Back at the top of the feed, so today reads from its title down.
        #expect(rig.scroll.documentVisibleRect.minY < 1)
    }

    /// Today taller than the window, so landing on its heading is not enough:
    /// the writing block itself has to be on screen.
    @Test func shortcutReturnsFromEarlierEntries() async throws {
        let rig = try rig(todayBlocks: 40)
        defer { rig.app.shutdown() }
        let today = JournalDate.today()
        try await rig.settle()
        for attempt in 0..<2 {
            // Cover both leaving the editor and scrolling while it has focus.
            if attempt == 0 { rig.window.makeFirstResponder(nil) }
            // Let the caret's reveal request lapse: while it stands it is meant
            // to pull the row back, as it has long since stopped doing by the
            // time a reader scrolls away.
            try await Task.sleep(for: .milliseconds(600))
            rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 6_000))
            rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
            try await rig.settle()
            // Deep in the older entries, where the lazy stack used to drop
            // today's editor and leave the request unanswered.
            #expect(rig.scroll.documentVisibleRect.minY > 1_000)
            #expect(loadedPages(in: rig.host).contains(today.pageName))

            rig.nav.goToJournal()
            try await rig.settle()
            // Offset alone would prove nothing here: the lazy stack re-estimates
            // its height and snaps back to the top on its own.
            let editor = try #require(rig.window.firstResponder as? BlockEditorTextView)
            #expect(outlinePage(of: editor) == today.pageName)
            #expect(!editor.visibleRect.isEmpty)
            #expect(rig.nav.focusWritingIn == nil)
            #expect(rig.nav.current == .journalHome)
        }
    }
}
