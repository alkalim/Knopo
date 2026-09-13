import AppKit
import Testing
@testable import Knopo

/// Which link a hover lands on. A result is a list of links, so snapping to
/// the nearest one previews the wrong page.
@MainActor
@Suite struct HoverHitTests {

    /// Two short link lines, laid out in a view far wider than either.
    private func view() -> RenderedTextView {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "first\n", attributes: [
            .link: KnopoURL.page("First"), .font: NSFont.systemFont(ofSize: 13),
        ]))
        text.append(NSAttributedString(string: "second", attributes: [
            .link: KnopoURL.page("Second"), .font: NSFont.systemFont(ofSize: 13),
        ]))
        view.textStorage?.setAttributedString(text)
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    /// A point on the link is that link.
    @Test func hoverOnALinkFindsIt() throws {
        let view = view()
        let hit = try #require(view.hoverRef(at: NSPoint(x: 12, y: 8)))
        #expect(hit.ref == .page("First"))
    }

    /// A result row is one link to its source block. Hovering it previews
    /// nothing: the row's text may name somewhere else entirely.
    @Test func hoverOnAResultRowFindsNothing() throws {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        view.textStorage?.setAttributedString(NSAttributedString(
            string: "a matching block", attributes: [
                .link: KnopoURL.block(UUID(), onPage: "Source Page"),
                .font: NSFont.systemFont(ofSize: 13),
            ]))
        view.layoutSubtreeIfNeeded()
        #expect(view.hoverRef(at: NSPoint(x: 12, y: 8)) == nil)
    }

    /// The empty space to the right of a short line belongs to no link.
    @Test func hoverPastTheEndOfALineFindsNothing() throws {
        let view = view()
        #expect(view.hoverRef(at: NSPoint(x: 340, y: 8)) == nil)
    }
}
