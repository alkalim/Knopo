import AppKit
import KnopoCore

/// Actions the focused-block editor forwards to the outline controller
/// (SPEC §5.4, §13). The editor itself never mutates documents.
@MainActor
protocol BlockEditorActions: AnyObject {
    func editorTextDidChange(_ text: String)
    func editorSplit(atUTF16Offset offset: Int)
    func editorIndent()
    func editorOutdent()
    func editorDeleteEmptyBlock()
    func editorMergeWithPrevious()
    func editorMergeWithNext()
    func editorMoveBlock(by delta: Int)
    func editorToggleTodo()
    func editorEndEditing()
    func editorFocusAdjacent(by delta: Int)
    /// The caret moved for any reason other than a vertical block hop, so a
    /// carried-over column is stale.
    func editorCaretMoved()
    func editorCopySubtreeMarkdown() -> String?
    func editorPasteBlocks(_ text: String)
    func editorImportImageAssets(_ fileURLs: [URL]) -> String?
    func editorImportPastedImage(png data: Data) -> String?
    func editorFocusLost()
}

/// The single shared NSTextView (TextKit 2) that moves into the focused row —
/// the field-editor pattern from SPEC §15. Shows raw Markdown source with a
/// Marklight-style full-block attribute pass per keystroke (blocks are single
/// paragraphs, so a full re-highlight is fine).
final class BlockEditorTextView: NSTextView {

    weak var actions: BlockEditorActions?
    weak var autocomplete: AutocompleteController?
    /// Whether this editor belongs to a right-sidebar pane. A main-region outline
    /// opening ready to write may take focus *from* a pane, but never from another
    /// main-region outline (§5.4).
    var isInPane = false
    /// Faint hint drawn in this block while it is empty — the outline sets it on
    /// the sole block of an otherwise-empty page (SPEC §5.4). Drawn, never inserted:
    /// text in the storage would be saved, indexed, found by `⌘F`, and measured
    /// into the row height.
    var emptyHint: String? {
        didSet {
            guard emptyHint != oldValue else { return }
            setAccessibilityPlaceholderValue(emptyHint)
            needsDisplay = true
        }
    }
    /// Whether the last `draw` painted the hint, so an edit only forces a repaint
    /// when that actually changes (TextKit repaints glyphs without calling `draw`).
    private var didDrawHint = false

    /// Caret position right after a `[[Page]]` completion's auto-inserted
    /// trailing space. Consumed on the next keystroke: a plain Enter there
    /// removes the space before splitting; anything else keeps it.
    var pendingTrailingSpaceCaret: Int?

    private var isSettingContent = false

    /// Proportional, matching the rendered rows — the focused block shows raw
    /// Markdown source, but it shouldn't feel like a different document.
    static var editorFont: NSFont {
        BlockRenderer.weightedSystemFont(ofSize: BlockRenderer.baseFontSize)
    }

    static func create() -> BlockEditorTextView {
        let view = BlockEditorTextView(usingTextLayoutManager: true)
        view.setUp()
        return view
    }

    private func setUp() {
        isRichText = false
        allowsUndo = false // global undo is custom (SPEC §13), not per-text-view
        font = Self.editorFont
        typingAttributes = [.font: Self.editorFont, .foregroundColor: BlockRenderer.bodyColor]
        drawsBackground = true
        backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06)
        insertionPointColor = .controlAccentColor
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        // Vertical breathing room inside the focused-row highlight.
        textContainerInset = NSSize(width: 0, height: OutlineRowCell.contentInsetV)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // The table row owns the editor's height. Matching the rendered view's
        // fixed-height TextKit configuration also keeps their first lines at the
        // same vertical position inside the row.
        isVerticallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: - Empty-block hint

    override func draw(_ dirtyRect: NSRect) {
        // Background first (`setUp` fills the focused row's accent tint), then the
        // hint over it — the reverse of `RenderedTextView`, which draws *under* the
        // glyphs because it has glyphs to draw under.
        super.draw(dirtyRect)
        didDrawHint = false
        guard let hint = emptyHint, string.isEmpty, !hasMarkedText(), superview != nil
        else { return }
        BlockRenderer.drawEmptyHint(hint, in: self)
        didDrawHint = true
    }

