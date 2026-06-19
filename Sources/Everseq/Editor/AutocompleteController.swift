import AppKit
import EverseqCore

/// Hand-rolled autocomplete popover for the focused-block editor (SPEC §15):
/// `[[` pages (§6.1), `((` block search (§7.1), `#` tags (§8.2), and `/`
/// journal commands (§10). Stateless trigger detection runs on every keystroke
/// and caret move; arrow keys navigate, Enter/Tab commits, Esc dismisses.
@MainActor
final class AutocompleteController: NSObject {

    enum Mode {
        case pageRef
        case blockRef
        case tag
        case command
    }

    enum Item {
        case page(String)
        case createPage(String)
        case block(SearchHit)
        case tag(String)
        case command(label: String, insertion: String)
        /// A command that prefixes the whole block (e.g. `/quote` → `> `).
        case commandPrefix(label: String, prefix: String, hint: String)
        /// Inserts `text` and places the caret `caretOffset` chars into it
        /// (e.g. `/code-block` → fenced skeleton, caret on the opening fence).
        case commandInsertCaret(label: String, text: String, caretOffset: Int, hint: String)
        /// Opens the two-field link panel (§5.5.2); inserts nothing itself.
        case commandLink(label: String, hint: String)
        /// Opens the graphical date picker (§5.5.4); inserts nothing itself.
        case commandDatePicker(label: String, hint: String)
    }

    // Data providers, injected by the outline controller.
    var fetchPages: (String) -> [String] = { _ in [] }
    var fetchBlocks: (String) -> [SearchHit] = { _ in [] }
    var fetchTags: (String) -> [String] = { _ in [] }
    /// Called after a `((uuid))` insert so the source page persists `id::` (§7.1).
    var onBlockRefInserted: (SearchHit) -> Void = { _ in }
    /// Called when `/link` is committed (trigger already removed); the host
    /// opens the link panel at the current caret (§5.5.2).
    var onLinkCommand: () -> Void = {}
    /// Called when `/date` is committed (trigger already removed); the host
    /// opens the date picker at the current caret (§5.5.4).
    var onDateCommand: () -> Void = {}

    private(set) var isActive = false
    /// Set just before a commit inserts its replacement, so the `textDidChange`
    /// that insertion fires doesn't re-open the popup. (A tag has no closing
    /// delimiter, so `#tag` at the caret would otherwise re-trigger; page/block
    /// refs close themselves with `]]` / `))`.) One-shot.
    private var suppressNextChange = false
    private var mode: Mode = .pageRef
    /// UTF-16 location of the trigger's first character (start of replacement).
    private var triggerLocation = 0
    private var items: [Item] = []
    private var selectedIndex = 0
    private weak var textView: NSTextView?

    // MARK: - Trigger detection

    private struct Trigger {
        var mode: Mode
        var location: Int
        var query: String
    }

