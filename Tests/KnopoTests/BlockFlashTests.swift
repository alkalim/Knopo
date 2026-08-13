import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// The flash a result click leaves on a row is an overlay view on the row's cell,
/// and cells are reused. Left to fade on its own it went on lighting whatever row
/// the cell showed next — a highlight on a row nobody clicked, and two lit rows
/// once the clicked one was flashed as well (which a redone reveal makes likely).
@MainActor
@Suite struct BlockFlashTests {

    private func cellInWindow() -> (cell: OutlineRowCell, window: NSWindow) {
        let cell = OutlineRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(cell)
        cell.showRendered(BlockRenderer.render(
            content: "a block", context: BlockRenderer.Context()))
        cell.layoutSubtreeIfNeeded()
        return (cell, window)
    }

    @Test func aFlashCanBeTakenOffAgain() {
        let (cell, _) = cellInWindow()
        let plain = cell.subviews.count
        cell.flash()
        #expect(cell.isFlashing)
        #expect(cell.subviews.count == plain + 1)
        cell.cancelFlash()
        #expect(!cell.isFlashing)
        #expect(cell.subviews.count == plain)   // the overlay is gone, not just faded
    }

    /// A redone reveal flashes the same cell again — one overlay, not a stack of
    /// them deepening the colour and outliving each other.
    @Test func flashingTwiceLeavesOneOverlay() {
        let (cell, _) = cellInWindow()
        let plain = cell.subviews.count
        cell.flash()
        cell.flash()
        #expect(cell.subviews.count == plain + 1)
        cell.cancelFlash()
        #expect(cell.subviews.count == plain)
    }

    /// Cancelling when nothing is lit is a no-op, not a stray removal.
    @Test func cancellingWithoutAFlashChangesNothing() {
        let (cell, _) = cellInWindow()
        let plain = cell.subviews.count
        cell.cancelFlash()
        #expect(!cell.isFlashing)
        #expect(cell.subviews.count == plain)
    }
}
