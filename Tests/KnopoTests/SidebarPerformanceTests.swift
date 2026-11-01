import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarPerformanceTests {
    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func paneWidthAccountsForScrollbar(style: NSScroller.Style) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = style
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 20_000))
        scroll.tile()
        #expect(RightSidebar.outlineWidth(in: scroll.frame.size, scrollerStyle: style)
            == scroll.contentSize.width - 60)
    }

    @Test func initialWidthMatchesScrollContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-scroller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Long page")
        page.blocks = (0..<400).map { Block(content: "Block \($0): enough text to wrap in the sidebar.") }
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = [RightPane(target: .page(name: page.name))]
        let host = NSHostingView(rootView: RightSidebar().environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func tables(_ view: NSView) -> [OutlineTableView] {
            ((view as? OutlineTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
        }
        let table = try #require(tables(host).first)
        let scroll = try #require(table.enclosingScrollView)
        let controller = try #require(table.delegate as? OutlineEditorController)
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        #expect(controller.initialLayoutWidth == table.bounds.width)
        #expect(table.bounds.width == scroll.contentSize.width - 60)
    }

    private final class ScrollRequest: ObservableObject {
        @Published var pane = 0
    }

    @Test func scrollingUpAcrossEarlierPanesPreservesVisibleTextPosition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-anchor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for i in 0..<10 {
            var doc = try store.createPage(named: "Pane \(i)")
            doc.blocks = (0..<400).map { Block(content: "Pane \(i) block \($0): enough text to wrap across a narrow sidebar.") }
            store.updatePage(doc)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = (0..<10).map { RightPane(target: .page(name: "Pane \($0)")) }
        let request = ScrollRequest()
        let host = NSHostingView(rootView: ScrollViewReader { proxy in
            RightSidebar().environmentObject(app).environmentObject(nav)
                .onReceive(request.$pane) {
                    proxy.scrollTo(NavTarget.page(name: "Pane \($0)"), anchor: .top)
                }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<8 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func tables(_ view: NSView) -> [OutlineTableView] {
            ((view as? OutlineTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
        }
        try await settle()
        request.pane = 7
        try await settle()
        let table = try #require(tables(host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == "Pane 7"
        })
        let scroll = try #require(table.enclosingScrollView)
        let clip = scroll.contentView
        #expect(tables(host).count == 10)
        try #require(!table.visibleRect.intersection(table.bounds).isEmpty)
        let height = try #require(scroll.documentView).frame.height
        for _ in 0..<6 {
            let origin = clip.bounds.origin
            clip.scroll(to: NSPoint(x: origin.x, y: origin.y - 100))
            scroll.reflectScrolledClipView(clip)
            let before = table.convert(.zero, to: clip).y - clip.bounds.minY
            try await settle()
            let after = table.convert(.zero, to: clip).y - clip.bounds.minY
            #expect(abs(after - before) < 2)
            #expect(scroll.documentView?.frame.height == height)
        }
    }

    @Test func longPanesKeepRowViewsBoundedWhileScrollingAndResizing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for i in 0..<5 {
            var doc = try store.createPage(named: "Pane \(i)")
            doc.blocks = (0..<400).map {
                Block(content: "Block \($0): some **formatted text** with a [[Link]] and a #tag, and enough words to wrap in a sidebar.")
            }
            store.updatePage(doc)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = (0..<5).map { RightPane(target: .page(name: "Pane \($0)")) }
        let request = ScrollRequest()
        let host = NSHostingView(rootView: ScrollViewReader { proxy in
            RightSidebar().environmentObject(app).environmentObject(nav)
                .onReceive(request.$pane) { proxy.scrollTo(NavTarget.page(name: "Pane \($0)"), anchor: .top) }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async throws {
            for _ in 0..<8 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, T.self) }
        }
        try await settle()
        func checkRows(_ label: String) throws {
            let tables = descendants(host, OutlineTableView.self)
            try #require(!tables.isEmpty && tables.count <= 5)
            #expect(descendants(host, OutlineRowCell.self).count < 100, "\(label)")
            for table in tables {
                // Allow retained cells and a generous prefetch margin, but
                // never a full 400-row page for this 700-point viewport.
                #expect(descendants(table, OutlineRowCell.self).count < 100, "\(label)")
                #expect(table.rows(in: table.bounds).length == 400)
                let visible = table.rows(in: table.visibleRect.intersection(table.bounds))
                if visible.location != NSNotFound {
                    for row in visible.location..<NSMaxRange(visible) {
                        #expect(table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil {
                print("SIDEBAR \(label): \(tables.count) tables, \(descendants(host, OutlineRowCell.self).count) cells")
            }
        }
        // AppKit's row and cell proxies still implement the legacy API.
        func accessibilityChildren(_ element: Any) -> [Any] {
            if let element = element as? NSAccessibilityProtocol {
                return element.accessibilityChildren() ?? []
            }
            return (element as? NSObject)?.accessibilityAttributeValue(.children) as? [Any] ?? []
        }
        func walkAccessibility(_ element: Any) -> [Any] {
            let children = accessibilityChildren(element)
            return children + children.flatMap { walkAccessibility($0) }
        }
        func checkAccessibility() throws {
            for table in descendants(host, OutlineTableView.self) {
                #expect((table as NSAccessibilityProtocol).accessibilityRows()?.count == 400)
                let elements = walkAccessibility(table)
                try #require(elements.count < 300)
                if let editor = window.firstResponder as? BlockEditorTextView,
                   editor.isDescendant(of: table) {
                    #expect(elements.contains { ($0 as AnyObject) === editor })
                }
            }
            // Merely reading the child tree must not construct offscreen cells.
            try checkRows("after accessibility scan")
        }
        try checkRows("initial")
        #expect(descendants(host, OutlineTableView.self).count == 5)
        try checkAccessibility()
        let firstTable = try #require(descendants(host, OutlineTableView.self).first)
        for i in [1, 2, 3, 4, 0] {
            request.pane = i
            try await settle()
            #expect(firstTable.visibleRect.intersection(firstTable.bounds).isEmpty == (i != 0))
            try checkRows("scroll \(i)")
            try checkAccessibility()
        }
        #expect(descendants(host, OutlineTableView.self).count == 5)
        let table = try #require(descendants(host, OutlineTableView.self).first {
            !$0.visibleRect.intersection($0.bounds).isEmpty
        })
        let controller = try #require(table.delegate as? OutlineEditorController)
        let firstBlock = app.document(for: "Pane 0").blocks[0]
        let selection = NSRange(location: 9, length: 4)
        controller.focusBlock(firstBlock.id, selection: selection)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        defer { controller.endEditing() }
        try await settle()
        let editorCell = try #require(editor.superview)
        // Move the entire edited pane outside the shared viewport.
        request.pane = 2
        try await settle()
        #expect(table.visibleRect.intersection(table.bounds).isEmpty)
        #expect(editor.superview === editorCell)
        #expect(editor.window === window)
        #expect(window.firstResponder === editor)
        try checkRows("edited pane offscreen")
        try checkAccessibility()

        window.setContentSize(NSSize(width: 500, height: 700))
        try await settle()
        #expect(table.visibleRect.intersection(table.bounds).isEmpty)
        #expect(editor.superview === editorCell)
        #expect(editor.window === window)
        #expect(window.firstResponder === editor)
        try checkRows("resized with edited pane offscreen")
        try checkAccessibility()

        request.pane = 0
        try await settle()
        #expect(!table.visibleRect.intersection(table.bounds).isEmpty)
        #expect(editor.superview === editorCell)
        #expect(editor.window === window)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string == firstBlock.content)
        try checkRows("returned to edited pane")
        try checkAccessibility()

        // Explicit offscreen access must still work for focus and navigation.
        let accessibleRows = try #require((table as NSAccessibilityProtocol).accessibilityRows())
        let offscreenContent = walkAccessibility(accessibleRows[350])
        #expect(offscreenContent.contains {
            ($0 as? NSTextView)?.string.contains("Block 350:") == true
        })
        #expect(table.view(atColumn: 0, row: 350, makeIfNecessary: false) is OutlineRowCell)
    }
}
