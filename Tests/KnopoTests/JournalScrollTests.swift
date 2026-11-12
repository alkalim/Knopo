import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct JournalScrollTests {
    @Test(arguments: [0, 8])
    func openingThreeYearsOfJournalsLoadsOnlyNearbyDays(futureDays: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-journal-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let today = JournalDate.today()
        let days = (-futureDays..<1_095).map { today.adding(days: -$0).pageName }
        let content = (0..<30).map { "- Entry \($0) with **formatting**, a [[Page]] reference and a #tag.\n" }.joined()
        for day in days {
            try content.write(to: store.fileURL(forPageNamed: day), atomically: true, encoding: .utf8)
        }
        try store.synchronizeIndex()
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.navigate(to: .page(name: "Another page"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let host = NSHostingView(rootView: MainWindow()
            .environmentObject(app).environmentObject(nav))
        window.contentView = host
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        nav.goToJournal()
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let loaded = days.filter { store.isLoaded($0) }
        #expect(store.isLoaded(today.pageName))
        // Allow AppKit's prefetch margin without constructing weeks of editors.
        #expect(loaded.count < 20)
        #expect(!store.isLoaded(days.last!))
        #expect(nav.current == .journalHome)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        #expect(!editor.visibleRect.isEmpty)
        let feed = try #require(tables(in: host).first?.enclosingScrollView?.documentView as? JournalTableView)
        #expect(feed.numberOfRows == days.count + 2)
        let coordinator = try #require(feed.delegate as? JournalScrollView.Coordinator)
        #expect(coordinator.days == days)
        try await Task.sleep(for: .milliseconds(600))
        window.makeFirstResponder(nil)
        feed.scrollRowToVisible(days.count)
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isLoaded(days.last!))
        #expect(days.filter { store.isLoaded($0) }.count < 40)
    }

    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func initialWidthAccountsForScrollbar(style: NSScroller.Style) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-scrollbar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: JournalScrollView(days:
            (0..<30).map { JournalDate.today().adding(days: -$0).pageName })
            .environmentObject(app).environmentObject(Navigator(app: app)))
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        let initial = try #require(tables(in: document).first?.delegate as? OutlineEditorController)
        #expect(initial.initialLayoutWidth == scroll.contentSize.width - 40)
        scroll.scrollerStyle = style
        scroll.tile()
        window.layoutIfNeeded()
        let table = try #require(tables(in: document).first)
        #expect(table.bounds.width == scroll.contentSize.width - 40)
        scroll.scrollerStyle = style == .legacy ? .overlay : .legacy
        scroll.tile()
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(table.bounds.width == scroll.contentSize.width - 40)
    }

    private final class Days: ObservableObject {
        @Published var values: [String]
        init(_ values: [String]) { self.values = values }
    }

    private struct Feed: View {
        @ObservedObject var days: Days
        var body: some View { JournalScrollView(days: days.values) }
    }

    private func tables(in view: NSView) -> [OutlineTableView] {
        ((view as? OutlineTableView).map { [$0] } ?? [])
            + view.subviews.flatMap { tables(in: $0) }
    }

    private final class ResizeWindow: NSWindow {
        var resizing = false
        override var inLiveResize: Bool { resizing || super.inLiveResize }
    }

    @Test(arguments: [false, true])
    func rolloverRetainsTheNewTodayAmongFutureEntries(alreadyExists: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-future-rollover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let today = JournalDate.today().pageName
        let tomorrow = JournalDate.today().adding(days: 1).pageName
        let later = JournalDate.today().adding(days: 2).pageName
        for day in [today, later] + (alreadyExists ? [tomorrow] : []) {
            var page = store.page(named: day)
            page.blocks = [Block(content: "Entry for \(day)")]
            store.updatePage(page)
            try store.savePage(named: day)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: JournalView().environmentObject(app).environmentObject(nav))
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try #require(tables(in: host).first?.enclosingScrollView?.documentView as? JournalTableView)
        let coordinator = try #require(table.delegate as? JournalScrollView.Coordinator)
        let oldTodayHost = try #require(coordinator.todayHost)
        let tomorrowHost = alreadyExists ? table.view(atColumn: 0, row: 2, makeIfNecessary: false) : nil
        coordinator.update(days: [later, tomorrow, today], focusToken: nav.focusWritingToken, today: tomorrow)
        window.layoutIfNeeded()
        let newTodayHost = try #require(coordinator.todayHost)
        if alreadyExists { #expect(newTodayHost === tomorrowHost) }
        #expect(newTodayHost !== oldTodayHost)
        #expect(newTodayHost.identifier == nil)
        #expect(table.view(atColumn: 0, row: 2, makeIfNecessary: false) === newTodayHost)
        #expect(oldTodayHost.identifier == NSUserInterfaceItemIdentifier("day"))
        #expect(table.view(atColumn: 0, row: 3, makeIfNecessary: false) === oldTodayHost)
    }

    @Test func shortFeedDoesNotScrollByTheToolbarInset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-short-feed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: JournalView().environmentObject(app)
            .environmentObject(Navigator(app: app)))
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        let document = try #require(scroll.documentView)
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.bounds.height + scroll.contentInsets.top <= scroll.contentSize.height + 0.5)
        var requested = scroll.contentView.bounds
        requested.origin.y = 1_000
        #expect(abs(scroll.contentView.constrainBoundsRect(requested).minY + scroll.contentInsets.top) < 1)
    }

    @Test func newTodayKeepsTheTopVisibleWhilePreviousDayHasFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-feed-rollover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let previousDay = JournalDate.today().adding(days: -1).pageName
        var page = store.page(named: previousDay)
        page.blocks = (0..<10).map { Block(content: "Yesterday's entry \($0)") }
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let previousDays = (1...15).map { JournalDate.today().adding(days: -$0).pageName }
        let days = Days(previousDays)
        let host = NSHostingView(rootView: Feed(days: days).environmentObject(app).environmentObject(nav))
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<20 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        for y: CGFloat in [3_000, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
        }
        let previousTable = try #require(tables(in: document).first {
            ($0.delegate as? OutlineEditorController)?.pageName == previousDay
        })
        let previous = try #require(previousTable.delegate as? OutlineEditorController)
        previous.focusBlock(page.blocks[0].id, selection: NSRange(location: 0, length: 0))
        try await settle()
        #expect(window.firstResponder is BlockEditorTextView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        try await Task.sleep(for: .seconds(1))
        days.values = [JournalDate.today().pageName] + previousDays
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 1)
        let today = try #require(tables(in: document).first {
            ($0.delegate as? OutlineEditorController)?.pageName == JournalDate.today().pageName
        })
        #expect(today.convert(today.bounds, to: document).intersects(scroll.documentVisibleRect))
        #expect((previousTable.delegate as? OutlineEditorController)?.pageName == previousDay)
        #expect(window.firstResponder is BlockEditorTextView)
    }

    @Test func dayListAndContentChangesPreserveReadingPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-day-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let names = (0..<36).map { JournalDate.today().adding(days: -2 * $0).pageName }
        for name in names {
            var page = store.page(named: name)
            page.blocks = (0..<4).map { Block(content: "Note \($0) on \(name).") }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let host = NSHostingView(rootView: JournalView().environmentObject(app)
            .environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle(_ count: Int = 10) async throws {
            for _ in 0..<count {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await settle()
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .seconds(1))
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        for _ in 0..<120 {
            if tables(in: host).contains(where: {
                ($0.delegate as? OutlineEditorController)?.pageName == names[20]
                    && $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }) { break }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 200))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(1)
        }
        var reading = try #require(tables(in: host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == names[20]
        })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: reading.convert(reading.rect(ofRow: 1), to: document).minY + 5))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let offset = reading.convert(reading.rect(ofRow: 1), to: document).minY - scroll.contentView.bounds.minY
        let readingY = scroll.contentView.bounds.minY
        for _ in 0..<3 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: readingY + 600))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: readingY))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            reading = try #require(tables(in: document).first {
                ($0.delegate as? OutlineEditorController)?.pageName == names[20]
            })
            #expect(abs(reading.convert(reading.rect(ofRow: 1), to: document).minY
                - scroll.contentView.bounds.minY - offset) < 1)
        }
        let insertedName = JournalDate.today().adding(days: -1).pageName
        var inserted = store.page(named: insertedName)
        inserted.blocks = [Block(content: "A newly imported day above the reading position.")]
        store.updatePage(inserted)
        try store.savePage(named: insertedName)
        app.dataVersion += 1
        try await settle()
        #expect(reading.window === window)
        #expect(abs(reading.convert(reading.rect(ofRow: 1), to: document).minY
            - scroll.contentView.bounds.minY - offset) < 1)
        // An empty past day leaves the feed after its index entry changes.
        inserted.blocks = []
        store.updatePage(inserted)
        try store.savePage(named: insertedName)
        app.dataVersion += 1
        try await settle()
        #expect(reading.window === window)
        #expect(abs(reading.convert(reading.rect(ofRow: 1), to: document).minY
            - scroll.contentView.bounds.minY - offset) < 1)

        let originalHeight = reading.bounds.height
        var changed = store.page(named: names[20])
        changed.blocks[2].content = String(repeating: "A longer entry wraps across many lines. ", count: 40)
        store.updatePage(changed)
        app.dataVersion += 1
        try await settle(60)
        #expect(reading.bounds.height > originalHeight + 100)
        let next = try #require(tables(in: host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == names[21]
        })
        #expect(next.convert(next.bounds, to: document).minY > reading.convert(reading.bounds, to: document).maxY)

        // The oldest unvisited days are shorter than the estimate. Resizing the
        // document must not apply AppKit's bottom correction a second time.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(40)
        let oldest = try #require(tables(in: document).first {
            ($0.delegate as? OutlineEditorController)?.pageName == names.last
        })
        #expect(oldest.convert(oldest.bounds, to: document).intersects(scroll.documentVisibleRect))
        #expect(abs(document.bounds.maxY + scroll.contentInsets.bottom - scroll.documentVisibleRect.maxY) < 1)
    }

    @Test func liveResizeDoesNotRefreshQueriesUntilDataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-query-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = try store.createPage(named: "Resize source")
        source.blocks = [Block(content: "Before resize #resize")]
        store.updatePage(source)
        try store.savePage(named: source.name)
        let day = JournalDate.today().adding(days: -1).pageName
        var journal = store.page(named: day)
        journal.blocks = [Block(content: "{{query #resize}}")]
        store.updatePage(journal)
        try store.savePage(named: day)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: JournalView()
            .environmentObject(app).environmentObject(nav))
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func renderedText(in view: NSView) -> String {
            ((view as? RenderedTextView)?.string ?? "")
                + view.subviews.map { renderedText(in: $0) }.joined()
        }
        try await settle()
        let table = try #require(tables(in: host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == day
        })
        #expect(renderedText(in: table).contains("Before resize"))

        // Change the query's answer without publishing a data update. A width
        // update alone must not rerun it during live resize.
        source.blocks[0].content = "After resize #resize"
        let stamp = GraphStore.stamp(of: store.fileURL(forPageNamed: source.name))
        try store.cache.indexPage(source, stamp: stamp)
        window.resizing = true
        for width: CGFloat in [680, 660, 640] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await settle()
            #expect(renderedText(in: table).contains("Before resize"))
            #expect(!renderedText(in: table).contains("After resize"))
        }
        // A data change still refreshes results, even when the width also changes.
        app.dataVersion += 1
        window.setContentSize(NSSize(width: 620, height: 450))
        try await settle()
        #expect(renderedText(in: table).contains("After resize"))
        window.resizing = false
        table.onLiveResizeEnd?()
        try await settle()
    }

    @Test(arguments: [0, 8])
    func fastUpwardScrollingReturnsToNewerDays(futureDays: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-scroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let today = JournalDate.today()
        for offset in 0..<730 {
            var doc = store.page(named: today.adding(days: futureDays - offset).pageName)
            doc.blocks = (0..<(4 + offset % 13)).map { index in
                Block(content: "Entry \(offset), block \(index). "
                    + String(repeating: "Daily notes with variable line wrapping. ",
                             count: (offset + index) % 9))
            }
            store.updatePage(doc)
            try store.savePage(named: doc.name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: JournalView()
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)

        func settle(_ frames: Int = 10) async throws {
            for _ in 0..<frames {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        var checkedAnchors = 0
        func scrollBy(_ distance: CGFloat) async throws {
            let y = max(0, scroll.documentVisibleRect.minY + distance)
            // Keep the paragraph at the requested viewport edge in place.
            // Its own wrapping can move later paragraphs farther down the screen.
            let anchor = distance < 0 ? tables(in: host).compactMap { table -> (String, Int, CGFloat, CGFloat)? in
                guard let controller = table.delegate as? OutlineEditorController else { return nil }
                for row in 0..<table.numberOfRows {
                    let rect = table.convert(table.rect(ofRow: row), to: document)
                    if rect.minY <= y, rect.maxY > y {
                        return (controller.pageName, row, rect.minY - y, rect.height)
                    }
                }
                return nil
            }.first : nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(distance < 0 ? 3 : 1)
            if let (page, row, offset, height) = anchor {
                checkedAnchors += 1
                let table = try #require(tables(in: host).first {
                    ($0.delegate as? OutlineEditorController)?.pageName == page
                })
                let actual = table.convert(table.rect(ofRow: row), to: document).minY
                    - scroll.documentVisibleRect.minY
                let newHeight = table.rect(ofRow: row).height
                if newHeight < height {
                    #expect(actual <= 0 && actual + newHeight > 0,
                            "The shortened reading paragraph disappeared on \(page)")
                } else {
                    #expect(abs(actual - offset) < 1,
                            "Remeasuring a preceding day moved the reading block on \(page)")
                }
            }
        }
        func newestVisibleDay() throws -> String {
            // Use document coordinates. An offscreen table's visibleRect can
            // remain nonempty while SwiftUI keeps its editor attached.
            let visible = tables(in: host).filter {
                $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }
            let days = visible.compactMap {
                ($0.delegate as? OutlineEditorController)?.pageName
            }
            return try #require(days.max())
        }

        // Let today's automatic caret reveal expire before moving the feed.
        try await settle(50)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        #expect(editor.window === window)
        #expect(editor.convert(editor.bounds, to: document).intersects(scroll.documentVisibleRect))
        window.makeFirstResponder(nil)
        if futureDays > 0 {
            // These future entries have not been measured at this width yet.
            for _ in 0..<12 { try await scrollBy(-150) }
            #expect(try newestVisibleDay() > today.pageName)
            #expect(checkedAnchors > 0)
        }
        for width: CGFloat in [700, 480] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await settle()
            for table in tables(in: host) {
                // Retained offscreen editors keep their width until approached.
                if table.convert(table.bounds, to: document).intersects(scroll.documentVisibleRect) {
                    #expect(table.bounds.width == scroll.contentSize.width - 40)
                }
            }
            for _ in 0..<80 { try await scrollBy(100) }
            try await settle()
            var previous = try newestVisibleDay()
            #expect(previous < today.adding(days: futureDays - 5).pageName)

            // Previously visited days have heights from the other width.
            window.setContentSize(NSSize(width: width == 700 ? 480 : 700, height: 450))
            try await settle()

            // Each burst requests 900 points toward newer days. A lazy height
            // correction must not move the reader to an older day instead.
            for _ in 0..<20 {
                for _ in 0..<6 { try await scrollBy(-150) }
                try await settle()
                let current = try newestVisibleDay()
                #expect(current >= previous,
                        "Upward scroll moved from \(previous) to \(current) at width \(width)")
                previous = current
                #expect(tables(in: host).count < 32, "The journal must keep loading days lazily")
                if scroll.documentVisibleRect.minY < 1 { break }
            }
            #expect(previous == today.adding(days: futureDays).pageName)
            #expect(scroll.documentVisibleRect.minY < 1)
        }

        // A scrollbar jump also leaves never-measured days above the viewport.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let checkedBeforeJump = checkedAnchors
        for _ in 0..<60 { try await scrollBy(-150) }
        #expect(checkedAnchors - checkedBeforeJump > 20)
    }
}
