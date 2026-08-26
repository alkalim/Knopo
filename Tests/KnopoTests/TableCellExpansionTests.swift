import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// A table cell is a single line, and rendering one must stay cheap however much
/// content it names. Both of these froze the app: a `{{query}}` in a cell
/// expanded to its whole result set, and truncating a long cell re-measured the
/// string once per character.
@MainActor
@Suite struct TableCellExpansionTests {

    /// Stands in for a real query's rendered results: many lines of text.
    private func bigRegion(lines: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for index in 0..<lines {
            out.append(NSAttributedString(
                string: "result row \(index) — some page name and a bit of content\n",
                attributes: [.font: BlockRenderer.baseFont()]))
        }
        return out
    }

    /// A query in a cell renders as the muted chip, not its results — the same
    /// thing a reference row or preview shows.
    @Test func queryInACellRendersAsAChipNotItsResults() {
        var expansions = 0
        let context = BlockRenderer.Context(journalDateFormat: .default, resolveQuery: { _ in
            expansions += 1
            return self.bigRegion(lines: 200)
        })
        let rendered = BlockRenderer.render(
            content: "| a | b |\n| --- | --- |\n| {{query #work TODO}} | x |",
            context: context)
        #expect(expansions == 0)
        #expect(rendered.string.contains("⧉ query"))
        #expect(!rendered.string.contains("result row"))
        // Still a laid-out table: two lines, and the row ends with the `x` cell.
        #expect(rendered.string.components(separatedBy: "\n").count == 2)
        #expect(rendered.string.hasSuffix("x"))
    }

    /// Same for an embed — one line of cell can't hold a transcluded subtree.
    @Test func embedInACellRendersAsAChip() {
        var expansions = 0
        let context = BlockRenderer.Context(journalDateFormat: .default, resolveEmbed: { _ in
            expansions += 1
            return self.bigRegion(lines: 50)
        })
        let rendered = BlockRenderer.render(
            content: "| a |\n| --- |\n| {{embed [[Marina]]}} |", context: context)
        #expect(expansions == 0)
        #expect(rendered.string.contains("⧉"))
        #expect(!rendered.string.contains("result row"))
    }

    /// Truncation binary-searches the cut point, so a cell holding a paragraph
    /// costs a handful of measurements, not one per character. This case measured
    /// ~7 s before the fix; a cell that expanded a `{{query}}` was as large as the
    /// whole result set and re-rendered on every rebuild, hence the frozen app.
    @Test func longCellTruncatesWithoutQuadraticMeasuring() {
        let long = String(repeating: "some long cell content ", count: 400)
        let clock = ContinuousClock()
        var rendered = NSAttributedString()
        let elapsed = clock.measure {
            rendered = BlockRenderer.render(content: "| a |\n| --- |\n| \(long) |",
                                            context: BlockRenderer.Context(
                                                journalDateFormat: .default))
        }
        #expect(elapsed < .seconds(1))
        #expect(rendered.string.contains("…"))
    }

    /// The truncated cell is still the widest thing the column allows: cutting
    /// too eagerly would waste the column, cutting too late would overrun it.
    @Test func truncationKeepsAsMuchAsFits() {
        let rendered = BlockRenderer.render(
            content: "| a |\n| --- |\n| \(String(repeating: "wide ", count: 200)) |",
            context: BlockRenderer.Context(journalDateFormat: .default))
        let cell = rendered.attributedSubstring(
            from: (rendered.string as NSString).range(of: "wide", options: .backwards))
        #expect(cell.length > 0)
        // The laid-out row fits inside the column cap, with the ellipsis on it.
        let row = rendered.attributedSubstring(
            from: NSRange(location: 0, length: rendered.length))
        #expect(ceil(row.size().width) <= BlockRenderer.tableMaxColumnWidth
            + BlockRenderer.tableCellPad * 2 + BlockRenderer.tableColumnSlack + 1)
    }
}