    func textDidChange(in textView: NSTextView) {
        self.textView = textView
        if suppressNextChange {
            suppressNextChange = false
            dismiss()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let trigger = Self.detectTrigger(
                  in: textView.string as NSString, caret: selection.location
              ) else {
            dismiss()
            return
        }
        mode = trigger.mode
        triggerLocation = trigger.location
        rebuildItems(query: trigger.query)
        if items.isEmpty {
            dismiss()
        } else {
            presentPanel(anchoredTo: textView)
            tableView.reloadData()
            select(0)
        }
    }

    private static func detectTrigger(in text: NSString, caret: Int) -> Trigger? {
        guard caret > 0, caret <= text.length else { return nil }
        var candidates: [Trigger] = []
        if let (location, query) = bracketTrigger(open: "[[", close: "]]", in: text, caret: caret) {
            // `#[[` is the bracketed *tag* form, not a page ref (SPEC §8.1).
            if location > 0, text.character(at: location - 1) == 0x23 /* # */ {
                candidates.append(Trigger(mode: .tag, location: location - 1, query: query))
            } else {
                candidates.append(Trigger(mode: .pageRef, location: location, query: query))
            }
        }
        if let (location, query) = bracketTrigger(open: "((", close: "))", in: text, caret: caret) {
            candidates.append(Trigger(mode: .blockRef, location: location, query: query))
        }
        if let trigger = wordTrigger(0x23 /* # */, mode: .tag, in: text, caret: caret) {
            candidates.append(trigger)
        }
        if let trigger = wordTrigger(0x2F /* / */, mode: .command, in: text, caret: caret) {
            candidates.append(trigger)
        }
        // The trigger nearest the caret wins.
        return candidates.max { $0.location < $1.location }
    }

    /// An unclosed `[[` / `((` left of the caret, on the same line.
    private static func bracketTrigger(
        open: String, close: String, in text: NSString, caret: Int
    ) -> (location: Int, query: String)? {
        let windowStart = max(0, caret - 160)
        let searchRange = NSRange(location: windowStart, length: caret - windowStart)
        let openRange = text.range(of: open, options: .backwards, range: searchRange)
        guard openRange.location != NSNotFound else { return nil }
        let queryStart = openRange.location + 2
        guard caret >= queryStart else { return nil }
        let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        guard !query.contains(close), !query.contains("\n"), query.count <= 80 else { return nil }
        return (openRange.location, query)
    }

    /// A `#word` or `/word` trigger whose word the caret sits in.
    private static func wordTrigger(
        _ triggerChar: unichar, mode: Mode, in text: NSString, caret: Int
    ) -> Trigger? {
        var i = caret - 1
        while i >= 0, caret - i <= 60 {
            let c = text.character(at: i)
            if c == triggerChar { break }
            guard isWordChar(c) else { return nil }
            i -= 1
        }
        guard i >= 0, text.character(at: i) == triggerChar else { return nil }
        if i > 0 {
            let previous = text.character(at: i - 1)
            // Word start only: `a#b` is not a tag, `a/b` is not a command.
            if isWordChar(previous) || previous == triggerChar { return nil }
            if mode == .command, !isWhitespace(previous) { return nil }
        }
        let query = text.substring(with: NSRange(location: i + 1, length: caret - i - 1))
        return Trigger(mode: mode, location: i, query: query)
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F /* _ */ || c == 0x2D /* - */
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Items

    private func rebuildItems(query: String) {
        switch mode {
        case .pageRef:
            // Fuzzy match ordered by recency, plus a create entry (SPEC §6.1).
            var out = fetchPages(query).prefix(12).map(Item.page)
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, PageName.isValid(trimmed),
               !out.contains(where: {
                   if case .page(let name) = $0 {
                       return PageName.key(name) == PageName.key(trimmed)
                   }
                   return false
               }) {
                out.append(.createPage(trimmed))
            }
            items = Array(out)
        case .blockRef:
            // Full-text block search across the graph (SPEC §7.1).
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            items = trimmed.isEmpty
                ? []
                : fetchBlocks(trimmed).prefix(12).map(Item.block)
        case .tag:
            items = fetchTags(query).prefix(12).map(Item.tag)
        case .command:
            // Slash commands (SPEC §5.5). Filter by command-name prefix.
            let today = JournalDate.today()
            let q = query.lowercased()
            func matches(_ name: String) -> Bool { q.isEmpty || name.hasPrefix(q) }
            var out: [Item] = []
            // Date references (§10).
            if matches("today") {
                out.append(.command(label: "/today", insertion: "[[\(today.pageName)]]"))
            }
            if matches("tomorrow") {
                out.append(.command(label: "/tomorrow",
                                    insertion: "[[\(today.adding(days: 1).pageName)]]"))
            }
            if matches("yesterday") {
                out.append(.command(label: "/yesterday",
                                    insertion: "[[\(today.adding(days: -1).pageName)]]"))
            }
            if matches("date") {
                // Opens a calendar to reference *any* day (§5.5.4), not just today.
                out.append(.commandDatePicker(label: "/date", hint: "pick a date"))
            }
            // Block-level (§5.5).
            if matches("quote") {
                out.append(.commandPrefix(label: "/quote", prefix: "> ", hint: "block quote"))
            }
            if matches("code-block") {
                // ```\n\n``` with the caret at the end of the opening fence.
                out.append(.commandInsertCaret(
                    label: "/code-block", text: "```\n\n```", caretOffset: 3, hint: "fenced code"))
            }
            if matches("link") {
                out.append(.commandLink(label: "/link", hint: "insert link"))
            }
            // Read-only transclusions (§7.6). Both insert a skeleton and drop
            // the caret inside the inner brackets so the page / block picker
            // opens right away; the trailing close brackets are absorbed on
            // commit (see `commitSelected`).
            if matches("embed") || matches("page-embed") {
                out.append(.commandInsertCaret(
                    label: "/page-embed", text: "{{embed [[]]}}", caretOffset: 10,
                    hint: "embed a page"))
            }
            if matches("embed") || matches("block-embed") {
                out.append(.commandInsertCaret(
                    label: "/block-embed", text: "{{embed (())}}", caretOffset: 10,
                    hint: "embed a block"))
            }
            // Live query (§17): a `{{query }}` skeleton with the caret inside,
            // ready to type a filter (e.g. `#tag TODO` or `(and …)`).
            if matches("query") {
                out.append(.commandInsertCaret(
                    label: "/query", text: "{{query }}", caretOffset: 8, hint: "live query"))
            }
            items = out
        }
    }

    // MARK: - Keyboard

    /// Returns true when the event was consumed by the popup.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        switch event.keyCode {
        case 125: // Down
            select(selectedIndex + 1)
            return true
        case 126: // Up
            select(selectedIndex - 1)
            return true
        case 36, 76, 48: // Return / keypad Enter / Tab
            commitSelected()
            return true
        case 53: // Esc
            dismiss()
            return true
        default:
            return false
        }
    }

