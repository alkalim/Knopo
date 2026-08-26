import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// The journal feed gives each day its own outline and its own editor, and an
/// editor is retained by the row it sits in — so it can outlive the outline that
/// made it (a feed rebuilt around a new day). Cleanup used to run only through
/// the editor's *weak* `actions`, so an outlived editor stayed embedded and lit
/// up: a row with a highlight and a blinking insertion indicator that nothing
/// would ever remove, while typing went somewhere else entirely.
@MainActor
@Suite struct OrphanedEditorTests {

    private func rowInWindow() -> (cell: OutlineRowCell, window: NSWindow) {
        let cell = OutlineRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(cell)
        cell.showRendered(BlockRenderer.render(
            content: "a block",
            context: BlockRenderer.Context(journalDateFormat: .default)))
        cell.layoutSubtreeIfNeeded()
        return (cell, window)
    }

    private func embeddedEditor(in cell: OutlineRowCell) -> BlockEditorTextView? {
        cell.subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? BlockEditorTextView }
            .first
    }

    /// An editor whose outline is gone takes itself out when it loses focus,
    /// rather than waiting for a delegate that no longer exists.
    @Test func anEditorWithNoOutlineLeftClearsItselfOnFocusLoss() {
        let (cell, window) = rowInWindow()
        let editor = BlockEditorTextView.create()
        editor.setContent("orphan")
        cell.embedEditor(editor)
        // No `actions`: exactly the state a deallocated controller leaves behind.
        #expect(editor.actions == nil)
        #expect(embeddedEditor(in: cell) === editor)

        window.makeFirstResponder(editor)
        window.makeFirstResponder(window.contentView)   // focus moves away

        #expect(embeddedEditor(in: cell) == nil)
        #expect(editor.superview == nil)
    }

    /// …and the row goes back to showing its content, rather than being left blank
    /// where the editor used to be.
    @Test func discardingAnEditorRestoresTheRenderedRow() {
        let (cell, _) = rowInWindow()
        let editor = BlockEditorTextView.create()
        cell.embedEditor(editor)
        #expect(embeddedEditor(in: cell) === editor)

        cell.discardEmbeddedEditor()

        #expect(embeddedEditor(in: cell) == nil)
        let rendered = cell.subviews.flatMap(\.subviews)
            .compactMap { $0 as? RenderedTextView }.first
        #expect(rendered?.isHidden == false)
        #expect(rendered?.string == "a block")
    }

    /// Discarding is idempotent and harmless on a row that never held an editor —
    /// the sweep runs on every attach.
    @Test func discardingWithoutAnEditorChangesNothing() {
        let (cell, _) = rowInWindow()
        cell.discardEmbeddedEditor()
        cell.discardEmbeddedEditor()
        let rendered = cell.subviews.flatMap(\.subviews)
            .compactMap { $0 as? RenderedTextView }.first
        #expect(rendered?.isHidden == false)
        #expect(rendered?.string == "a block")
    }
}
