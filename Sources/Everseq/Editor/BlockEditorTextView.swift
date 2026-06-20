import AppKit
import EverseqCore

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
    func editorCopySubtreeMarkdown() -> String?
    func editorPasteBlocks(_ text: String)
    func editorFocusLost()
}

/// The single shared NSTextView (TextKit 2) that moves into the focused row —
/// the field-editor pattern from SPEC §15. Shows raw Markdown source with a
/// Marklight-style full-block attribute pass per keystroke (blocks are single
/// paragraphs, so a full re-highlight is fine).
final class BlockEditorTextView: NSTextView {

    weak var actions: BlockEditorActions?
    weak var autocomplete: AutocompleteController?
    /// Caret position right after a `[[Page]]` completion's auto-inserted
    /// trailing space. Consumed on the next keystroke: a plain Enter there
    /// removes the space before splitting; anything else keeps it.
    var pendingTrailingSpaceCaret: Int?

    private var isSettingContent = false

    /// Proportional, matching the rendered rows — the focused block shows raw
    /// Markdown source, but it shouldn't feel like a different document.
    static var editorFont: NSFont { NSFont.systemFont(ofSize: BlockRenderer.baseFontSize) }

    static func create() -> BlockEditorTextView {
        let view = BlockEditorTextView(usingTextLayoutManager: true)
        view.setUp()
        return view
    }

    private func setUp() {
        isRichText = false
        allowsUndo = false // global undo is custom (SPEC §13), not per-text-view
        font = Self.editorFont
        typingAttributes = [.font: Self.editorFont, .foregroundColor: NSColor.textColor]
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
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
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
            return
        }
        isSettingContent = true
        string = text
        applyHighlighting()
        isSettingContent = false
    }

    // MARK: - Key handling (SPEC §5.4, §13)

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
            } else {
                // Enter: drop the just-completed trailing space (if any), then
                // split the block at the cursor.
                removePendingTrailingSpace(at: pendingSpaceCaret)
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
            wrapSelection(with: "**")
            return
        case 34 where flags == .command: // Cmd+I → italic
            wrapSelection(with: "*")
            return
        default:
            break
        }
        super.keyDown(with: event)
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
        // Inside a code block, multi-line text stays in the block verbatim —
        // splitting it would let lines "escape" the fence (§5.5.1).
        if let text = NSPasteboard.general.string(forType: .string),
           text.contains("\n"),
           !BlockKind.caretInsideFence(string, utf16Caret: selectedRange().location) {
            actions?.editorPasteBlocks(text)
            return
        }
        super.paste(sender)
    }

    // MARK: - Change notifications

    override func didChangeText() {
        super.didChangeText()
        applyHighlighting()
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
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { actions?.editorFocusLost() }
        return resigned
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
            // Inline grammar (SPEC §5.1).
            rule("\\*\\*[^\\n]+?\\*\\*", [:], fontStyle: .bold),
            rule("(?<![\\*\\w])\\*[^\\*\\n]+\\*(?![\\*\\w])",
                 [.obliqueness: 0.18]),
            rule("~~[^~\\n]+~~",
                 [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
            rule("==[^=\\n]+==",
                 [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.3)]),
            rule("`[^`\\n]+`",
                 [.backgroundColor: NSColor.quaternarySystemFill,
                  .foregroundColor: NSColor.systemOrange],
                 fontStyle: .mono),
            rule("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", [.foregroundColor: NSColor.linkColor]),
            rule("\\[\\[[^\\[\\]\\n]+\\]\\]",
                 [.foregroundColor: NSColor.controlAccentColor]),
            rule("\\(\\([0-9a-fA-F-]{36}\\)\\)",
                 [.foregroundColor: NSColor.systemTeal,
                  .underlineStyle: NSUnderlineStyle.single.rawValue
                      | NSUnderlineStyle.patternDot.rawValue]),
            rule("(?<![\\w#])#(?:\\[\\[[^\\[\\]\\n]+\\]\\]|[\\w-]+)",
                 [.foregroundColor: NSColor.systemPurple]),
        ].compactMap { $0 }
    }()

    /// The base font for the whole raw source: a heading block edits at its
    /// rendered size, so focusing never changes row height (no "vibration").
    private static func baseFont(for source: String) -> NSFont {
        if case .heading(let level, _) = BlockKind.classify(source) {
            return BlockRenderer.headingFont(level: level)
        }
        return editorFont
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
            [.font: base, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph],
            range: full
        )
        for rule in Self.rules {
            var attrs = rule.attributes
            switch rule.fontStyle {
            case .none:
                break
            case .bold:
                attrs[.font] = NSFont.systemFont(ofSize: base.pointSize, weight: .bold)
            case .mono:
                attrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: base.pointSize - 1, weight: .regular)
            }
            rule.regex.enumerateMatches(in: source, options: [], range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attrs, range: match.range)
            }
        }
        // Match the rendered view's emoji size so they don't grow on focus.
        BlockRenderer.shrinkEmoji(storage, scale: BlockRenderer.emojiScale)
        storage.endEditing()
        typingAttributes = [
            .font: base, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
        ]
    }
}