    private func select(_ index: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = ((index % items.count) + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func commitSelected() {
        guard items.indices.contains(selectedIndex), let textView else {
            dismiss()
            return
        }
        let item = items[selectedIndex]
        let insertion: String
        switch item {
        case .page(let name), .createPage(let name):
            insertion = "[[\(name)]]"
        case .block(let hit):
            insertion = "((\(hit.blockID.uuidString.lowercased())))"
        case .tag(let name):
            insertion = name.contains(" ") ? "#[[\(name)]]" : "#\(name)"
        case .command(_, let text):
            insertion = text
        case .commandPrefix(_, let prefix, _):
            // Remove the trigger text, then prefix the whole block.
            let caret = textView.selectedRange().location
            let replaceRange = NSRange(
                location: triggerLocation, length: max(0, caret - triggerLocation)
            )
            dismiss()
            textView.insertText("", replacementRange: replaceRange)
            if !textView.string.hasPrefix(prefix) {
                textView.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
            }
            return
        case .commandInsertCaret(_, let text, let caretOffset, _):
            // Replace the trigger with `text`, then place the caret within it.
            let caret = textView.selectedRange().location
            let replaceRange = NSRange(
                location: triggerLocation, length: max(0, caret - triggerLocation)
            )
            let anchor = triggerLocation
            dismiss()
            textView.insertText(text, replacementRange: replaceRange)
            textView.setSelectedRange(NSRange(location: anchor + caretOffset, length: 0))
            // If the caret now sits inside a `[[` / `((` (e.g. an embed
            // skeleton), re-run detection so the page / block picker opens.
            textDidChange(in: textView)
            return
        case .commandLink, .commandDatePicker:
            // Remove the trigger; the host opens the relevant panel at the caret.
            let caret = textView.selectedRange().location
            let replaceRange = NSRange(
                location: triggerLocation, length: max(0, caret - triggerLocation)
            )
            dismiss()
            textView.insertText("", replacementRange: replaceRange)
            if case .commandDatePicker = item { onDateCommand() } else { onLinkCommand() }
            return
        }
        let caret = textView.selectedRange().location
        var replaceRange = NSRange(
            location: triggerLocation, length: max(0, caret - triggerLocation)
        )
        // When the brackets were pre-supplied by a skeleton (e.g. /page-embed's
        // `{{embed [[]]}}`), the picker's `[[name]]` / `((uuid))` would double
        // the close. Absorb a matching close sitting right after the caret.
        let close = mode == .pageRef ? "]]" : mode == .blockRef ? "))" : ""
        var absorbedClose = false
        if !close.isEmpty, insertion.hasSuffix(close) {
            let ns = textView.string as NSString
            let len = (close as NSString).length
            if caret + len <= ns.length,
               ns.substring(with: NSRange(location: caret, length: len)) == close {
                replaceRange.length += len
                absorbedClose = true
            }
        }
        // After completing any reference/tag (`[[Page]]`, `#tag`, `((block))`),
        // add a trailing space so you can keep typing; it's removed if the very
        // next key is Enter (see BlockEditorTextView). Skipped only when
        // completing inside a pre-bracketed skeleton (`{{embed [[]]}}` /
        // `{{embed (())}}`), where a space inside the braces would be wrong.
        let trailingSpace = absorbedClose ? "" : " "
        dismiss()
        // The insert below fires `textDidChange`; don't let it re-open the popup
        // (a committed `#tag` would otherwise immediately re-trigger).
        suppressNextChange = true
        textView.insertText(insertion + trailingSpace, replacementRange: replaceRange)
        if !trailingSpace.isEmpty, let editor = textView as? BlockEditorTextView {
            editor.pendingTrailingSpaceCaret = textView.selectedRange().location
        }
        if case .block(let hit) = item {
            onBlockRefInserted(hit)
        }
    }

    // MARK: - Panel UI

    private static let panelWidth: CGFloat = 380
    private static let rowHeight: CGFloat = 24

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = Self.panelWidth - 24
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        return table
    }()

    private lazy var panel: NSPanel = {
        let scroll = NSScrollView(frame: NSRect(x: 4, y: 4,
                                                width: Self.panelWidth - 8, height: 192))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0,
                                                      width: Self.panelWidth, height: 200))
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.addSubview(scroll)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }()

    private func presentPanel(anchoredTo textView: NSTextView) {
        let height = min(CGFloat(items.count) * (Self.rowHeight + 1) + 10, 240)
        // Position below the trigger character (screen coordinates).
        let anchor = textView.firstRect(
            forCharacterRange: NSRange(location: triggerLocation, length: 0), actualRange: nil
        )
        var frame = NSRect(
            x: anchor.minX, y: anchor.minY - height - 4,
            width: Self.panelWidth, height: height
        )
        if let screen = textView.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.minY < visible.minY { frame.origin.y = anchor.maxY + 4 }
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        }
        panel.setFrame(frame, display: false)
        if !isActive {
            textView.window?.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            isActive = true
        }
    }

    func dismiss() {
        guard isActive else { return }
        isActive = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        selectedIndex = 0
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        selectedIndex = row
        commitSelected()
    }
}