    /// TextKit 2 renders the caret with a child view rather than through
    /// `drawInsertionPoint`. Empty storage has no paragraph fragment, so AppKit
    /// gives that view the font's natural 21 pt line instead of Knopo's pinned
    /// 15 pt block line. Preserve AppKit's position and clamp only the height.
    private func alignEmptyInsertionIndicator() {
        guard string.isEmpty else { return }
        for case let indicator as NSTextInsertionIndicator in subviews {
            var frame = indicator.frame
            frame.size.height = BlockRenderer.lineHeight(forSource: "")
            indicator.frame = frame
        }
    }

    override func layout() {
        super.layout()
        alignEmptyInsertionIndicator()
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        alignEmptyInsertionIndicator()
    }

    /// The hint is painted by `draw`, but TextKit 2 repaints glyphs on its own
    /// layout path without calling it — so an edit that starts or ends the empty
    /// state has to ask for a redraw, or the hint lingers beside the typed text.
    private func invalidateHintIfNeeded() {
        guard emptyHint != nil, didDrawHint != string.isEmpty else { return }
        needsDisplay = true
    }

    /// Keep file drops on the outline table, which inserts each image as a new
    /// block at the drop point. Ordinary string drags still edit this block.
    override func updateDragTypeRegistration() {
        registerForDraggedTypes([.string])
    }

    /// AppKit validates Edit > Paste against this list before dispatching the
    /// action. A plain-text NSTextView omits bitmap types, which otherwise makes
    /// Cmd+V a no-op for image-only clipboards before `paste(_:)` can run.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff]
            where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let pasteActions: Set<Selector> = [
            #selector(paste(_:)),
            #selector(pasteAsPlainText(_:)),
            #selector(pasteAsRichText(_:)),
        ]
        if let action = item.action, pasteActions.contains(action), isEditable,
           hasImagePasteboardContent {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    private var hasImagePasteboardContent: Bool {
        let pasteboard = NSPasteboard.general
        let hasFileURL = pasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        let hasBitmap = pasteboard.string(forType: .string) == nil
            && pasteboard.availableType(from: [.png, .tiff]) != nil
        return hasFileURL || hasBitmap
    }

    /// Declining image *return* types keeps this view out of the image-import
    /// Services, so the context and Edit menus omit Continuity-Camera items
    /// ("Insert from iPhone or iPad", "Add Sketch", "Scan Documents") that
    /// advertising image pasteboard types would otherwise inject. Image paste
    /// still works — `paste(_:)` reads the pasteboard directly, not via Services.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType, [.png, .tiff, .fileURL].contains(returnType) { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: - Context menu

    /// The stock NSTextView menu is a kitchen sink — Font, Substitutions,
    /// Transformations, Speech, Layout Orientation… — meaningless or harmful in
    /// a plain-Markdown source editor (the Substitutions submenu can re-enable
    /// the smart quotes/dashes deliberately disabled in `setUp`). Serve just the
    /// useful core instead.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if selectedRange().length > 0 {
            let selected = (string as NSString).substring(with: selectedRange())
            let short = selected.count > 24 ? selected.prefix(24) + "…" : selected[...]
            let lookUp = NSMenuItem(
                title: String(localized: "Look Up “\(short)”",
                              comment: "Text menu; the placeholder is the selected text"),
                action: #selector(lookUpSelection), keyEquivalent: ""
            )
            lookUp.target = self
            menu.addItem(lookUp)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Select All"),
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func lookUpSelection() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        showDefinition(for: storage.attributedSubstring(from: range), range: range)
    }

    // MARK: - Height measurement

    /// Hidden twin of the editor used to measure focused-row heights with the
    /// real TextKit 2 layout — `boundingRect` under-measures NSTextView and
    /// left the focused row visibly short.
    private static let measuringView = BlockEditorTextView.create()

