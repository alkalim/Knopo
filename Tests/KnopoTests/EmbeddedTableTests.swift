import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Embedded tables use the ordinary table renderer, shifted past the generated
/// row's bullet and fitted inside the embed region.
@MainActor
@Suite struct EmbeddedTableTests {

    @Test(arguments: [false, true])
    func gridsFollowTextBandsAndStayClearOfFollowingBlocks(hostProse: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-grid-bands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        var page = store.page(named: "Tables")
        page.blocks = [Block(content: source), Block(content: "Between tables"),
                       Block(content: source, properties: [BlockProperty(key: "table-width", value: "min")]),
                       Block(content: "After tables")]
        store.updatePage(page)
        try store.savePage(named: "Tables")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        let host = hostProse ? "Before embed\n{{embed [[Tables]]}}\nAfter embed"
            : "{{embed [[Tables]]}}"
        let rendered = BlockRenderer.render(content: host, context: .init(
            journalDateFormat: .default, resolveEmbed: { target in
                controller.renderEmbed(target, contentWidth: 600)
            }))
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        view.textStorage?.setAttributedString(rendered)
        let layout = try #require(view.textLayoutManager)
        let manager = try #require(layout.textContentManager)
        layout.ensureLayout(for: layout.documentRange)
        let grids = view.tableGridRects()
        try #require(grids.count == 2)
        #expect(grids[0].width > grids[1].width * 2) // table-width:: min
        let ns = rendered.string as NSString
        var bands: [(offset: Int, rect: CGRect)] = []
        layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let offset = manager.offset(from: manager.documentRange.location,
                                        to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                bands.append((offset, line.typographicBounds.offsetBy(
                    dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                    dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)))
            }
            return true
        }
        var tableRanges: [NSRange] = []
        rendered.enumerateAttribute(BlockRenderer.tableKey,
                                    in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if value != nil { tableRanges.append(range) }
        }
        try #require(tableRanges.count == 2)
        for (index, range) in tableRanges.enumerated() {
            let headerStart = ns.paragraphRange(for: NSRange(location: range.location, length: 0)).location
            let headerIndex = try #require(bands.firstIndex { $0.offset == headerStart })
            let header = bands[headerIndex].rect
            let row = bands[headerIndex + 1].rect
            #expect(abs(grids[index].minY - (header.minY - BlockRenderer.tableRowPad)) < 0.01)
            #expect(abs(grids[index].maxY - (row.maxY + BlockRenderer.tableRowPad + 1)) < 0.01)
            #expect(grids[index].maxY <= bands[headerIndex + 2].rect.minY)
            for band in bands[headerIndex...headerIndex + 1] {
                let style = try #require(rendered.attribute(
                    .paragraphStyle, at: band.offset, effectiveRange: nil) as? NSParagraphStyle)
                #expect(style.paragraphSpacingBefore == BlockRenderer.tableRowPad)
                #expect(style.paragraphSpacing == BlockRenderer.tableRowPad)
            }
        }
    }

    @Test func embeddedTableRefitsAfterResizing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-embed-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = store.page(named: "Source")
        source.blocks = [Block(content: "| A | B |\n| --- | --- |\n| one | two |")]
        store.updatePage(source)
        try store.savePage(named: "Source")
        var host = store.page(named: "Host")
        host.blocks = [Block(content: "{{embed [[Source]]}}")]
        store.updatePage(host)
        try store.savePage(named: "Host")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.inPane = true
        let table = controller.tableView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = content
        content.addSubview(table)
        defer { window.contentView = nil }
        table.frame.size.width = 800
        controller.present(pageName: "Host", zoom: nil)

        func textView(in view: NSView) -> RenderedTextView? {
            if let text = view as? RenderedTextView { return text }
            return view.subviews.compactMap { textView(in: $0) }.first
        }
        func renderedText() throws -> NSAttributedString {
            let cell = try #require(controller.tableView(
                table, viewFor: table.tableColumns.first, row: 0))
            return try #require(textView(in: cell)?.attributedString())
        }
        func rightEdge() throws -> CGFloat {
            let text = try renderedText()
            var geometry: BlockRenderer.TableGeometry?
            text.enumerateAttribute(BlockRenderer.tableKey,
                                    in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let value = value as? BlockRenderer.TableGeometry { geometry = value }
            }
            return try #require(geometry?.columnEdges.last)
        }
        let original = try rightEdge()
        table.frame.size.width = 450
        table.onWidthChange?()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let resized = try rightEdge()
        #expect(abs(original - resized - 350) < 0.5)
        #expect(resized < OutlineRowCell.contentWidth(forDepth: 0, rowWidth: 450))

        source.blocks[0].content = "| A | B |\n| --- | --- |\n| changed | two |"
        store.updatePage(source)
        controller.invalidateWidthMeasurement()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // A width check must keep the existing render when its width matches.
        #expect(try renderedText().string.contains("one"))
        controller.present(pageName: "Host", zoom: nil)
        #expect(try renderedText().string.contains("changed"))
    }

    @Test(arguments: [CGFloat(420), 700], ["block", "page", "nested", "child"])
    func embeddedTableRendersAsAFittedGrid(width: CGFloat, kind: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-embedded-table-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let id = UUID()
        var source = store.page(named: "Source")
        let tableSource = """
            | ID | Project | Status | Updated |
            | ---: | :--- | :--- | :--- |
            | 101 | Website Redesign | In Progress | 2026-09-22 |
            | 102 | Mobile App v2 | Review | 2026-09-21 |
            | 110 | Performance Testing | Planned | 2026-09-26 |
            """
        source.blocks = [Block(
            id: id,
            content: tableSource,
            properties: [BlockProperty(key: "id", value: id.uuidString.lowercased())]
        )]
        store.updatePage(source)
        try store.savePage(named: "Source")
        var container = store.page(named: "Container")
        container.blocks = kind == "child"
            ? [Block(content: "Parent", children: source.blocks)]
            : [Block(content: "Intro\n{{embed [[Source]]}}")]
        store.updatePage(container)
        try store.savePage(named: "Container")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))

        let target: EmbedTarget = kind == "block" ? .block(id)
            : .page(kind == "page" ? "Source" : "Container")
        // Run through the host renderer too, as a real outline row does.
        let rendered = BlockRenderer.render(content: "{{embed [[Target]]}}", context: .init(
            journalDateFormat: .default, resolveEmbed: { _ in
                controller.renderEmbed(target, contentWidth: width)
            }))
        #expect(!rendered.string.contains("| ---"))
        #expect(rendered.string.contains("\tID\tProject"))

        var tables: [(NSRange, BlockRenderer.TableGeometry)] = []
        rendered.enumerateAttribute(
            BlockRenderer.tableKey,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            if let geometry = value as? BlockRenderer.TableGeometry {
                tables.append((range, geometry))
            }
        }
        let table = try #require(tables.first)
        #expect(table.0.location > 0) // the generated bullet precedes the table
        #expect(table.1.rowCount == 4)
        #expect((table.1.columnEdges.first ?? 0) > 0)
        #expect((table.1.columnEdges.last ?? .greatestFiniteMagnitude) < width)

        // Check the actual TextKit positions, not just the presence of a grid.
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(rendered)
        let layout = try #require(view.textLayoutManager)
        let manager = try #require(layout.textContentManager)
        layout.ensureLayout(for: layout.documentRange)
        let ns = rendered.string as NSString
        let grid = try #require(view.tableGridRects().first)
        let background = try #require(view.embedRegionRect())
        // Every shape ends with this table. The background must stop at its rule.
        #expect(abs(background.maxY - grid.maxY) < 0.01)
        if kind == "block" || kind == "page" {
            #expect(abs(background.minY - grid.minY) < 0.01)
        }
        let origin = try #require(table.1.columnEdges.first)
        let tableWidth = try #require(table.1.columnEdges.last) - origin
        let plain = BlockRenderer.render(content: tableSource, context: .init(
            journalDateFormat: .default, contentWidth: tableWidth))
        var plainOffset = 0
        var rowStart = table.0.location
        for row in ns.substring(with: table.0).components(separatedBy: "\n") {
            let style = try #require(rendered.attribute(
                .paragraphStyle, at: rowStart, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.lineSpacing == 0)
            let plainStyle = try #require(plain.attribute(
                .paragraphStyle, at: plainOffset, effectiveRange: nil) as? NSParagraphStyle)
            // The first paragraph also has tabs for the generated marker.
            let cellTabs = style.tabStops.filter { $0.location > origin }
            #expect(cellTabs.count == plainStyle.tabStops.count)
            for (actual, expected) in zip(cellTabs, plainStyle.tabStops) {
                #expect(abs(actual.location - expected.location - origin) < 0.5)
            }
            var offset = rowStart + 1 // each cell starts after a tab
            for (column, cell) in row.components(separatedBy: "\t").dropFirst().enumerated() {
                let start = try #require(manager.location(
                    manager.documentRange.location, offsetBy: offset))
                let end = try #require(manager.location(start, offsetBy: (cell as NSString).length))
                let range = try #require(NSTextRange(location: start, end: end))
                var frames: [CGRect] = []
                layout.enumerateTextSegments(in: range, type: .standard, options: []) {
                    _, frame, _, _ in
                    if frame.width > 0, !frames.contains(frame) { frames.append(frame) }
                    return true
                }
                let frame = try #require(frames.first)
                #expect(frames.count == 1, "Cell \(cell): \(frames)")
                #expect(frame.minX >= table.1.columnEdges[column] - 0.5)
                #expect(frame.maxX <= table.1.columnEdges[column + 1] + 0.5)
                #expect(abs(frame.minX - cellTabs[column].location) < 1)
                offset += (cell as NSString).length + 1
            }
            rowStart += (row as NSString).length + 1
            plainOffset += (row as NSString).length + 1
        }
    }
}
