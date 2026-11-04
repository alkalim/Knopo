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

    private func rig(todayBlocks: Int, wholeWindow: Bool = false) throws -> Rig {
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
        let content = wholeWindow ? AnyView(MainWindow()) : AnyView(JournalView())
        let host = NSHostingView(rootView: content.environmentObject(app).environmentObject(nav))
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

    @Test func leavingTheJournalCommitsTheCurrentUndoSession() async throws {
        let rig = try rig(todayBlocks: 6, wholeWindow: true)
        defer { rig.app.shutdown(); rig.window.contentView = nil }
        try await rig.settle()
        let today = JournalDate.today().pageName
        let original = rig.app.document(for: today).blocks[0]
        do {
            let table = try #require(descendants(rig.host, of: OutlineTableView.self).first {
                ($0.delegate as? OutlineEditorController)?.pageName == today
            })
            let controller = try #require(table.delegate as? OutlineEditorController)
            controller.focusBlock(original.id, selection: NSRange(location: 0, length: 0))
            let editor = try #require(rig.window.firstResponder as? BlockEditorTextView)
            editor.string = "An edit made before leaving the journal"
            editor.didChangeText()
        }
        rig.nav.navigate(to: .page(name: "Another page"))
        try await rig.settle()
        #expect(rig.app.document(for: today).blocks[0].content != original.content)
        rig.app.undo()
        #expect(rig.app.document(for: today).blocks[0].content == original.content)
    }

    @Test(arguments: [0, -1])
    func undoFromOlderEntriesRestoresTheEditedDay(dayOffset: Int) async throws {
        let rig = try rig(todayBlocks: 6)
        defer { rig.app.shutdown(); rig.window.contentView = nil }
        try await rig.settle()
        let today = JournalDate.today().adding(days: dayOffset).pageName
        let table = try #require(descendants(rig.host, of: OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == today
        })
        let controller = try #require(table.delegate as? OutlineEditorController)
        controller.focusBlock(rig.app.document(for: today).blocks[0].id,
                              selection: NSRange(location: 3, length: 0))
        controller.editorSplit(atUTF16Offset: 3)
        try await rig.settle()
        rig.window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(600))
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 3_000))
        rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
        try await rig.settle()
        rig.app.undo()
        try await rig.settle()
        let editor = try #require(rig.window.firstResponder as? BlockEditorTextView)
        #expect(outlinePage(of: editor) == today)
        #expect(!editor.visibleRect.isEmpty)
    }

    @Test(arguments: [1, 10])
    func findExcludesRecycledDays(day: Int) async throws {
        let rig = try rig(todayBlocks: 6)
        defer { rig.app.shutdown(); rig.window.contentView = nil }
        try await rig.settle()
        try await Task.sleep(for: .milliseconds(600))
        rig.window.makeFirstResponder(nil)
        let query = "Entry \(day),"
        rig.nav.findActive = true
        rig.nav.findQuery = query
        try await rig.settle()
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 3_000))
        rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
        try await rig.settle()
        let expected = descendants(rig.host, of: OutlineTableView.self).reduce(0) { total, table in
            guard let controller = table.delegate as? OutlineEditorController else { return total }
            return total + rig.app.document(for: controller.pageName).blocks.filter {
                $0.content.contains(query)
            }.count
        }
        #expect(rig.nav.findMatchCount == expected)
        if day == 10 { #expect(expected > 0) }
    }

    @Test func returningToTodayKeepsTheCurrentResponder() async throws {
        let rig = try rig(todayBlocks: 6)
        defer { rig.app.shutdown(); rig.window.contentView = nil }
        try await rig.settle()
        try await Task.sleep(for: .milliseconds(600))
        let reader = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        rig.host.addSubview(reader)
        rig.window.makeFirstResponder(reader)
        let blockCount = rig.app.document(for: JournalDate.today().pageName).blocks.count
        for y: CGFloat in [6_000, 0] {
            rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
            try await rig.settle()
            #expect(rig.window.firstResponder === reader)
        }
        #expect(rig.app.document(for: JournalDate.today().pageName).blocks.count == blockCount)
    }

    @Test func resizePreservesMarkedTextInAnOlderDay() async throws {
        let rig = try rig(todayBlocks: 6)
        defer { rig.app.shutdown(); rig.window.contentView = nil }
        try await rig.settle()
        try await Task.sleep(for: .milliseconds(600))
        rig.window.makeFirstResponder(nil)
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
        try await rig.settle()
        let table = try #require(descendants(rig.host, of: OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName != JournalDate.today().pageName
                && !$0.visibleRect.isEmpty
        })
        let controller = try #require(table.delegate as? OutlineEditorController)
        let block = rig.app.document(for: controller.pageName).blocks[0]
        controller.focusBlock(block.id, selection: NSRange(location: 0, length: 0))
        try await rig.settle()
        let editor = try #require(rig.window.firstResponder as? BlockEditorTextView)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        let text = editor.string
        let selection = editor.selectedRange()
        for width: CGFloat in [360, 900, 700] {
            rig.window.setContentSize(NSSize(width: width, height: 450))
            try await rig.settle()
            #expect(rig.window.firstResponder === editor)
            #expect(editor.hasMarkedText())
            #expect(editor.string == text)
            #expect(editor.selectedRange() == selection)
        }
        editor.unmarkText()
    }

    /// Opening a search hit is a reading action, today's journal included. Its
    /// automatic writing focus must not replace the reveal.
    @Test(arguments: [0, -1])
    func searchResultRevealsTheJournalBlockWithoutTakingFocus(dayOffset: Int) async throws {
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
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        let blockID = app.document(for: day).blocks[1].id
        // Verify that the destination was flashed. The overlay may already have
        // faded on a slow runner; BlockFlashTests cover the overlay itself.
        #expect(controller.flashedBlockID == blockID)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 1)))
        #expect(!(window.firstResponder is BlockEditorTextView))
        #expect(app.document(for: day).blocks.count == 40)

        // Check again after the flash's hold and fade have elapsed.
        try await Task.sleep(for: .seconds(2))
        // A subsequent presentation must not belatedly take the caret either.
        app.dataVersion += 1
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.flashedBlockID == blockID)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 1)))
        #expect(!(window.firstResponder is BlockEditorTextView))
        #expect(app.document(for: day).blocks.count == 40)
    }

    @Test func searchRevealSurvivesSlowWindowAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-slow-reveal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var doc = store.page(named: "Target")
        doc.blocks = (0..<40).map { Block(content: "Entry \($0)") }
        store.updatePage(doc)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let target = doc.blocks[30]
        nav.navigateToBlock(pageName: doc.name, blockID: target.id,
                            content: target.content, inSidebar: false)
        let controller = OutlineEditorController(app: app, nav: nav)

        // Cold window construction can block the main thread before the
        // deferred reveal runs. Exceed its old two-second deadline.
        func presentSlowly() {
            controller.present(pageName: doc.name, zoom: nil)
            Thread.sleep(forTimeInterval: 2.1)
        }
        presentSlowly()
        let table = controller.tableView
        table.frame = NSRect(x: 0, y: 0, width: 700,
                             height: table.intrinsicContentSize.height)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = scroll
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(controller.flashedBlockID == target.id)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 30)))

        // Once the reveal settles, later scrolling belongs to the reader.
        try await Task.sleep(for: .seconds(2.1))
        scroll.contentView.scroll(to: .zero)
        table.onDidLayout?()
        try await Task.sleep(for: .milliseconds(60))
        #expect(table.visibleRect.minY == 0)
        #expect(!table.visibleRect.intersects(table.rect(ofRow: 30)))
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
        let host = NSHostingView(rootView: MainWindow()
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
            let controller = try #require(table.delegate as? OutlineEditorController)
            #expect(controller.flashedBlockID == app.document(for: day).blocks[1].id,
                    "Destination: \(day), starting in feed: \(startInFeed)")
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
            // Deep in older entries, away from today's writing block.
            #expect(rig.scroll.documentVisibleRect.minY > 1_000)

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