    static func measureHeight(for text: String, width: CGFloat) -> CGFloat {
        let view = measuringView
        view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.isSettingContent = true
        view.string = text.isEmpty ? " " : text
        view.isSettingContent = false
        // Same attribute pass as the live editor — heading blocks measure at
        // their heading size.
        view.applyHighlighting()
        guard let layoutManager = view.textLayoutManager else {
            return ceil(view.intrinsicContentSize.height)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // usageBounds excludes the container inset; the editor draws with it.
        return ceil(layoutManager.usageBoundsForTextContainer.height)
            + view.textContainerInset.height * 2
    }

    /// Replaces the content without notifying the controller (used when the
    /// editor moves into a newly focused block). No-op when the text already
    /// matches, preserving caret and selection across reloads.
    /// Deletes the auto-inserted trailing space if the caret is still right
    /// after it (guards against the caret having moved, e.g. a click elsewhere).
    private func removePendingTrailingSpace(at expected: Int?) {
        guard let expected, expected > 0, selectedRange().location == expected else { return }
        let ns = string as NSString
        guard expected <= ns.length, ns.character(at: expected - 1) == 0x20 /* space */ else { return }
        insertText("", replacementRange: NSRange(location: expected - 1, length: 1))
    }

    func setContent(_ text: String) {
        pendingTrailingSpaceCaret = nil // editor reused for another block
        guard string != text else {
            applyHighlighting()
            invalidateHintIfNeeded()
            return
        }
        isSettingContent = true
        string = text
        applyHighlighting()
        isSettingContent = false
        // The editor moves between blocks, so its text can go non-empty → empty
        // (or back) with no `didChangeText` at all.
        invalidateHintIfNeeded()
    }

    // MARK: - Key handling (SPEC §5.4, §13)

    /// Formatting markers that wrap a selection instead of replacing it. The
    /// inner text stays selected, so pressing the key again doubles the marker:
    /// `[` `[` → `[[Page]]`, `*` `*` → `**bold**`, `~` `~` → `~~strike~~`.
    private static let wrapMarkers: [String: String] = [
        "[": "]", "`": "`", "*": "*", "~": "~", "=": "=", "$": "$",
    ]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let sel = selectedRange()
        if sel.length > 0, !hasMarkedText(),
           let typed = insertString as? String, let close = Self.wrapMarkers[typed],
           // Not inside a fenced code block: there these markers are literal
           // characters (code is full of `*`, backticks, `$`, `[`), so typing
           // one replaces the selection instead of wrapping it.
           !BlockKind.caretInsideFence(string, utf16Caret: sel.location) {
            let inner = (string as NSString).substring(with: sel)
            super.insertText(typed + inner + close, replacementRange: sel)
            // Re-select the inner text (not the markers) for repeat presses.
            setSelectedRange(NSRange(
                location: sel.location + (typed as NSString).length, length: sel.length))
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { // never break IME composition
            super.keyDown(with: event)
            return
        }
        if let autocomplete, autocomplete.handleKeyDown(event) { return }
        // The auto-space from a `[[Page]]` completion is one-shot: any key clears
        // it; a plain Enter at that caret removes it before splitting.
        let pendingSpaceCaret = pendingTrailingSpaceCaret
        pendingTrailingSpaceCaret = nil
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The auto-space after a `[[Page]]` completion helps when the next thing
        // is a word, but not when it's closing punctuation — drop it so the mark
        // sits against the reference ("[[Page]]," not "[[Page]] ,"). `super`
        // then types the punctuation at the reclaimed caret.
        if let spaceCaret = pendingSpaceCaret,
           flags.isSubset(of: [.shift]),
           let chars = event.characters, chars.count == 1, ",.;:!?".contains(chars) {
            removePendingTrailingSpace(at: spaceCaret)
        }
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if flags.contains(.command) {
                // Cmd+Enter: toggle the block's TODO/DONE state (§5.2).
                actions?.editorToggleTodo()
            } else if flags.contains(.shift) {
                // Shift+Enter: newline inside the block.
                insertText("\n", replacementRange: selectedRange())
            } else if BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
                // Inside a fenced code block: a fence is one block (§5.5.1),
                // so Enter inserts a newline rather than splitting.
                insertText("\n", replacementRange: selectedRange())
            } else if BlockKind.caretInsideTable(string, utf16Caret: selectedRange().location) {
                // A table is one block too (§5.2): Enter starts the next row.
                insertText("\n", replacementRange: selectedRange())
            } else {
                // Enter: drop the just-completed trailing space (if any), then
                // split the block at the cursor.
                removePendingTrailingSpace(at: pendingSpaceCaret)
                dropBlankTableRow()
                actions?.editorSplit(atUTF16Offset: selectedRange().location)
            }
            return
        case 48: // Tab / Shift+Tab
            if BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
                // Inside a code block, Tab indents the code, not the outline.
                if flags.contains(.shift) {
                    outdentCodeLine()
                } else {
                    insertText("\t", replacementRange: selectedRange())
                }
            } else if flags.contains(.shift) {
                actions?.editorOutdent()
            } else {
                actions?.editorIndent()
            }
            return
        case 126 where flags.contains(.option): // Alt+Up
            actions?.editorMoveBlock(by: -1)
            return
        case 125 where flags.contains(.option): // Alt+Down
            actions?.editorMoveBlock(by: 1)
            return
        case 11 where flags == .command: // Cmd+B → bold
            // Emphasis is meaningless in code, so these are inert in a fence.
            if !BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
                wrapSelection(with: "**")
            }
            return
        case 34 where flags == .command: // Cmd+I → italic
            if !BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
                wrapSelection(with: "*")
            }
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Second Enter at the end of a table: the first one opened a blank row, and
    /// this one leaves the table — so drop that empty row instead of committing
    /// it as a blank row in the grid. Only ever removes a trailing newline the
    /// caret sits right after.
    private func dropBlankTableRow() {
        let caret = selectedRange()
        guard caret.length == 0, caret.location == (string as NSString).length,
              caret.location > 0, string.hasSuffix("\n"),
              BlockKind.classify(String(string.dropLast())).isTable
        else { return }
        insertText("", replacementRange: NSRange(location: caret.location - 1, length: 1))
    }

    /// Wraps the selection in a Markdown emphasis marker (`**` bold, `*` italic),
    /// or inserts an empty pair with the caret between when there's no selection.
    private func wrapSelection(with marker: String) {
        let sel = selectedRange()
        let markerLen = (marker as NSString).length
        if sel.length == 0 {
            insertText(marker + marker, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + markerLen, length: 0))
            return
        }
        let selected = (string as NSString).substring(with: sel)
        insertText(marker + selected + marker, replacementRange: sel)
        // Keep the original text selected (now inside the markers).
        setSelectedRange(NSRange(location: sel.location + markerLen,
                                 length: (selected as NSString).length))
    }

    /// Shift+Tab inside a code block: remove one level of leading indentation
    /// (a leading tab, or up to two leading spaces) from the caret's line.
    private func outdentCodeLine() {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: lineRange)
        let removeLength: Int
        if line.hasPrefix("\t") {
            removeLength = 1
        } else {
            removeLength = line.prefix(2).prefix { $0 == " " }.count
        }
        guard removeLength > 0 else { return }
        insertText("", replacementRange: NSRange(location: lineRange.location, length: removeLength))
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc: end editing (block deselect).
            actions?.editorEndEditing()
        case #selector(NSResponder.deleteBackward(_:)):
            let sel = selectedRange()
            if sel.length == 0 && sel.location == 0 {
                if string.isEmpty {
                    actions?.editorDeleteEmptyBlock()
                } else {
                    actions?.editorMergeWithPrevious()
                }
                return
            }
            super.doCommand(by: selector)
        case #selector(NSResponder.deleteForward(_:)):
            // Del at the very end of a block pulls the next block's content up
            // into this one — the mirror of Backspace-at-start.
            let sel = selectedRange()
            if sel.length == 0 && sel.location == (string as NSString).length {
                actions?.editorMergeWithNext()
                return
            }
            super.doCommand(by: selector)
        case #selector(NSResponder.moveUp(_:)):
            if caretOnFirstLine {
                actions?.editorFocusAdjacent(by: -1)
            } else {
                super.doCommand(by: selector)
            }
        case #selector(NSResponder.moveDown(_:)):
            if caretOnLastLine {
                actions?.editorFocusAdjacent(by: 1)
            } else {
                super.doCommand(by: selector)
            }
        default:
            super.doCommand(by: selector)
        }
    }

    // MARK: - Caret geometry (carrying the column across blocks)

    /// True while we place the caret ourselves, so the placement doesn't report
    /// itself as a stray caret move and discard the column being carried.
    private var isPlacingCaret = false

    /// The caret's horizontal position in view coordinates, or nil when there is
    /// no layout to ask. Handed to the next block so `↑`/`↓` lands in the same
    /// column instead of at the end (or start) of the text.
    var caretX: CGFloat? {
        caretFrame(forOffset: min(selectedRange().location, (string as NSString).length))?.minX
    }

    /// Places the caret on the first or last visual line, at `x` in view
    /// coordinates — what AppKit does for `↑`/`↓` inside one text view, extended
    /// across a block boundary. Falls back to the line's far edge without layout.
    func placeCaret(atGoalX x: CGFloat, onFirstLine: Bool) {
        let ns = string as NSString
        let fallback = onFirstLine ? 0 : ns.length
        guard ns.length > 0, let anchor = caretFrame(forOffset: fallback) else {
            select(offset: fallback)
            return
        }
        let point = NSPoint(x: x, y: anchor.midY)
        select(offset: min(characterIndexForInsertion(at: point), ns.length))
    }

    private func select(offset: Int) {
        isPlacingCaret = true
        setSelectedRange(NSRange(location: offset, length: 0))
        isPlacingCaret = false
    }

    /// Scrolls the outline so the caret stays on screen.
    ///
    /// AppKit's own caret scrolling works on the text view's own bounds, and this
    /// view is one block tall — the caret is always "visible" inside it, so the
    /// outline's scroll view never moves on its own. Without this, arrowing or
    /// typing walks the caret straight past the fold on a page taller than the
    /// window.
    func revealCaret() {
        guard superview != nil, var caret = caretSegmentFrame() else { return }
        // A line of margin, so the caret comes to rest just inside the edge
        // rather than flush against it (and the next line is already in view).
        caret = caret.insetBy(dx: 0, dy: -BlockRenderer.lineHeight(forSource: ""))
        // Keep the whole focused row visible when it fits. For a block taller
        // than the viewport, the caret remains the only useful scroll target.
        if let scrollView = enclosingScrollView,
           bounds.height <= scrollView.contentView.bounds.height {
            caret = caret.union(bounds)
        }
        scrollToVisible(caret)
    }

    /// The caret's line rectangle in this view's coordinates, straight from
    /// TextKit. `caretFrame(forOffset:)` goes through screen space, which is only
    /// defined once the view is on an on-screen window — this one answers
    /// wherever the text is laid out.
    private func caretSegmentFrame() -> CGRect? {
        guard let layout = textLayoutManager, let content = textContentStorage,
              let location = content.location(content.documentRange.location,
                                              offsetBy: selectedRange().location)
        else { return nil }
        layout.ensureLayout(for: layout.documentRange)
        var frame: CGRect?
        layout.enumerateTextSegments(
            in: NSTextRange(location: location), type: .selection,
            options: [.rangeNotRequired]
        ) { _, rect, _, _ in
            frame = rect
            return false
        }
        guard var caret = frame else { return nil }
        let origin = textContainerOrigin
        caret.origin.x += origin.x
        caret.origin.y += origin.y
        return caret
    }

    /// The caret rectangle for a UTF-16 offset, in this view's coordinates.
    /// `firstRect(forCharacterRange:)` answers in screen space and is defined for
    /// an empty range, which is what a caret is.
    private func caretFrame(forOffset offset: Int) -> CGRect? {
        guard let window else { return nil }
        let screen = firstRect(
            forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        guard screen.origin.x.isFinite, screen.origin.y.isFinite else { return nil }
        return convert(window.convertFromScreen(screen), from: nil)
    }

    /// First/last *visual* line checks (wrap-aware, TextKit 2 safe): compare
    /// the caret's line rect against the rect at the start/end of the text.
    private var caretOnFirstLine: Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return true }
        let loc = min(selectedRange().location, ns.length)
        if ns.substring(to: loc).contains("\n") { return false }
        let caret = firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil)
        let start = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        return abs(caret.midY - start.midY) < 2
    }

    private var caretOnLastLine: Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return true }
        let loc = min(selectedRange().location, ns.length)
        if loc < ns.length, ns.substring(from: loc).contains("\n") { return false }
        let caret = firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil)
        let end = firstRect(forCharacterRange: NSRange(location: ns.length, length: 0), actualRange: nil)
        return abs(caret.midY - end.midY) < 2
    }

    // MARK: - Clipboard (SPEC §13)

    override func copy(_ sender: Any?) {
        // Cmd+C with no selection copies the whole subtree as Markdown.
        if selectedRange().length == 0, let markdown = actions?.editorCopySubtreeMarkdown() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(markdown, forType: .string)
            return
        }
        super.copy(sender)
    }

    override func paste(_ sender: Any?) {
        if pasteKnopoContent() { return }
        super.paste(sender)
    }

    /// Plain-text text views can receive Cmd+V through this selector instead of
    /// `paste(_:)`. Keep both responder paths behaviorally identical.
    override func pasteAsPlainText(_ sender: Any?) {
        if pasteKnopoContent() { return }
        super.pasteAsPlainText(sender)
    }

    /// Handles Knopo's structured/image clipboard forms. Returns false for an
    /// ordinary single-line string so AppKit can perform its normal paste.
    private func pasteKnopoContent() -> Bool {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? NSURL).map { $0 as URL } } ?? []
        if !fileURLs.isEmpty,
           let markdown = actions?.editorImportImageAssets(fileURLs) {
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        // Inside a code block, multi-line text stays in the block verbatim —
        // splitting it would let lines "escape" the fence (§5.5.1). Same for a
        // quote block: it is one multi-line block by design (§5.2), so pasted
        // lines become continuation lines instead of separate blocks.
        let isQuote: Bool = {
            if case .quote = BlockKind.classify(string) { return true }
            return false
        }()
        let text = pasteboard.string(forType: .string)
        // A table is one block as well — both when pasting into one and when the
        // pasted text is itself a table (the common case: a table copied from a
        // page into an empty block). Splitting it by lines would shred the grid
        // into a block per row.
        let isTable = BlockKind.classify(string).isTable
            || (text.map { BlockKind.classify($0).isTable } ?? false)
        if let text, text.contains("\n"),
           !isQuote, !isTable,
           !BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
            actions?.editorPasteBlocks(text)
            return true
        }
        if text == nil {
            let png: Data?
            if let data = pasteboard.data(forType: .png) {
                png = data
            } else if let data = pasteboard.data(forType: .tiff),
                      let bitmap = NSBitmapImageRep(data: data) {
                png = bitmap.representation(using: .png, properties: [:])
            } else {
                png = nil
            }
            if let png, let markdown = actions?.editorImportPastedImage(png: png) {
                insertText(markdown, replacementRange: selectedRange())
                return true
            }
        }
        return false
    }

    // MARK: - Change notifications

    override func didChangeText() {
        super.didChangeText()
        applyHighlighting()
        invalidateHintIfNeeded()
        guard !isSettingContent else { return }
        actions?.editorTextDidChange(string)
        autocomplete?.textDidChange(in: self)
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Moving the caret out of a trigger region re-evaluates/dismisses.
        if !isSettingContent, let autocomplete, autocomplete.isActive {
            autocomplete.textDidChange(in: self)
        }
        // Any move we didn't make ourselves (a click, a horizontal step, editing)
        // ends the vertical run, so the carried column is no longer wanted.
        if !isPlacingCaret, !isSettingContent { actions?.editorCaretMoved() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned else { return false }
        if let actions {
            actions.editorFocusLost()
        } else {
            // `actions` is weak, and the row retains this view — so an outline
            // that went away (a journal feed rebuilt around a new day) leaves its
            // editor embedded with nothing left to end the session. Ending it is
            // then this view's own job, or the row keeps its highlight and a
            // still-animating insertion indicator indefinitely.
            OutlineRowCell.enclosing(self)?.discardEmbeddedEditor()
            removeFromSuperview()
        }
        return true
    }

    // MARK: - Syntax highlighting (SPEC §15)

    private struct Rule {
        enum FontStyle { case none, bold, mono }
        let regex: NSRegularExpression
        let attributes: [NSAttributedString.Key: Any]
        var fontStyle: FontStyle = .none
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ attributes: [NSAttributedString.Key: Any],
                  options: NSRegularExpression.Options = [],
                  fontStyle: Rule.FontStyle = .none) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            return Rule(regex: regex, attributes: attributes, fontStyle: fontStyle)
        }
        return [
            // Block-level prefixes (SPEC §5.2). Heading text gets its real
            // size from the base-font pass (Logseq-style: big text with the
            // `#` marks visible); this rule just dims the marks.
            rule("^#{1,6}(?= )", [.foregroundColor: NSColor.tertiaryLabelColor],
                 options: [.anchorsMatchLines]),
            rule("^> ", [.foregroundColor: NSColor.secondaryLabelColor],
                 options: [.anchorsMatchLines]),
            // Logseq/org-mode quote container markers.
            rule("^#\\+(?:BEGIN|END)_[A-Za-z_]+.*$",
                 [.foregroundColor: NSColor.tertiaryLabelColor],
                 options: [.anchorsMatchLines, .caseInsensitive]),
            rule("^TODO(?= |$)", [.foregroundColor: NSColor.controlAccentColor],
                 fontStyle: .bold),
            rule("^DONE(?= |$)", [.foregroundColor: NSColor.secondaryLabelColor],
                 fontStyle: .bold),
            rule("^[A-Za-z][\\w-]*:: ", [.foregroundColor: NSColor.tertiaryLabelColor],
                 options: [.anchorsMatchLines]),
            // Inline grammar (SPEC §5.1). A leading `(?<!\\)` keeps a backslash-
            // escaped opener (`\#`, `\[[`, `` \` ``, `\*`, …) from highlighting,
            // matching how the rendered view treats the escape (§5.1).
            rule("(?<!\\\\)\\*\\*[^\\n]+?\\*\\*", [:], fontStyle: .bold),
            rule("(?<![\\*\\w\\\\])\\*[^\\*\\n]+\\*(?![\\*\\w])",
                 [.obliqueness: 0.18]),
            rule("(?<!\\\\)~~[^~\\n]+~~",
                 [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
            rule("(?<!\\\\)==[^=\\n]+==",
                 [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.3)]),
            rule("(?<!\\\\)`[^`\\n]+`",
                 [.backgroundColor: NSColor.quaternarySystemFill,
                  .foregroundColor: NSColor.systemOrange],
                 fontStyle: .mono),
            rule("(?<!\\\\)\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", [.foregroundColor: NSColor.linkColor]),
            rule("(?<!\\\\)\\[\\[[^\\[\\]\\n]+\\]\\]",
                 [.foregroundColor: NSColor.controlAccentColor]),
            rule("(?<!\\\\)\\(\\([0-9a-fA-F-]{36}\\)\\)",
                 [.foregroundColor: NSColor.systemTeal,
                  .underlineStyle: NSUnderlineStyle.single.rawValue
                      | NSUnderlineStyle.patternDot.rawValue]),
            rule("(?<![\\w#\\\\])#(?:\\[\\[[^\\[\\]\\n]+\\]\\]|[\\w-]+)",
                 [.foregroundColor: NSColor.systemPurple]),
        ].compactMap { $0 }
    }()

    /// The base font for the whole raw source: a heading block edits at its
    /// rendered size, so focusing never changes row height (no "vibration").
    private static func baseFont(for source: String) -> NSFont {
        switch BlockKind.classify(source) {
        case .heading(let level, _):
            return BlockRenderer.headingFont(level: level)
        case .fence:
            // Editing a fenced code block shows it monospaced, matching the
            // rendered view's code font (same size, so the pinned line height
            // holds and focus doesn't shift the code).
            return NSFont.monospacedSystemFont(ofSize: BlockRenderer.baseFontSize - 1, weight: .regular)
        default:
            return editorFont
        }
    }

    /// Dims a table's cell separators and its whole delimiter row (the second
    /// line, which has no rendered counterpart). An escaped `\|` is cell content,
    /// not a separator, so it stays as typed.
    private func dimTableSyntax(_ storage: NSTextStorage, source: String) {
        let dim = [NSAttributedString.Key.foregroundColor: NSColor.tertiaryLabelColor]
        let ns = source as NSString
        var offset = 0
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let length = (line as NSString).length
            if index == 1 {
                storage.addAttributes(dim, range: NSRange(location: offset, length: length))
            } else {
                var search = NSRange(location: offset, length: length)
                while search.length > 0 {
                    let pipe = ns.range(of: "|", range: search)
                    guard pipe.location != NSNotFound else { break }
                    if pipe.location == offset
                        || ns.substring(with: NSRange(location: pipe.location - 1, length: 1)) != "\\" {
                        storage.addAttributes(dim, range: pipe)
                    }
                    let next = NSMaxRange(pipe)
                    search = NSRange(location: next, length: max(0, NSMaxRange(search) - next))
                }
            }
            offset += length + 1 // + the "\n"
        }
    }

    /// Full re-highlight of the (single-paragraph) block source. Attribute-only
    /// edits, so this never re-enters `didChangeText`.
    private func applyHighlighting() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let source = storage.string
        let base = Self.baseFont(for: source)
        // Pin the line height to match the rendered view, so emoji (whose
        // substituted font carries extra leading) don't make the focused row
        // taller than the rendered one — no vertical jitter on focus (§5.4).
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = BlockRenderer.lineHeight(forSource: source)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // Match the rendered view's wrapped-line spacing so the row height (and
        // caret line pitch) don't change when a multi-line block is focused.
        paragraph.lineSpacing = BlockRenderer.lineSpacing
        storage.beginEditing()
        storage.setAttributes(
            [.font: base, .foregroundColor: BlockRenderer.bodyColor, .paragraphStyle: paragraph],
            range: full
        )
        // Inside a fenced code block the content is code, not markdown, so skip
        // the inline rules: it stays plain monospace, and a `#`/`>`-prefixed
        // code line isn't dimmed like a heading or quote.
        let isFence: Bool
        if case .fence = BlockKind.classify(source) { isFence = true } else { isFence = false }
        for rule in Self.rules where !isFence {
            var attrs = rule.attributes
            switch rule.fontStyle {
            case .none:
                break
            case .bold:
                attrs[.font] = BlockRenderer.bolder(base)
            case .mono:
                attrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: base.pointSize - 1, weight: .regular)
            }
            rule.regex.enumerateMatches(in: source, options: [], range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attrs, range: match.range)
            }
        }
        // A table's pipes and delimiter row are structure, not content: dim them
        // so the focused source reads as the grid it renders to (§5.2). Cell text
        // keeps the inline highlighting above.
        if case .table = BlockKind.classify(source) {
            dimTableSyntax(storage, source: source)
        }
        // Match the rendered view's emoji size so they don't grow on focus.
        BlockRenderer.shrinkEmoji(storage, scale: BlockRenderer.emojiScale)
        storage.endEditing()
        typingAttributes = [
            .font: base, .foregroundColor: BlockRenderer.bodyColor, .paragraphStyle: paragraph,
        ]
    }
}
