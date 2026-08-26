import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Clicks that land in a row's dead space — the gutter beside the text, the
/// padding above and below it. `NSTableCellView` declines those hits so the table
/// can use them for row selection, which left them doing nothing at all.
@MainActor
@Suite struct DeadSpaceClickTests {

    private func render(_ content: String) -> NSAttributedString {
        BlockRenderer.render(
            content: content,
            context: BlockRenderer.Context(journalDateFormat: .default))
    }

    /// A click in the gutter or the row's padding lands outside the text, and has
    /// to resolve to the nearest real position rather than nothing at all.
    @Test func clampedHitTestResolvesToTheNearestPosition() {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        view.textContainer?.size = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        let text = "some words here"
        view.textStorage?.setAttributedString(render(text))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        // Left of the text (a click in the gutter) → the line's start.
        #expect(view.nearestIndex(toClamped: NSPoint(x: -80, y: 10)) == 0)
        // Right of it (a click in the trailing space) → the line's end.
        #expect(view.nearestIndex(toClamped: NSPoint(x: 5_000, y: 10))
            == (text as NSString).length)
        // Above and below the text still resolve, rather than returning nothing.
        #expect(view.nearestIndex(toClamped: NSPoint(x: -80, y: -50)) == 0)
        #expect(view.nearestIndex(toClamped: NSPoint(x: 5_000, y: 500))
            == (text as NSString).length)
    }
}