// MARK: - Table data source / delegate

extension AutocompleteController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("AutocompleteCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.autoresizingMask = [.width]
            field.frame = NSRect(x: 8, y: 3, width: Self.panelWidth - 40, height: 18)
            cell.addSubview(field)
            cell.textField = field
        }
        guard items.indices.contains(row) else { return cell }
        cell.textField?.attributedStringValue = Self.title(for: items[row])
        return cell
    }

    private static func title(for item: Item) -> NSAttributedString {
        let mainFont = NSFont.systemFont(ofSize: 12)
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        switch item {
        case .page(let name):
            return NSAttributedString(string: name, attributes: [
                .font: mainFont, .foregroundColor: NSColor.labelColor,
            ])
        case .createPage(let name):
            return NSAttributedString(string: "Create \u{201C}\(name)\u{201D}", attributes: [
                .font: mainFont, .foregroundColor: NSColor.controlAccentColor,
            ])
        case .block(let hit):
            let out = NSMutableAttributedString(
                string: hit.content.components(separatedBy: "\n").first ?? hit.content,
                attributes: [.font: mainFont, .foregroundColor: NSColor.labelColor]
            )
            out.append(NSAttributedString(string: "  \u{2014}  \(hit.pageDisplayName)",
                                          attributes: detailAttrs))
            return out
        case .tag(let name):
            return NSAttributedString(string: "#\(name)", attributes: [
                .font: mainFont, .foregroundColor: BlockRenderer.tagColor,
            ])
        case .command(let label, let insertion):
            let out = NSMutableAttributedString(string: label, attributes: [
                .font: mainFont, .foregroundColor: NSColor.labelColor,
            ])
            out.append(NSAttributedString(string: "  \(insertion)", attributes: detailAttrs))
            return out
        case .commandPrefix(let label, _, let hint),
             .commandInsertCaret(let label, _, _, let hint),
             .commandLink(let label, let hint),
             .commandDatePicker(let label, let hint):
            let out = NSMutableAttributedString(string: label, attributes: [
                .font: mainFont, .foregroundColor: NSColor.labelColor,
            ])
            out.append(NSAttributedString(string: "  \(hint)", attributes: detailAttrs))
            return out
        }
    }
}
