import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct ResizeScrollAnchorTests {
    // GitHub's shared runners vary in CPU speed. Keep timing budgets local.
    private let checksCPULimits = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true"

    private final class ResizeWindow: NSWindow {
        var resizing = false {
            didSet {
                guard resizing != oldValue else { return }
                NotificationCenter.default.post(name: resizing
                    ? NSWindow.willStartLiveResizeNotification : NSWindow.didEndLiveResizeNotification,
                    object: self)
            }
        }
        override var inLiveResize: Bool { resizing || super.inLiveResize }
    }

    private final class ResizeScrollView: NSScrollView {
        var resizing = false
        override var inLiveResize: Bool { resizing || super.inLiveResize }
    }

    private final class SplitWidth: ObservableObject {
        @Published var main: CGFloat = 1_400
    }

    private struct SplitContent: View {
        @ObservedObject var width: SplitWidth
        var body: some View {
            HStack(spacing: 0) {
                JournalView().frame(width: width.main)
                RightSidebar()
            }
        }
    }

    private struct HintedOutline: View {
        @ObservedObject var width: SplitWidth
        var body: some View {
            ScrollView {
                OutlineEditorView(pageName: "Width hint", initialWidth: width.main)
                    .frame(width: 420)
            }
        }
    }

    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, T.self) }
    }

    private func cpuTime() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    @Test func journalOpensAboveToolbarInsetWithoutTakingFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-feed-origin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = store.page(named: JournalDate.today().pageName)
        page.blocks = [Block(content: "A day opened for reading.")]
        store.updatePage(page)
        for offset in 1..<12 {
            var previous = store.page(named: JournalDate.today().adding(days: -offset).pageName)
            previous.blocks = [Block(content: "An earlier entry.")]
            store.updatePage(previous)
            try store.savePage(named: previous.name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let host = NSHostingView(rootView: MainWindow().environmentObject(app)
            .environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Knopo Journal Origin Test"
        // Retain another main editor's focus so today's automatic reveal cannot
        // hide an incorrect initial scroll position.
        let focused = BlockEditorTextView.create()
        host.addSubview(focused)
        window.contentView = host
        window.makeFirstResponder(focused)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.firstResponder === focused)
        let scroll = try #require(descendants(host, OutlineTableView.self).first?.enclosingScrollView)
        #expect(scroll.contentInsets.top > 0)
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 1)
        // A feed that initially fits is also at its bottom. Growing it must
        // keep the reader at the top instead of following the new bottom.
        page.blocks = (0..<40).map { Block(content: "An imported entry \($0).") }
        store.updatePage(page)
        app.dataVersion += 1
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 1)
    }

    @Test(arguments: [false, true], [0, 90, 365, 730])
    func historyResizeKeepsWorkNearViewport(divider: Bool, depth: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-deep-resize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let names = (0..<800).map { JournalDate.today().adding(days: -$0).pageName }
        for (day, name) in names.enumerated() {
            var page = store.page(named: name)
            page.blocks = (0..<(4 + day % 9)).map {
                Block(content: "Day \(day), note \($0). A short sentence about the project and another reminder for tomorrow.")
            }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let split = SplitWidth()
        let content = divider ? AnyView(SplitContent(width: split)) : AnyView(JournalView())
        let host = NSHostingView(rootView: content.environmentObject(app).environmentObject(nav))
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 1_000),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Knopo Deep Resize Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func frame() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(2))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        for _ in 0..<20 { try await frame() }
        let scroll = try #require(descendants(host, OutlineTableView.self).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .seconds(1))
        var slowestScroll: Double = 0
        for _ in 0..<2_000 {
            if descendants(host, OutlineTableView.self).contains(where: {
                ($0.delegate as? OutlineEditorController)?.pageName == names[depth]
                    && $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }) { break }
            let start = cpuTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 700))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await frame()
            slowestScroll = max(slowestScroll, cpuTime() - start)
        }
        let reading = try #require(descendants(host, OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == names[depth]
        })
        scroll.contentView.scroll(to: NSPoint(x: 0, y:
            reading.convert(reading.rect(ofRow: 2), to: document).minY + 5 - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<20 { try await frame() }
        let offset = reading.convert(reading.rect(ofRow: 2), to: document).minY - scroll.contentView.bounds.minY
        // Retain identities so a deallocated table's address cannot hide a recreation.
        func accessibilityChildren(_ element: Any) -> [Any] {
            if let element = element as? NSAccessibilityProtocol { return element.accessibilityChildren() ?? [] }
            return (element as? NSObject)?.accessibilityAttributeValue(.children) as? [Any] ?? []
        }
        func walkAccessibility(_ element: Any) -> Int {
            let children = accessibilityChildren(element)
            return children.count + children.reduce(0) { $0 + walkAccessibility($1) }
        }
        #expect(walkAccessibility(document) < 1_000)
        #expect(descendants(host, OutlineTableView.self).count < 24)
        var seen: [ObjectIdentifier: OutlineTableView] = [:]
        var slowest: Double = 0
        var drift: CGFloat = 0
        let widths = Array(stride(from: 1_400, through: 320, by: -40))
            + Array(stride(from: 360, through: 1_400, by: 40))
        if divider { OutlineScrollAnchor.beginDividerResize(in: window) }
        else { window.resizing = true }
        for width in widths {
            let start = cpuTime()
            if divider { split.main = CGFloat(width) }
            else { window.setContentSize(NSSize(width: width, height: 1_000)) }
            try await frame()
            slowest = max(slowest, cpuTime() - start)
            #expect(reading.window === window, "The day being read must retain its editor")
            let current = reading.convert(reading.rect(ofRow: 2), to: document).minY - scroll.contentView.bounds.minY
            drift = max(drift, abs(current - offset))
            for table in descendants(host, OutlineTableView.self) { seen[ObjectIdentifier(table)] = table }
        }
        if divider { OutlineScrollAnchor.endDividerResize(in: window) }
        else {
            window.resizing = false
            for table in descendants(host, OutlineTableView.self) { table.onLiveResizeEnd?() }
        }
        for _ in 0..<20 { try await frame() }
        #expect(drift < 1, "Reading position drift during resize: \(drift)")
        #expect(abs(reading.convert(reading.rect(ofRow: 2), to: document).minY
            - scroll.contentView.bounds.minY - offset) < 1)
        #expect(seen.count < 24, "Resize constructed \(seen.count) day editors with only a few days visible")
        if checksCPULimits {
            #expect(slowestScroll < 0.200, "Slowest journal scroll frame used \(slowestScroll) seconds of main-thread CPU")
            #expect(slowest < 0.200, "Slowest deep journal resize frame used \(slowest) seconds of main-thread CPU")
        }
        print("Journal resize at \(depth) days (divider: \(divider)): \(seen.count) editors, peak CPU \(slowest * 1000) ms, drift \(drift)")
        // ⌘J must reveal the writing block even when today is offscreen.
        nav.goToJournal()
        for _ in 0..<40 { try await frame() }
        let today = try #require(descendants(host, OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == names[0]
        })
        #expect(today.convert(today.bounds, to: document).intersects(scroll.documentVisibleRect))
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        #expect(editor.isDescendant(of: today))
        #expect(!editor.visibleRect.isEmpty)
        #expect(nav.focusWritingIn == nil)
    }

    @Test func animatedWindowResizeFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-native-resize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for day in 0..<270 {
            let name = JournalDate.today().adding(days: -day).pageName
            var page = store.page(named: name)
            page.blocks = (0..<(4 + day % 9)).map {
                Block(content: "Day \(day), note \($0). A short sentence about the project and another reminder for tomorrow. [[Reference]]")
            }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        var reference = try store.createPage(named: "Reference")
        reference.blocks = (0..<100).map {
            Block(content: "Reference \($0). A short note with a second sentence to check wrapping across changing widths.")
        }
        store.updatePage(reference)
        let nav = Navigator(app: app)
        nav.rightPanes = [RightPane(target: .page(name: "Reference"))]
        let host = NSHostingView(rootView: MainWindow().environmentObject(app)
            .environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 1_328),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Knopo Native Resize Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        for width in [1_800, 900, 1_400] {
            let start = cpuTime()
            var frame = window.frame
            frame.size.width = CGFloat(width)
            window.setFrame(frame, display: true, animate: true)
            if checksCPULimits {
                #expect(cpuTime() - start < 1, "Animated resize consumed more than a second of CPU time")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let scroll = try #require(descendants(host, OutlineTableView.self).first?.enclosingScrollView)
        #expect(scroll.contentInsets.top > 0, "The journal must extend under the native toolbar")
        let document = try #require(scroll.documentView)
        let target = JournalDate.today().adding(days: -90).pageName
        func settle() async throws {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(16))
        }
        for _ in 0..<180 {
            if descendants(host, OutlineTableView.self).contains(where: {
                ($0.delegate as? OutlineEditorController)?.pageName == target
                    && $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }) { break }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 300))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
        }
        let reading = try #require(descendants(host, OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == target
        })
        scroll.contentView.scroll(to: NSPoint(x: 0, y:
            reading.convert(reading.rect(ofRow: 3), to: document).minY + 5 - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<20 { try await settle() }
        let offset = reading.convert(reading.rect(ofRow: 3), to: document).minY - scroll.contentView.bounds.minY
        try #require(reading.window === window)
        for width in [2_560, 1_280, 900, 1_800] {
            let start = cpuTime()
            var frame = window.frame
            frame.size.width = CGFloat(width)
            window.setFrame(frame, display: true, animate: true)
            if checksCPULimits {
                #expect(cpuTime() - start < 1, "Animated resize consumed more than a second of CPU time")
            }
            for _ in 0..<20 { try await settle() }
            #expect(reading.window === window, "Animated resize must retain the day being read")
            let current = reading.convert(reading.rect(ofRow: 3), to: document).minY - scroll.contentView.bounds.minY
            #expect(abs(current - offset) < 1, "Animated resize drift at width \(width): \(current - offset)")
        }
    }

    @Test func attachedOutlineUsesItsActualWidthWhenTheHintChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-width-hint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Width hint")
        page.blocks = (0..<20).map { _ in
            Block(content: String(repeating: "Words that wrap across the available width. ", count: 10))
        }
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let width = SplitWidth()
        width.main = 420
        let host = NSHostingView(rootView: HintedOutline(width: width)
            .environmentObject(app).environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<10 {
                window.layoutIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let table = try #require(descendants(host, OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        let height = table.rect(ofRow: 0).height
        width.main = 200
        try await settle()
        #expect(table.bounds.width == 420)
        #expect(table.rect(ofRow: 0).height == height)
        #expect(controller.tableView(table, heightOfRow: 0) == height)

        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        controller.invalidateWidthMeasurement()
        // Queue a scroll after the measurement but before its deferred restore.
        // A refresh that changes no heights must not consume this scroll.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
                scroll.reflectScrolledClipView(scroll.contentView)
                continuation.resume()
            }
        }
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - 300) < 1)
    }

    @Test func initialWidthSurvivesAttachmentProbes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-detached-width-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Detached width")
        page.blocks = [Block(content: String(repeating: "A paragraph that wraps at the available width. ", count: 10))]
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.initialLayoutWidth = 420
        let table = controller.tableView
        table.setFrameSize(NSSize(width: 100, height: 0))
        controller.present(pageName: page.name, zoom: nil)
        let height = controller.tableView(table, heightOfRow: 0)
        controller.invalidateWidthMeasurement()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.tableView(table, heightOfRow: 0) == height)
        #expect(table.rect(ofRow: 0).height == height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let content = DocumentView(frame: NSRect(x: 0, y: 0, width: 420, height: 2_000))
        window.contentView = scroll
        scroll.documentView = content
        table.frame.size.height = table.intrinsicContentSize.height
        content.addSubview(table)
        defer { window.contentView = nil }
        #expect(controller.tableView(table, heightOfRow: 0) == height)
        // A new lazy day can get a newer width hint before its first draw.
        controller.initialLayoutWidth = 200
        table.frame.size.width = 200
        table.viewWillDraw()
        #expect(table.rect(ofRow: 0).height > height)
        #expect(table.rect(ofRow: 0).height == controller.tableView(table, heightOfRow: 0))
    }

    @Test(arguments: [false, true])
    func longPageRevealWinsAndLiveMeasurementStaysNearTheViewport(divider: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-resize-reveal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Long page")
        page.blocks = (0..<1_000).map { index in
            Block(content: "Note \(index). " + String(repeating: "Words that wrap when the window narrows. ", count: 8))
        }
        store.updatePage(page)
        try store.savePage(named: page.name)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let target = page.blocks[700]
        nav.navigateToBlock(pageName: page.name, blockID: target.id, content: target.content, inSidebar: false)
        let host = NSHostingView(rootView: PageScreen(pageName: page.name)
            .environmentObject(app).environmentObject(nav))
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle(_ frames: Int = 12) async throws {
            for _ in 0..<frames {
                window.layoutIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let table = try #require(descendants(host, OutlineTableView.self).first)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 700)))
        // Expire the reveal before checking ordinary reading during resize.
        try await settle(110)
        let oldHeight = table.rect(ofRow: 0).height
        let readingRow = table.row(at: NSPoint(x: 0, y: table.visibleRect.minY))
        if divider { OutlineScrollAnchor.beginDividerResize(in: window) }
        else { window.resizing = true }
        var resizeCPU: Double = 0
        var largestHeightError: CGFloat = 0
        let widths = Array(stride(from: 680, through: 380, by: -30)) + [2_000, 380]
        let controller = try #require(table.delegate as? OutlineEditorController)
        for width in widths {
            let cpuStart = cpuTime()
            let readingHeight = table.rect(ofRow: readingRow).height
            window.setContentSize(NSSize(width: width, height: 500))
            window.layoutIfNeeded()
            #expect(table.rect(ofRow: readingRow).height == readingHeight,
                    "Row heights must not change recursively during window layout")
            try await settle(1)
            window.layoutIfNeeded()
            CATransaction.flush()
            let clip = try #require(table.enclosingScrollView?.contentView)
            var shown = clip.bounds
            let topInset = table.enclosingScrollView?.contentInsets.top ?? 0
            shown.origin.y += topInset
            shown.size.height -= topInset
            let viewport = table.convert(shown, from: clip)
            let visible = table.rows(in: viewport.intersection(table.bounds))
            if visible.location != NSNotFound {
                for index in visible.location..<NSMaxRange(visible) {
                    guard table.rect(ofRow: index).intersects(viewport) else { continue }
                    largestHeightError = max(largestHeightError,
                        abs(controller.tableView(table, heightOfRow: index) - table.rect(ofRow: index).height))
                }
            }
            resizeCPU += cpuTime() - cpuStart
            #expect(table.rect(ofRow: 0).height == oldHeight)
        }
        if checksCPULimits {
            #expect(resizeCPU < Double(widths.count) * 0.050, "Resize CPU time for \(widths.count) frames: \(resizeCPU)")
        }
        #expect(largestHeightError < 1, "Incorrect visible row heights during resize: \(largestHeightError)")
        if divider { OutlineScrollAnchor.endDividerResize(in: window) }
        else {
            window.resizing = false
            table.onLiveResizeEnd?()
        }
        try await settle()
        #expect(table.rect(ofRow: 0).height > oldHeight)
        #expect(table.row(at: NSPoint(x: 0, y: table.visibleRect.minY)) == readingRow)
        for row in 0..<table.numberOfRows {
            #expect(abs(table.rect(ofRow: row).height - controller.tableView(table, heightOfRow: row)) < 1)
        }

        let scroll = try #require(table.enclosingScrollView)
        let document = try #require(scroll.documentView)
        let nextY = scroll.contentView.bounds.minY + 100
        scroll.contentView.scroll(to: NSPoint(x: 0, y: nextY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - nextY) < 1)
        let targetRect = table.convert(table.rect(ofRow: 700), to: document)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: targetRect.maxY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let beforeZoom = table.rect(ofRow: 0).height
        window.setContentSize(NSSize(width: 2_000, height: 500))
        window.layoutIfNeeded()
        #expect(table.rect(ofRow: 0).height == beforeZoom, "Offscreen rows must not block a non-live layout pass")
        try await settle()
        let top = table.convert(scroll.contentView.bounds, from: scroll.contentView).minY
        #expect(table.row(at: NSPoint(x: 0, y: top)) == 700,
                "Widening must not scroll past the paragraph that became shorter")

        if divider {
            OutlineScrollAnchor.beginDividerResize(in: window)
            OutlineScrollAnchor.endDividerResize(in: window)
        } else {
            window.resizing = true
            window.resizing = false
        }
        try await settle()
        let afterEmptyDrag = scroll.contentView.bounds.minY + 100
        scroll.contentView.scroll(to: NSPoint(x: 0, y: afterEmptyDrag))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - afterEmptyDrag) < 1)

        let unchangedHeight = table.rect(ofRow: 700).height
        let partialRow = table.convert(table.rect(ofRow: 700), to: document).maxY - 4
        scroll.contentView.scroll(to: NSPoint(x: 0, y: partialRow))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        window.setContentSize(NSSize(width: 2_001, height: 500))
        try await settle()
        #expect(table.rect(ofRow: 700).height == unchangedHeight)
        #expect(abs(scroll.contentView.bounds.minY - partialRow) < 1,
                "A row that did not shrink must keep its partial-row offset")
    }

    @Test(arguments: [false, true], [false, true])
    func continuousResizeKeepsUnevenDaysAtTheReadingPosition(sidebar: Bool, fullWindow: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-continuous-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let names = (0..<180).map { JournalDate.today().adding(days: -$0).pageName }
        for (day, name) in names.enumerated() {
            var page = store.page(named: name)
            page.blocks = (0..<(4 + day % 9)).map { index in
                Block(content: "Day \(day), block \(index). "
                    + String(repeating: "Variable notes wrap into more lines. ", count: 1 + (day + index) % 2))
            }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = names.prefix(40).map { RightPane(target: .page(name: $0)) }
        let split = SplitWidth()
        split.main = sidebar ? 400 : 1_400
        let content = fullWindow ? AnyView(MainWindow()) : AnyView(SplitContent(width: split))
        let host = NSHostingView(rootView: content.environmentObject(app).environmentObject(nav))
        let initialWidth = fullWindow ? 1_800 : 1_400
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 1_800, height: 1_328),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Knopo Continuous Resize Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func frame() async throws {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(16))
        }
        for _ in 0..<65 { try await frame() }
        func outlines() -> [OutlineTableView] {
            descendants(host, OutlineTableView.self).filter {
                ($0.delegate as? OutlineEditorController)?.inPane == sidebar
            }
        }
        let scroll = try #require(outlines().first?.enclosingScrollView)
        let document = try #require(scroll.documentView)
        for _ in 0..<(sidebar ? 40 : 140) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + (sidebar ? 100 : 300)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await frame()
            if !sidebar, outlines().contains(where: {
                ($0.delegate as? OutlineEditorController)?.pageName == names[90]
                    && $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }) { break }
        }
        for _ in 0..<12 { try await frame() }
        let table = try #require(outlines().first {
            sidebar ? $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
                : ($0.delegate as? OutlineEditorController)?.pageName == names[90]
        })
        if !sidebar {
            let controller = try #require(table.delegate as? OutlineEditorController)
            #expect(controller.pageName <= names[89], "Must exercise three months of lazy journal history")
        }
        let row = min(3, table.numberOfRows - 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y:
            table.convert(table.rect(ofRow: row), to: document).minY + 5 - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<12 { try await frame() }
        let offset = table.convert(table.rect(ofRow: row), to: document).minY - scroll.contentView.bounds.minY
        var largestDrift: CGFloat = 0
        var largestHeightError: CGFloat = 0
        var heightErrorLocation = ""
        var driftWidths: [Int] = []
        // Match the divider's minimum pane widths. The window case also
        // exercises the sidebar shrinking below its preferred minimum.
        let minimumWidth = fullWindow ? 680 : (sidebar ? 280 : 320)
        let gestures = [Array(stride(from: initialWidth, through: minimumWidth, by: -16)),
                        Array(stride(from: minimumWidth, through: initialWidth + 160, by: 16))]
            + [1_000, minimumWidth, initialWidth + 160, minimumWidth, initialWidth].map { [$0] }
        let widths = gestures.flatMap { $0 }
        var slowestFrameCPU: Double = 0
        var drawingTime: Double = 0
        for gesture in gestures {
            if fullWindow { window.resizing = true }
            else { OutlineScrollAnchor.beginDividerResize(in: window) }
            for width in gesture {
                let cpuStart = cpuTime()
                if fullWindow { window.setContentSize(NSSize(width: width, height: 1_328)) }
                else { split.main = CGFloat(sidebar ? 1_800 - width : width) }
                window.layoutIfNeeded()
                // Run queued measurements between layout and the next frame,
                // as the native event loop does during a resize.
                try await Task.sleep(for: .milliseconds(1))
                window.layoutIfNeeded()
                window.displayIfNeeded()
                // Flush the display transaction so assertions inspect the drawn frame.
                CATransaction.flush()
                let current = table.convert(table.rect(ofRow: row), to: document).minY - scroll.contentView.bounds.minY
                largestDrift = max(largestDrift, abs(current - offset))
                if abs(current - offset) >= 1 {
                    driftWidths.append(width)
                }
                for visible in outlines() {
                    var shown = scroll.contentView.bounds
                    shown.origin.y += scroll.contentInsets.top
                    shown.size.height -= scroll.contentInsets.top
                    let viewport = visible.convert(shown, from: scroll.contentView)
                    guard viewport.intersects(visible.bounds) else { continue }
                    let range = visible.rows(in: viewport.intersection(visible.bounds))
                    guard range.location != NSNotFound,
                          let controller = visible.delegate as? OutlineEditorController else { continue }
                    for index in range.location..<NSMaxRange(range) {
                        guard visible.rect(ofRow: index).intersects(viewport) else { continue }
                        let error = controller.tableView(visible, heightOfRow: index)
                            - visible.rect(ofRow: index).height
                        if abs(error) > largestHeightError {
                            largestHeightError = abs(error)
                            heightErrorLocation = "width \(width), page \(controller.pageName), row \(index), error \(error)"
                        }
                    }
                }
                let frameCPU = cpuTime() - cpuStart
                drawingTime += frameCPU
                slowestFrameCPU = max(slowestFrameCPU, frameCPU)
                try await Task.sleep(for: .milliseconds(16))
            }
            if fullWindow {
                window.resizing = false
                for outline in descendants(host, OutlineTableView.self) { outline.onLiveResizeEnd?() }
            } else {
                OutlineScrollAnchor.endDividerResize(in: window)
            }
            for _ in 0..<20 { try await frame() }
            let settled = table.convert(table.rect(ofRow: row), to: document).minY - scroll.contentView.bounds.minY
            #expect(abs(settled - offset) < 1, "Drift after gesture ending at \(gesture.last!): \(settled - offset), attached: \(table.window != nil)")
        }
        if checksCPULimits {
            // CPU time excludes display-server waits and scheduler delays.
            #expect(slowestFrameCPU < 0.200, "Slowest resize frame CPU time: \(slowestFrameCPU)")
            #expect(drawingTime < Double(widths.count) * 0.050, "Resize CPU time: \(drawingTime) for \(widths.count) frames")
        }
        let finalOffset = table.convert(table.rect(ofRow: row), to: document).minY - scroll.contentView.bounds.minY
        #expect(abs(finalOffset - offset) < 1, "Final drift: \(finalOffset - offset)")
        #expect(largestDrift < 1, "Drift during drag: \(largestDrift), widths: \(driftWidths)")
        #expect(largestHeightError < 1, "Incorrect visible row heights during drag: \(largestHeightError), \(heightErrorLocation)")

        if fullWindow {
            window.setContentSize(NSSize(width: 2_560, height: 1_328))
            for _ in 0..<20 {
                window.layoutIfNeeded()
                CATransaction.flush()
                try await frame()
            }
            let zoomedOffset = table.convert(table.rect(ofRow: row), to: document).minY - scroll.contentView.bounds.minY
            #expect(table.window === window)
            #expect(abs(zoomedOffset - offset) < 1, "Window zoom drift: \(zoomedOffset - offset)")
        }
        // Previously offscreen days must get their deferred measurements
        // when the reader scrolls back to them.
        let beforeScroll = scroll.contentView.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: beforeScroll - 1_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        let reading = outlines().compactMap { outline -> (OutlineTableView, Int, String)? in
            let top = scroll.contentView.bounds.minY + scroll.contentInsets.top
            let point = outline.convert(NSPoint(x: 0, y: top), from: document)
            guard point.y >= 0, point.y < outline.bounds.height else { return nil }
            let index = outline.row(at: NSPoint(x: 0, y: point.y))
            guard index >= 0, let controller = outline.delegate as? OutlineEditorController else { return nil }
            return (outline, index, controller.pageName)
        }.first
        if let (outline, index, _) = reading {
            let top = outline.convert(outline.rect(ofRow: index), to: document).minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top + 5 - scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for _ in 0..<20 { try await frame() }
        if let (_, index, readingPage) = reading {
            let outline = try #require(outlines().first {
                ($0.delegate as? OutlineEditorController)?.pageName == readingPage
            })
            let top = outline.convert(outline.rect(ofRow: index), to: document).minY
            #expect(abs(top - scroll.contentView.bounds.minY - scroll.contentInsets.top + 5) < 1,
                    "Deferred row measurement must keep the text at the reading position")
        } else {
            #expect(scroll.contentView.bounds.minY < beforeScroll - 500)
        }
        for visible in outlines() {
            let viewport = visible.convert(scroll.contentView.bounds, from: scroll.contentView)
            guard viewport.intersects(visible.bounds) else { continue }
            let range = visible.rows(in: viewport.intersection(visible.bounds))
            guard range.location != NSNotFound,
                  let controller = visible.delegate as? OutlineEditorController else { continue }
            for index in range.location..<NSMaxRange(range) {
                guard visible.rect(ofRow: index).intersects(viewport) else { continue }
                #expect(abs(visible.rect(ofRow: index).height
                    - controller.tableView(visible, heightOfRow: index)) < 1)
            }
        }

    }

    @Test(arguments: [false, true], [false, true])
    func wrappedRowsKeepTheirPositionAcrossWidthChanges(sidebar: Bool, live: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-scroll-anchor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let names = (0..<12).map { JournalDate.today().adding(days: -$0).pageName }
        for name in names {
            var page = store.page(named: name)
            page.blocks = (0..<40).map { index in
                Block(content: "Block \(index). " + String(repeating: "Notes that wrap when resized. ", count: 8))
            }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = names.prefix(3).map { RightPane(target: .page(name: $0)) }
        let content = sidebar ? AnyView(RightSidebar()) : AnyView(JournalView())
        let host = NSHostingView(rootView: content.environmentObject(app).environmentObject(nav))
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle(_ frames: Int = 12) async throws {
            for _ in 0..<frames {
                window.layoutIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle(50)
        window.makeFirstResponder(nil)
        let scroll = try #require(descendants(host, NSScrollView.self).first)
        let document = try #require(scroll.documentView)
        // Walk into a later day so lazy journal layout has placed its outline.
        for _ in 0..<45 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentVisibleRect.minY + 120))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(1)
        }
        try await settle()
        let table = try #require(descendants(host, OutlineTableView.self).first {
            $0.convert($0.bounds, to: document).contains(
                NSPoint(x: 60, y: scroll.documentVisibleRect.minY + 150))
        })
        let row = 20
        let rect = table.convert(table.rect(ofRow: row), to: document)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let offset = table.convert(table.rect(ofRow: row), to: document).minY
            - scroll.documentVisibleRect.minY
        for width: CGFloat in [460, 820, 540, 700] {
            window.resizing = live
            window.setContentSize(NSSize(width: width, height: 450))
            try await settle()
            window.resizing = false
            for outline in descendants(host, OutlineTableView.self) { outline.onLiveResizeEnd?() }
            try await settle()
            let after = table.convert(table.rect(ofRow: row), to: document).minY
                - scroll.documentVisibleRect.minY
            #expect(abs(after - offset) < 1, "Row moved by \(after - offset) at width \(width)")
        }
        let y = scroll.documentVisibleRect.minY + 200
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        #expect(abs(scroll.documentVisibleRect.minY - y) < 1)
    }

    @Test func viewOnlyResizePreservesContentBelowTheOutline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-divider-anchor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Resize")
        page.blocks = (0..<30).map { index in
            Block(content: "Block \(index). " + String(repeating: "Wrapped notes. ", count: 15))
        }
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.inPane = true
        controller.applyPaneRole()
        let table = controller.tableView
        table.frame.size.width = 600
        controller.present(pageName: page.name, zoom: nil)
        let scroll = ResizeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = DocumentView()
        scroll.documentView = document
        document.addSubview(table)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        var precedingHeight: CGFloat = 0
        func settle() async throws {
            for _ in 0..<8 {
                table.frame = NSRect(x: 0, y: precedingHeight, width: scroll.contentSize.width,
                                     height: table.intrinsicContentSize.height)
                document.frame.size = NSSize(width: scroll.contentSize.width, height: table.frame.maxY + 10_000)
                window.layoutIfNeeded()
                table.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let beforeResize = table.rect(ofRow: 0).height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.frame.maxY + 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.resizing = true
        window.setContentSize(NSSize(width: 360, height: 400))
        try await settle()
        #expect(table.rect(ofRow: 0).height == beforeResize)
        #expect(abs(scroll.contentView.bounds.minY - table.frame.maxY - 150) < 1)

        // An earlier pane finishes its deferred measurement during the same drag.
        precedingHeight = 240
        OutlineScrollAnchor.preserve(beforeResizing: table)
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - table.frame.maxY - 150) < 1)

        scroll.resizing = false
        table.onLiveResizeEnd?()
        // A split-view drag ends without window resize notifications.
        for view in scroll.subviews { view.viewDidEndLiveResize() }
        try await settle()
        #expect(table.rect(ofRow: 0).height > beforeResize)
        #expect(abs(scroll.contentView.bounds.minY - table.frame.maxY - 150) < 1)
        let afterDrag = scroll.contentView.bounds.minY + 80
        scroll.contentView.scroll(to: NSPoint(x: 0, y: afterDrag))
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - afterDrag) < 1)

        // Match the toolbar overlap without SwiftUI managing the inset itself.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets.top = 52
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -52))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        try #require(abs(scroll.contentView.bounds.minY + 52) < 1)
        window.setContentSize(NSSize(width: 600, height: 400))
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY + 52) < 1)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        try await settle()
        let oldHeight = table.rect(ofRow: 0).height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        window.setContentSize(NSSize(width: 360, height: 400))
        table.frame.size.width = scroll.contentSize.width
        var scrolledY: CGFloat = 0
        // A continued scroll arrives after measurement captures a new anchor.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                scrolledY = scroll.contentView.bounds.minY + 80
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scrolledY))
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                continuation.resume()
            }
        }
        #expect(table.rect(ofRow: 0).height > oldHeight)
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY - scrolledY) < 1)
    }
}
