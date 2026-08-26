import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Table layout (SPEC §5.2): cells sit on per-row tab stops and the grid is
/// drawn from the geometry attribute, so these check the shape of what the
/// renderer emits — one line per row, a stop per column, alignment in the stops.
@MainActor
@Suite struct BlockRendererTableTests {

    private let source = """
        | Name | Qty |
        | --- | --- |
        | Apples | 3 |
        | Pears | 12 |
        """

    private func render(_ content: String, tables: Bool = true) -> NSAttributedString {
        BlockRenderer.render(content: content,
                             context: BlockRenderer.Context(
                                journalDateFormat: .default, tables: tables))
    }

    private func tabStops(_ rendered: NSAttributedString, line: Int) -> [CGFloat] {
        let paragraphs = rendered.string.components(separatedBy: "\n")
        var offset = 0
        for (index, paragraph) in paragraphs.enumerated() {
            if index == line {
                let style = rendered.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
                    as? NSParagraphStyle
                return style?.tabStops.map(\.location) ?? []
            }
            offset += (paragraph as NSString).length + 1
        }
        return []
    }

    @Test func rendersOneLinePerRowWithATabPerCell() {
        let rendered = render(source)
        let lines = rendered.string.components(separatedBy: "\n")
        #expect(lines.count == 3) // header + two rows; the delimiter row is structure
        #expect(lines[0] == "\tName\tQty")
        #expect(lines[2] == "\tPears\t12")
    }

    @Test func carriesColumnGeometryForTheGrid() throws {
        let rendered = render(source)
        let geometry = try #require(
            rendered.attribute(BlockRenderer.tableKey, at: 0, effectiveRange: nil)
                as? BlockRenderer.TableGeometry)
        // One edge per column boundary, outer borders included, left to right.
        try #require(geometry.columnEdges.count == 3)
        #expect(geometry.columnEdges[0] == 0)
        #expect(geometry.columnEdges == geometry.columnEdges.sorted())
        #expect(Set(geometry.columnEdges).count == 3)
        // Every cell's stop falls inside the table.
        for line in 0..<3 {
            for stop in tabStops(rendered, line: line) {
                #expect(stop > geometry.columnEdges[0])
                #expect(stop < geometry.columnEdges[2])
            }
        }
    }

    /// Rows abut so the drawn grid reads as one figure — a table takes none of
    /// the inter-line spacing other multi-line blocks get.
    @Test func rowsTakeNoInterlineSpacing() throws {
        let style = try #require(render(source).attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineSpacing == 0)
        #expect(style.maximumLineHeight > 0) // still pinned, like every block
    }

    @Test func headerCellsAreEmphasized() throws {
        let rendered = render(source)
        let headerFont = try #require(
            rendered.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        let bodyRow = (rendered.string as NSString).range(of: "Apples")
        let bodyFont = try #require(
            rendered.attribute(.font, at: bodyRow.location, effectiveRange: nil) as? NSFont)
        #expect(headerFont != bodyFont)
    }

    /// Alignment is baked into each row's tab stops (computed from the cell's own
    /// measured width), so a right-aligned short cell starts further right than
    /// the same cell left-aligned.
    @Test func alignmentShiftsTheCellsStop() throws {
        func stopsOfNarrowRow(_ delimiter: String) throws -> [CGFloat] {
            let rendered = render("""
                | wide column here | wide column here |
                \(delimiter)
                | x | y |
                """)
            let stops = tabStops(rendered, line: 1) // line 0 is the header
            try #require(stops.count == 2)
            return stops
        }
        let left = try stopsOfNarrowRow("| :--- | :--- |")
        let center = try stopsOfNarrowRow("| :--- | :---: |")
        let right = try stopsOfNarrowRow("| :--- | ---: |")
        // Column 0 is left-aligned in all three: same stop.
        #expect(left[0] == center[0])
        #expect(left[0] == right[0])
        // Column 1 moves right as alignment goes left → center → right.
        #expect(left[1] < center[1])
        #expect(center[1] < right[1])
    }

    /// A cell past the column cap tail-truncates: v1 doesn't wrap inside a cell.
    @Test func overlongCellTruncatesWithAnEllipsis() {
        let long = String(repeating: "long cell text ", count: 40)
        let rendered = render("| a | b |\n| --- | --- |\n| \(long) | ok |")
        #expect(rendered.string.contains("…"))
        #expect(!rendered.string.contains(long))
        #expect(rendered.string.hasSuffix("ok"))
    }

    /// Cells render through the ordinary inline pipeline, so a page ref inside a
    /// cell is a live link, not literal `[[…]]` text.
    @Test func cellsRenderInlineMarkdown() {
        let rendered = render("| page |\n| --- |\n| [[Marina]] |")
        let range = (rendered.string as NSString).range(of: "Marina")
        #expect(range.location != NSNotFound)
        #expect(rendered.attribute(.link, at: range.location, effectiveRange: nil) != nil)
    }

    /// Where nothing can draw a grid (reference rows, previews, embeds), the raw
    /// pipe source shows instead of a half-rendered table.
    @Test func constrainedContextsShowRawSource() {
        let rendered = render(source, tables: false)
        #expect(rendered.string == source)
        #expect(rendered.attribute(BlockRenderer.tableKey, at: 0, effectiveRange: nil) == nil)
    }
}
