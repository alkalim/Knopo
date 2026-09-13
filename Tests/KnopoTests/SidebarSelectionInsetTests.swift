import AppKit
import Testing
@testable import Knopo

/// The sidebar paints its own selection pill. It has to sit where AppKit puts
/// a source list's highlight, which is also the rect it outlines on right-click.
/// Measured from a real table, so a system that changes the inset fails here.
@MainActor
@Suite struct SidebarSelectionInsetTests {

    /// Draws a one-row source list and reports where the highlight starts.
    private func measuredInset(rowWidth: CGFloat) throws -> CGFloat {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 30))
        table.selectionHighlightStyle = .sourceList
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
        let rowView = NSTableRowView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))
        rowView.selectionHighlightStyle = .sourceList
        rowView.isSelected = true
        rowView.isEmphasized = false
        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rowWidth
        let middle = rep.pixelsHigh / 2
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: middle) else { continue }
            if colour.alphaComponent > 0.1 { return CGFloat(x) / scale }
        }
        return -1
    }

    @Test func pillMatchesTheSystemHighlight() throws {
        let inset = try measuredInset(rowWidth: 220)
        // -1 means nothing was drawn offscreen. Then this test proves nothing.
        try #require(inset >= 0)
        #expect(inset == Sidebar.selectionInset)
    }
}
