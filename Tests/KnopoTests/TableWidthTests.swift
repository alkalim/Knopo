import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// `table-width::` and the column fitting behind it (SPEC §5.2). The invariant
/// that matters: a table never exceeds the row it's in — columns scale to fit
/// instead of being clipped at the edge.
@MainActor
@Suite struct TableWidthTests {

    /// `fittedColumnWidths` returns laid-out widths (content plus padding), so the
    /// invariant under test is simply their sum against the row width.
    private func totalWidth(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) }

    private func fitted(
        _ natural: [CGFloat], available: CGFloat?, mode: BlockRenderer.TableWidth
    ) -> [CGFloat] {
        BlockRenderer.fittedColumnWidths(
            natural: natural, available: available, mode: mode,
            pad: BlockRenderer.tableCellPad(columns: natural.count, available: available))
    }

    @Test func maxModeFillsTheRowExactly() {
        let widths = fitted([40, 60, 20], available: 600, mode: .max)
        #expect(abs(totalWidth(widths) - 600) < 0.5)
        // Proportions follow the content: the widest column stays the widest.
        #expect(widths[1] > widths[0])
        #expect(widths[0] > widths[2])
    }

    @Test func maxModeAlsoShrinksAnOversizedTable() {
        let widths = fitted([400, 400, 400], available: 500, mode: .max)
        #expect(abs(totalWidth(widths) - 500) < 0.5)
    }

    @Test func minModeKeepsNaturalWidthsWhenTheyFit() {
        let natural: [CGFloat] = [40, 60, 20]
        let widths = fitted(natural, available: 600, mode: .min)
        let chrome = BlockRenderer.tableCellPad * 2 + BlockRenderer.tableColumnSlack
        #expect(widths == natural.map { $0 + chrome })
    }

    /// The clipping fix: even a table that asks for more than the row gets
    /// scaled down to fit rather than running off the edge.
    @Test func minModeShrinksRatherThanOverflowing() {
        let widths = fitted([300, 300, 300], available: 400, mode: .min)
        #expect(totalWidth(widths) <= 400.5)
        #expect(widths.allSatisfy { $0 > 0 })
    }

    /// Shrinking takes from the columns that have room to give: a narrow column
    /// next to a paragraph-wide one is left at its natural width, so its heading
    /// doesn't get truncated to buy the wide column a few points.
    @Test func shrinkingTakesFromTheWidestColumns() {
        let chrome = BlockRenderer.tableCellPad * 2 + BlockRenderer.tableColumnSlack
        let widths = fitted([1000, 8], available: 420, mode: .max)
        #expect(totalWidth(widths) <= 420.5)
        #expect(widths[1] == 8 + chrome)    // untouched
        #expect(widths[0] > widths[1] * 5)  // the wide one absorbed the overflow
    }

    /// Degenerate case — more columns than the row can floor. Still must fit.
    @Test func manyColumnsInANarrowRowStillFit() {
        let widths = fitted(Array(repeating: 80, count: 24), available: 300, mode: .max)
        #expect(totalWidth(widths) <= 300.5)
        #expect(widths.allSatisfy { $0 >= 0 })
    }

    /// With no width to fit against (SwiftUI `Text`, previews), columns take
    /// their natural widths — nothing to fill or shrink to.
    @Test func noAvailableWidthLeavesNaturalWidths() {
        let natural: [CGFloat] = [40, 60]
        let chrome = BlockRenderer.tableCellPad * 2 + BlockRenderer.tableColumnSlack
        #expect(fitted(natural, available: nil, mode: .max) == natural.map { $0 + chrome })
        #expect(fitted(natural, available: 0, mode: .max) == natural.map { $0 + chrome })
    }

    // MARK: - End to end through the renderer

    private func render(
        _ content: String, width: CGFloat?, mode: BlockRenderer.TableWidth = .max
    ) -> NSAttributedString {
        BlockRenderer.render(content: content, context: BlockRenderer.Context(
            journalDateFormat: .default, contentWidth: width, tableWidth: mode))
    }

    private func tableGeometry(_ rendered: NSAttributedString) -> BlockRenderer.TableGeometry? {
        rendered.attribute(BlockRenderer.tableKey, at: 0, effectiveRange: nil)
            as? BlockRenderer.TableGeometry
    }

    private let small = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    @Test func aSmallTableFillsTheRowByDefault() throws {
        let geometry = try #require(tableGeometry(render(small, width: 700)))
        #expect(abs((geometry.columnEdges.last ?? 0) - 700) < 0.5)
    }

    @Test func minWidthKeepsASmallTableCompact() throws {
        let geometry = try #require(tableGeometry(render(small, width: 700, mode: .min)))
        let width = try #require(geometry.columnEdges.last)
        #expect(width > 0)
        #expect(width < 300) // content-sized, nowhere near the row
    }

    /// A wide table — the case that used to be clipped — now ends exactly at the
    /// row's edge in both modes.
    @Test func wideTableFitsTheRowInBothModes() throws {
        let wide = """
            | one | two | three | four | five | six |
            | --- | --- | --- | --- | --- | --- |
            | \(String(repeating: "long ", count: 40)) | b | c | d | e | f |
            """
        for mode in BlockRenderer.TableWidth.allCases {
            let geometry = try #require(tableGeometry(render(wide, width: 520, mode: mode)))
            #expect((geometry.columnEdges.last ?? 0) <= 520.5)
        }
    }

    /// The geometry knows how many lines are rows, so the row view stops drawing
    /// rules there — a block's visible property lines follow the table.
    @Test func geometryReportsItsRowCount() throws {
        let geometry = try #require(tableGeometry(render(small, width: 700)))
        #expect(geometry.rowCount == 2) // header + one row
    }

    /// The grid is drawn from TextKit 2's layout fragments — one per row — so
    /// those frames have to tile the table with no gaps and no overlap, or the
    /// rules drift off the row boundaries. The breathing room inside a row is
    /// paragraph spacing, which lands *inside* its fragment; this is what pins
    /// that down.
    @Test func rowFragmentsTileTheTableExactly() throws {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        view.textContainer?.size = NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
        let source = """
            | Name | Qty |
            | --- | ---: |
            | Apples | 3 |
            | Pears | 12 |
            """
        view.textStorage?.setAttributedString(render(source, width: 620))
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var frames: [CGRect] = []
        layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            frames.append(fragment.layoutFragmentFrame)
            return true
        }
        try #require(frames.count == 3) // header + two rows
        let text = BlockRenderer.lineHeight(forSource: source)
        let pad = BlockRenderer.tableRowPad
        #expect(abs(frames[0].minY) < 0.5)
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(abs(next.minY - previous.maxY) < 0.5) // contiguous: no gap, no overlap
        }
        // TextKit drops the first paragraph's leading spacing and the last one's
        // trailing spacing, so the outer rows are one pad short — which is exactly
        // what `drawTableGrid` compensates for by pushing the outer rules out.
        #expect(abs(frames[0].height - (text + pad)) < 0.5)
        #expect(abs(frames[1].height - (text + pad * 2)) < 0.5)
        #expect(abs(frames[2].height - (text + pad)) < 0.5)
        // The compensated extent has to stay inside the row, or a rule is clipped.
        let drawn = frames[2].maxY + pad * 2 // pad above the first row and below the last
        #expect(drawn <= OutlineRowCell.height(for: view.attributedString(),
                                               contentWidth: 620) + 0.5)
    }

    @Test func propertyValueParsesLenientlyAndDefaultsToMax() {
        #expect(BlockRenderer.TableWidth(propertyValue: "min") == .min)
        #expect(BlockRenderer.TableWidth(propertyValue: "  MIN ") == .min)
        #expect(BlockRenderer.TableWidth(propertyValue: "max") == .max)
        #expect(BlockRenderer.TableWidth(propertyValue: "nonsense") == .max)
        #expect(BlockRenderer.TableWidth(propertyValue: "") == .max)
    }
}
