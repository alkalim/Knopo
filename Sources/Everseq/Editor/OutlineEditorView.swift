import SwiftUI
import AppKit
import EverseqCore

/// The outline editor (SPEC §5.4, §15): an AppKit NSTableView whose rows are
/// the visible blocks. The focused block edits raw Markdown in one shared
/// NSTextView; unfocused blocks render via BlockRenderer.
///
/// Public interface is stable: `OutlineEditorView(pageName:)` and
/// `OutlineEditorView(pageName:zoom:)`.
struct OutlineEditorView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String
    var zoom: UUID? = nil

    var body: some View {
        OutlineEditorRepresentable(
            app: app, nav: nav, pageName: pageName, zoom: zoom, dataVersion: app.dataVersion,
            // Reading these here makes the view (and updateNSView) react to find.
            findActive: nav.findActive, findQuery: nav.findQuery,
            findStepToken: nav.findStepToken, findForward: nav.findStepForward,
            // Reacts to a result-click's scroll-to/flash request.
            highlightToken: nav.highlightToken
        )
    }
}

private struct OutlineEditorRepresentable: NSViewRepresentable {
    let app: AppState
    let nav: Navigator
    let pageName: String
    let zoom: UUID?
    /// @Published on AppState; bumps on external/index changes so
    /// `updateNSView` runs and the controller can diff and reload.
    let dataVersion: Int
    let findActive: Bool
    let findQuery: String
    let findStepToken: Int
    let findForward: Bool
    let highlightToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OutlineTableView {
        let controller = OutlineEditorController(app: app, nav: nav)
        context.coordinator.controller = controller
        context.coordinator.find = nav.find
        nav.find.register(controller)
        controller.present(pageName: pageName, zoom: zoom)
        return controller.tableView
    }

    func updateNSView(_ nsView: OutlineTableView, context: Context) {
        context.coordinator.controller?.present(pageName: pageName, zoom: zoom)
        // Any registered outline driving this is fine; the coordinator dedupes.
        nav.find.sync(active: findActive, query: findQuery,
                      stepToken: findStepToken, forward: findForward)
    }

    static func dismantleNSView(_ nsView: OutlineTableView, coordinator: Coordinator) {
        if let controller = coordinator.controller {
            coordinator.find?.unregister(controller)
        }
    }

    @MainActor
    final class Coordinator {
        var controller: OutlineEditorController?
        weak var find: FindCoordinator?
    }
}

// MARK: - Self-sizing table view

/// The outline lives inside the page's SwiftUI ScrollView, so the table
/// reports its full content height as intrinsic size and never scrolls itself.
final class OutlineTableView: NSTableView {

    var onWidthChange: (() -> Void)?
    /// Returns true if the controller consumed the key (node-selection mode).
    var onKeyDown: ((NSEvent) -> Bool)?
    private var lastLayoutWidth: CGFloat = -1

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        let height = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 28
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 28))
    }

    override func layout() {
        if let column = tableColumns.first, abs(column.width - bounds.width) > 0.5 {
            column.width = bounds.width
        }
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            onWidthChange?()
        }
    }
}

// MARK: - Controller

/// Drives the outline table: row models, focus and the shared editor, all
/// structural operations (SPEC §5.4, §13), and commits back into AppState.
///
/// Reentrancy rule: after every commit the controller rebuilds rows from
/// `app.document(for:)` instead of holding stale copies; debounced-save
/// `dataVersion` bumps are diffed and skipped when nothing changed.
@MainActor
final class OutlineEditorController: NSObject {

    private struct Row {
        var block: Block
        var depth: Int
        var path: [Int]
        var hasChildren: Bool
        var rendered: NSAttributedString
    }

    private let app: AppState
    private let nav: Navigator
    let tableView = OutlineTableView()
    private let editor: BlockEditorTextView
    private let autocomplete = AutocompleteController()
    private let linkPanel = LinkPanelController()
    private let datePanel = DatePanelController()

    private(set) var pageName = ""
    private(set) var zoom: UUID?
    private var rows: [Row] = []
    private var focusedBlockID: UUID?
    /// Last `nav.highlightToken` this outline acted on, so a scroll-to/flash
    /// request fires exactly once per click.
    private var lastHighlightToken = 0
    /// Block whose bullet context menu is open, for its color submenu actions.
    private var contextMenuBlockID: UUID?
    /// The block currently being rendered, so a `{{query}}` can exclude itself.
    private var renderingBlockID: UUID?
    /// Snapshot when the edit session started; structural ops batch all
    /// keystrokes since then into one undo step (SPEC §13).
    private var editSessionBefore: PageDocument?
    /// True while the link panel holds focus; suppresses end-of-edit teardown
    /// when the editor temporarily resigns first responder (§5.5.2).
    private var suppressFocusLoss = false
    /// Bracket setting the cached rows were rendered with; a change forces a
    /// re-render (cached `NSAttributedString`s don't otherwise update).
    private var renderedWithBrackets = BlockRenderer.bracketsEnabled
    private var renderedWithZoom = BlockRenderer.zoom
    private var renderedWithDensity = BlockRenderer.density

    // Node selection (SPEC §13): block-level multi-select when not editing.
    private var selectedRows: Set<Int> = []
    private var selectionAnchor: Int?

    // In-page find (Cmd+F) — this outline's slice, driven by FindCoordinator.
    private var findActive = false
    private var findQuery = ""
    private var findMatches: [(row: Int, range: NSRange)] = []
    /// Index into `findMatches` that is the window-global current match, or nil.
    private var findCurrentLocal: Int?

    init(app: AppState, nav: Navigator) {
        self.app = app
        self.nav = nav
        self.editor = BlockEditorTextView.create()
        super.init()
        editor.actions = self
        editor.autocomplete = autocomplete
        setUpTable()
        setUpAutocomplete()
    }

    private func setUpTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = []
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsColumnReordering = false
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onWidthChange = { [weak self] in self?.widthDidChange() }
        tableView.onKeyDown = { [weak self] in self?.handleSelectionKeyDown($0) ?? false }
    }

    private func setUpAutocomplete() {
        // `[[`: fuzzy page list ordered by recency (SPEC §6.1).
        autocomplete.fetchPages = { [weak self] query in
            self?.app.pageNames(matching: query) ?? []
        }
        // `((`: full-text block search (SPEC §7.1).
        autocomplete.fetchBlocks = { [weak self] query in
            guard let self else { return [] }
            return (try? self.app.store.cache.searchBlocks(query, limit: 20)) ?? []
        }
        // `#`: existing tags by prefix (SPEC §8.2).
        autocomplete.fetchTags = { [weak self] prefix in
            guard let self else { return [] }
            return (try? self.app.store.cache.tags(withPrefix: prefix)) ?? []
        }
        // Inserting `((uuid))` persists `id::` in the hit's source page (§7.1).
        autocomplete.onBlockRefInserted = { [weak self] hit in
            guard let self else { return }
            try? self.app.store.persistBlockID(hit.blockID, inPageNamed: hit.pageDisplayName)
            self.app.dataVersion += 1
        }
        // `/link`: open the two-field panel at the caret (§5.5.2).
        autocomplete.onLinkCommand = { [weak self] in self?.presentLinkPanel() }
        // `/date`: open the calendar at the caret (§5.5.4).
        autocomplete.onDateCommand = { [weak self] in self?.presentDatePicker() }
    }

    /// Opens the link panel; on confirm inserts `[label](url)` at the caret
    /// where the `/link` trigger was removed.
    private func presentLinkPanel() {
        guard focusedBlockID != nil else { return }
        let caret = editor.selectedRange().location
        let prefill = LinkPanelController.plausibleURL(
            NSPasteboard.general.string(forType: .string))
        suppressFocusLoss = true
        linkPanel.present(anchoredTo: editor, clipboardURL: prefill) { [weak self] result in
            guard let self else { return }
            self.suppressFocusLoss = false
            self.tableView.window?.makeFirstResponder(self.editor)
            guard let (label, url) = result else { return }
            let markdown = "[\(label)](\(url))"
            let loc = min(caret, (self.editor.string as NSString).length)
            self.editor.setSelectedRange(NSRange(location: loc, length: 0))
            self.editor.insertText(markdown, replacementRange: NSRange(location: loc, length: 0))
            self.editor.setSelectedRange(
                NSRange(location: loc + (markdown as NSString).length, length: 0))
        }
    }

    /// Opens the date picker; on confirm inserts `[[<ISO date>]]` for the chosen
    /// day at the caret where the `/date` trigger was removed (§5.5.4).
    private func presentDatePicker() {
        guard focusedBlockID != nil else { return }
        let caret = editor.selectedRange().location
        suppressFocusLoss = true
        datePanel.present(anchoredTo: editor, initialDate: Date()) { [weak self] date in
            guard let self else { return }
            self.suppressFocusLoss = false
            self.tableView.window?.makeFirstResponder(self.editor)
            guard let date else { return }
            let ref = "[[\(JournalDate(date: date).pageName)]]"
            let loc = min(caret, (self.editor.string as NSString).length)
            self.editor.setSelectedRange(NSRange(location: loc, length: 0))
            self.editor.insertText(ref, replacementRange: NSRange(location: loc, length: 0))
            self.editor.setSelectedRange(
                NSRange(location: loc + (ref as NSString).length, length: 0))
        }
    }

    // MARK: - Presentation / reload

    func present(pageName: String, zoom: UUID?) {
        // `zoom` here is the block-zoom UUID; `BlockRenderer.zoom` is the content
        // font-zoom — both flow through here.
        let bracketsChanged = BlockRenderer.bracketsEnabled != renderedWithBrackets
        let fontZoomChanged = BlockRenderer.zoom != renderedWithZoom
        let densityChanged = BlockRenderer.density != renderedWithDensity
        renderedWithBrackets = BlockRenderer.bracketsEnabled
        renderedWithZoom = BlockRenderer.zoom
        renderedWithDensity = BlockRenderer.density
        if pageName != self.pageName || zoom != self.zoom {
            self.pageName = pageName
            self.zoom = zoom
            focusedBlockID = nil
            editSessionBefore = nil
            autocomplete.dismiss()
            editor.removeFromSuperview()
            rebuildRows()
            tableView.reloadData()
            tableView.invalidateIntrinsicContentSize()
        } else if bracketsChanged || fontZoomChanged || densityChanged {
            // A global rendering preference flipped (brackets, content zoom, or
            // text density): re-render the cached rows and re-measure heights.
            reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                ? editor.selectedRange() : nil)
        } else {
            refreshIfChanged()
        }
        // A freshly created page focuses its first block so you can type at once
        // (set by `Navigator.navigateToNewPage`). Deferred so the table is laid
        // out and in a window; cleared on consume so it fires once.
        if nav.focusFirstBlock == pageName {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pageName == pageName,
                      self.nav.focusFirstBlock == pageName else { return }
                self.nav.focusFirstBlock = nil
                if let first = self.rows.first?.block.id {
                    self.focusBlock(first, selection: NSRange(location: 0, length: 0))
                }
            }
        }
        applyPendingHighlightIfNeeded()
    }

    /// Scrolls to and flashes a block when a result click requested it (and the
    /// request is for the page this outline shows). Matches by id, then by
    /// content — block ids drift across re-parses unless `id::`-pinned.
    private func applyPendingHighlightIfNeeded() {
        guard nav.highlightToken != lastHighlightToken else { return }
        guard let hl = nav.highlightTarget, hl.pageKey == PageName.key(pageName) else { return }
        lastHighlightToken = nav.highlightToken
        guard let index = rows.firstIndex(where: { $0.block.id == hl.blockID })
            ?? rows.firstIndex(where: { $0.block.content == hl.content }) else { return }
        let blockID = rows[index].block.id
        // Defer so the table finishes its post-reload layout — the row→cell
        // mapping is briefly stale right after reloadData, so a cell fetched too
        // early lands on the wrong row.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableView.layoutSubtreeIfNeeded()
            guard let row = self.rows.firstIndex(where: { $0.block.id == blockID }) else { return }
            self.tableView.scrollRowToVisible(row)
            self.tableView.layoutSubtreeIfNeeded()
            if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? OutlineRowCell {
                cell.flash()
            }
        }
    }

    /// Diffs the store's current state against the displayed rows; reloads
    /// (preserving focus) only when something actually changed — the common
    /// no-op being our own debounced save bumping `dataVersion`.
    private func refreshIfChanged() {
        let doc = app.document(for: pageName)
        let fresh = OutlineOps.visibleRows(in: doc.blocks, zoomRoot: zoom)
        guard !matchesCurrent(fresh) else { return }
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
            ? editor.selectedRange() : nil)
    }

    private func matchesCurrent(_ fresh: [OutlineOps.VisibleRow]) -> Bool {
        guard fresh.count == rows.count else { return false }
        for (a, b) in zip(fresh, rows) {
            if a.block.id != b.block.id
                || a.block.content != b.block.content
                || a.block.properties != b.block.properties
                || a.block.collapsed != b.block.collapsed
                || a.depth != b.depth
                || a.hasChildren != b.hasChildren {
                return false
            }
        }
        return true
    }

    private func rebuildRows() {
        let doc = app.document(for: pageName)
        rows = OutlineOps.visibleRows(in: doc.blocks, zoomRoot: zoom).map {
            Row(block: $0.block, depth: $0.depth, path: $0.path,
                hasChildren: $0.hasChildren, rendered: renderBlock($0.block))
        }
    }

    private func render(_ content: String) -> NSAttributedString {
        BlockRenderer.render(content: content, context: BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: false, // the row cell draws one continuous bar
            resolveEmbed: { [weak self] target in self?.renderEmbed(target) },
            resolveQuery: { [weak self] expr in self?.renderQuery(expr) }
        ))
    }

    private func renderEmbed(_ target: EmbedTarget) -> NSAttributedString? {
        renderEmbed(target, embedDepth: 0, visited: [])
    }

    /// A 6px filled circle inline bullet (matching `BulletView`'s dot), as a
    /// text attachment so it renders at a fixed size regardless of font and sits
    /// vertically centered on the line. Followed by a small gap.
    private static let embedBulletImage: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 6))
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 6, height: 6)).fill()
        image.unlockFocus()
        return image
    }()

    private static func embedBullet() -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = embedBulletImage
        // Center the 6px dot against the x-height of the 14pt body line.
        attachment.bounds = CGRect(x: 0, y: 2, width: 6, height: 6)
        let bullet = NSMutableAttributedString(attachment: attachment)
        bullet.append(NSAttributedString(string: "  ", attributes: [.font: BlockRenderer.baseFont()]))
        return bullet
    }

    /// Read-only render of a `{{embed …}}` target's subtree (§7.6): an indented,
    /// bulleted, navigable transclusion with a left bar to mark it as embedded.
    /// Nested embeds resolve up to `maxEmbedDepth`; cycles (a target already in
    /// `visited`) and over-deep nesting return nil → rendered literally.
    private func renderEmbed(
        _ target: EmbedTarget, embedDepth: Int, visited: Set<EmbedTarget>
    ) -> NSAttributedString? {
        guard embedDepth < 4, !visited.contains(target) else { return nil }
        let rootBlocks: [Block]
        let link: URL
        switch target {
        case .block(let id):
            guard let hit = app.store.resolveBlock(id) else { return nil }
            rootBlocks = [hit.block]
            link = EverseqURL.block(id)
        case .page(let name):
            let blocks = app.document(for: name).blocks
            guard !blocks.isEmpty else { return nil }
            rootBlocks = blocks
            link = EverseqURL.page(name)
        }
        // Nested embeds resolve through this context, with the chain tracked so
        // cycles break instead of looping.
        let nextVisited = visited.union([target])
        let inner = BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: true,
            resolveEmbed: { [weak self] t in
                self?.renderEmbed(t, embedDepth: embedDepth + 1, visited: nextVisited)
            }
        )
        let body = NSMutableAttributedString()
        var count = 0
        func walk(_ blocks: [Block], depth: Int) {
            for block in blocks {
                guard count < 40 else { return } // cap huge embeds
                count += 1
                if body.length > 0 {
                    body.append(NSAttributedString(string: "\n",
                                                   attributes: [.font: BlockRenderer.baseFont()]))
                }
                // Indent + a real 6px bullet (a drawn circle, not a glyph) so it
                // matches the outline's bullets exactly; the cell background
                // marks the region as embedded.
                body.append(NSAttributedString(string: String(repeating: "    ", count: depth),
                                               attributes: [.font: BlockRenderer.baseFont()]))
                body.append(Self.embedBullet())
                body.append(BlockRenderer.render(content: block.content, context: inner))
                if !block.collapsed { walk(block.children, depth: depth + 1) }
            }
        }
        walk(rootBlocks, depth: 0)
        guard body.length > 0 else { return nil }
        // Breathing room between embedded blocks and within multi-line ones, so
        // a transclusion isn't cramped (matches the query-result treatment).
        finishRegion(body, linkAll: link, interlineSpacing: 6, lineSpacing: 4) // click → source
        return body
    }

    /// Common finishing for a generated, read-only region (an embed's subtree or
    /// a query's results): marks the `.embedRegion` so the cell draws the grey
    /// box, pins line height, adds vertical breathing room, and insets the whole
    /// thing horizontally (baked into the paragraph styles so row-height
    /// measurement stays consistent). `linkAll` makes the whole region one click
    /// target (embeds → their source); query results set per-line links and pass
    /// nil.
    private func finishRegion(
        _ body: NSMutableAttributedString, linkAll: URL?,
        interlineSpacing: CGFloat = 0, lineSpacing: CGFloat = 0
    ) {
        guard body.length > 0 else { return }
        let full = NSRange(location: 0, length: body.length)
        if let linkAll { body.addAttribute(.link, value: linkAll, range: full) }
        body.addAttribute(.embedRegion, value: true, range: full)
        BlockRenderer.pinLineHeight(body, BlockRenderer.lineHeight(forSource: ""))
        let ns = body.string as NSString
        let firstBreak = ns.range(of: "\n").location
        addParagraphSpacing(to: body, before: 8,
                            range: NSRange(location: 0,
                                           length: firstBreak == NSNotFound ? body.length : firstBreak))
        let lastBreak = ns.range(of: "\n", options: .backwards).location
        if lastBreak != NSNotFound {
            addParagraphSpacing(to: body, after: 8,
                                range: NSRange(location: lastBreak + 1,
                                               length: body.length - lastBreak - 1))
        } else {
            addParagraphSpacing(to: body, after: 8, range: full)
        }
        let leftPad: CGFloat = 14, rightPad: CGFloat = 14
        body.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)
                .flatMap { $0.mutableCopy() as? NSMutableParagraphStyle } ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += leftPad
            style.headIndent += leftPad
            if style.tailIndent == 0 { style.tailIndent = -rightPad }
            // Breathing room between rows (paragraphs) so a result list isn't
            // cramped; keeps the larger boundary spacing on the first/last line.
            if interlineSpacing > 0 {
                style.paragraphSpacing = max(style.paragraphSpacing, interlineSpacing)
            }
            // …and between the wrapped/hard-broken lines *within* one block.
            if lineSpacing > 0 {
                style.lineSpacing = max(style.lineSpacing, lineSpacing)
            }
            body.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Read-only render of a `{{query …}}` expression's results (§17): matching
    /// blocks grouped by page, capped, click-to-navigate. The host block (set in
    /// `renderBlock`) is excluded so a query never lists itself.
    private func renderQuery(_ expr: QueryExpr) -> NSAttributedString? {
        let cap = 50
        guard let result = try? app.store.cache.runQuery(
            expr, excluding: renderingBlockID, limit: cap) else { return nil }

        let body = NSMutableAttributedString()
        func line(_ piece: NSAttributedString) {
            if body.length > 0 {
                body.append(NSAttributedString(string: "\n",
                                               attributes: [.font: BlockRenderer.baseFont()]))
            }
            body.append(piece)
        }

        if result.hits.isEmpty {
            line(NSAttributedString(string: "No matching blocks", attributes: [
                .font: BlockRenderer.baseFont(), .foregroundColor: NSColor.tertiaryLabelColor]))
            finishRegion(body, linkAll: nil, interlineSpacing: 9, lineSpacing: 4)
            return body
        }

        let inner = BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: true)
        var lastPage: String?
        for hit in result.hits {
            if hit.pageDisplayName != lastPage {
                lastPage = hit.pageDisplayName
                // Journal pages show their pretty date ("Apr 21st, 2026"), not
                // the raw ISO / Logseq underscore filename form.
                let title = JournalDate(pageName: hit.pageDisplayName)?.displayName
                    ?? hit.pageDisplayName
                line(NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .link: EverseqURL.page(hit.pageDisplayName)]))
            }
            let row = NSMutableAttributedString(
                string: "    ", attributes: [.font: BlockRenderer.baseFont()])
            row.append(Self.embedBullet())
            row.append(BlockRenderer.render(content: hit.content, context: inner))
            // The whole result row navigates to that block. Carry the page name
            // (not a bare block id) — the index id may not survive a re-parse,
            // so a name-less block link can fail to resolve its page.
            row.addAttribute(.link,
                             value: EverseqURL.block(hit.blockID, onPage: hit.pageDisplayName),
                             range: NSRange(location: 0, length: row.length))
            line(row)
        }
        if result.total > result.hits.count {
            line(NSAttributedString(
                string: "showing \(result.hits.count) of \(result.total)", attributes: [
                    .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize - 2),
                    .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        finishRegion(body, linkAll: nil, interlineSpacing: 9, lineSpacing: 4)
        return body
    }

    /// Adjusts the paragraph spacing on a range, preserving the pinned line
    /// height and other paragraph attributes already set.
    private func addParagraphSpacing(
        to string: NSMutableAttributedString, before: CGFloat = 0, after: CGFloat = 0,
        range: NSRange
    ) {
        guard range.length > 0, range.location < string.length else { return }
        let base = (string.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if before > 0 { base.paragraphSpacingBefore = before }
        if after > 0 { base.paragraphSpacing = after }
        string.addAttribute(.paragraphStyle, value: base, range: range)
    }

    /// Renders a block's content plus a dimmed `key:: value` area for its user
    /// properties, so properties are visible (and editable on focus) — §3.2.
    private func renderBlock(_ block: Block) -> NSAttributedString {
        // Tracked so a `{{query}}` can exclude its own host block from results.
        renderingBlockID = block.id
        defer { renderingBlockID = nil }
        let out = render(block.content).mutableCopy() as! NSMutableAttributedString
        guard !block.properties.isEmpty else { return out }
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for prop in block.properties where !Block.hiddenPropertyKeys.contains(prop.key) {
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: valueAttrs))
            }
            out.append(NSAttributedString(string: "\(prop.key): ", attributes: keyAttrs))
            out.append(NSAttributedString(string: prop.value, attributes: valueAttrs))
        }
        // Re-pin the line height so the appended property lines match (and so
        // focused/unfocused heights stay equal — same lines, same metrics).
        BlockRenderer.pinLineHeight(out, BlockRenderer.lineHeight(forSource: block.content))
        return out
    }

    /// Full reload from the store, then re-attaches the shared editor to the
    /// given block (if still visible).
    private func reloadAndFocus(_ id: UUID?, selection: NSRange?) {
        rebuildRows()
        tableView.reloadData()
        tableView.invalidateIntrinsicContentSize()
        if let id, rows.contains(where: { $0.block.id == id }) {
            attachEditor(to: id, selection: selection, startSession: false)
        } else {
            focusedBlockID = nil
            editor.removeFromSuperview()
        }
    }

    private func reloadRow(_ index: Int) {
        guard index >= 0, index < tableView.numberOfRows else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)
        )
        noteHeightChanged([index])
    }

    private func noteHeightChanged(_ indexes: [Int]) {
        let valid = IndexSet(indexes.filter { $0 >= 0 && $0 < tableView.numberOfRows })
        guard !valid.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: valid)
        }
        tableView.invalidateIntrinsicContentSize()
    }

    private func widthDidChange() {
        // Deferred: noteHeightOfRows inside layout would recurse.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let count = min(self.rows.count, self.tableView.numberOfRows)
            if count > 0 {
                self.noteHeightChanged(Array(0..<count))
            } else {
                self.tableView.invalidateIntrinsicContentSize()
            }
        }
    }

    // MARK: - Focus and the shared editor

    func focusBlock(_ id: UUID, selection: NSRange?) {
        if hasSelection { selectedRows = []; selectionAnchor = nil } // editing exits node selection
        flushEditSessionUndo() // close the previous block's typing into one undo step
        let previous = focusedBlockID
        attachEditor(to: id, selection: selection, startSession: true)
        if let previous, previous != id,
           let prevIndex = rows.firstIndex(where: { $0.block.id == previous }) {
            rows[prevIndex].rendered = renderBlock(rows[prevIndex].block)
            reloadRow(prevIndex)
        }
    }

    private func attachEditor(to id: UUID, selection: NSRange?, startSession: Bool) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        if startSession && focusedBlockID != id {
            editSessionBefore = app.document(for: pageName)
        }
        focusedBlockID = id
        // Edit the full source — content plus user `key:: value` lines (§3.2).
        editor.setContent(rows[index].block.editableSource)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? OutlineRowCell else { return }
        cell.embedEditor(editor)
        cell.setBulletHidden(false) // the focused block always shows its bullet
        if let selection {
            let length = (editor.string as NSString).length
            let location = min(max(0, selection.location), length)
            editor.setSelectedRange(NSRange(
                location: location, length: min(selection.length, length - location)
            ))
        }
        tableView.window?.makeFirstResponder(editor)
        noteHeightChanged([index])
    }

    func endEditing() {
        guard let id = focusedBlockID else { return }
        flushEditSessionUndo()
        autocomplete.dismiss()
        focusedBlockID = nil
        editSessionBefore = nil
        editor.removeFromSuperview()
        if tableView.window?.firstResponder === editor {
            tableView.window?.makeFirstResponder(tableView)
        }
        if let index = rows.firstIndex(where: { $0.block.id == id }) {
            rows[index].rendered = renderBlock(rows[index].block)
            reloadRow(index)
        }
    }

    // MARK: - Node selection (SPEC §13)

    private var hasSelection: Bool { !selectedRows.isEmpty }

    private func setSelection(_ rows: Set<Int>, anchor: Int?) {
        selectedRows = rows
        selectionAnchor = anchor
        tableView.reloadData()
    }

    private func clearSelection() {
        guard hasSelection else { return }
        setSelection([], anchor: nil)
    }

    /// Returns true when consumed. Active only when not text-editing.
    private func handleSelectionKeyDown(_ event: NSEvent) -> Bool {
        guard focusedBlockID == nil, !rows.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 126: // Up
            guard hasSelection else { return false }
            if flags.contains(.option) { moveSelection(by: -1) }
            else { stepSelection(up: true, extend: flags.contains(.shift)) }
            return true
        case 125: // Down
            guard hasSelection else { return false }
            if flags.contains(.option) { moveSelection(by: 1) }
            else { stepSelection(up: false, extend: flags.contains(.shift)) }
            return true
        case 36, 76: // Return → edit the anchor block
            guard hasSelection, let i = selectionAnchor ?? selectedRows.min(),
                  rows.indices.contains(i) else { return false }
            let id = rows[i].block.id
            clearSelection()
            focusBlock(id, selection: nil)
            return true
        case 51, 117: // Delete / forward-delete
            guard hasSelection else { return false }
            deleteSelection()
            return true
        case 48: // Tab / Shift+Tab — single-selection only (multi is ambiguous)
            guard selectedRows.count == 1, let i = selectedRows.first else { return hasSelection }
            indentOutdentSelected(row: i, outdent: flags.contains(.shift))
            return true
        case 53: // Esc clears selection
            guard hasSelection else { return false }
            clearSelection()
            return true
        case 8 where flags.contains(.command): // Cmd+C
            guard hasSelection else { return false }
            copySelection()
            return true
        case 9 where flags.contains(.command): // Cmd+V
            guard hasSelection else { return false }
            pasteSelection()
            return true
        case 0 where flags.contains(.command): // Cmd+A
            setSelection(Set(rows.indices), anchor: 0)
            return true
        default:
            return false
        }
    }

    private func stepSelection(up: Bool, extend: Bool) {
        let bound = up ? (selectedRows.min() ?? 0) - 1 : (selectedRows.max() ?? -1) + 1
        guard rows.indices.contains(bound) else { return }
        if extend {
            selectedRows.insert(bound)
        } else {
            selectedRows = [bound]
            selectionAnchor = bound
        }
        tableView.reloadData()
        tableView.scrollRowToVisible(bound)
    }

    /// Click-driven selection: shift extends a contiguous range from the
    /// anchor; cmd toggles a single row.
    func selectViaClick(_ id: UUID, extend: Bool, toggle: Bool) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        if focusedBlockID != nil { endEditing() }
        if toggle {
            if selectedRows.contains(index) { selectedRows.remove(index) }
            else { selectedRows.insert(index); selectionAnchor = index }
            tableView.reloadData()
        } else if extend, let anchor = selectionAnchor {
            setSelection(Set(min(anchor, index)...max(anchor, index)), anchor: anchor)
        } else {
            setSelection([index], anchor: index)
        }
        tableView.window?.makeFirstResponder(tableView)
    }

    /// Selected rows whose ancestor isn't *also* selected. `copyMarkdown` emits a
    /// block with its whole subtree, so a selected descendant is already covered
    /// by its selected ancestor — treating only the top-most ones avoids
    /// duplicating nested blocks on copy and gives paste a sane anchor.
    private func topMostSelectedRows() -> [Int] {
        let selectedPaths = Set(selectedRows.compactMap {
            rows.indices.contains($0) ? rows[$0].path : nil
        })
        return selectedRows.sorted().filter { row in
            guard rows.indices.contains(row) else { return false }
            let path = rows[row].path
            return !(1..<path.count).contains { selectedPaths.contains(Array(path.prefix($0))) }
        }
    }

    private func copySelection() {
        let doc = app.document(for: pageName)
        let markdown = topMostSelectedRows().compactMap { row -> String? in
            guard let block = doc.blocks.block(id: rows[row].block.id) else { return nil }
            return OutlineOps.copyMarkdown(block)
        }.joined()
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    /// Cmd+V in node-selection mode: paste the clipboard's blocks right after the
    /// last top-most selected block (as its sibling), then select the result.
    /// (In edit mode the text view handles paste itself.)
    private func pasteSelection() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let pasted = OutlineOps.blocksFromPasted(text)
        guard !pasted.isEmpty, let anchorRow = topMostSelectedRows().last,
              rows.indices.contains(anchorRow) else { return }
        var doc = app.document(for: pageName)
        guard var insertAt = doc.blocks.path(to: rows[anchorRow].block.id) else { return }
        insertAt[insertAt.count - 1] += 1 // after the anchor block (and its subtree)
        for (i, block) in pasted.enumerated() {
            var p = insertAt
            p[p.count - 1] += i
            doc.blocks.insert(block, at: p)
        }
        commitStructural(doc, label: "Paste")
        clearSelection()
        reloadAndFocus(nil, selection: nil)
        let pastedIDs = Set(pasted.map(\.id))
        let newSel = Set(rows.indices.filter { pastedIDs.contains(rows[$0].block.id) })
        if let anchor = newSel.min() { setSelection(newSel, anchor: anchor) }
    }

    private func deleteSelection() {
        let ids = selectedRows.sorted().compactMap { rows.indices.contains($0) ? rows[$0].block.id : nil }
        guard !ids.isEmpty else { return }
        // Aggregate incoming block-references over every selected subtree (§7.4).
        var subtreeIDs: [UUID] = []
        let doc0 = app.document(for: pageName)
        for id in ids {
            guard let block = doc0.blocks.block(id: id) else { continue }
            subtreeIDs.append(contentsOf: [id] + block.children.flattened.map(\.id))
        }
        let count = (try? app.store.cache.incomingRefCount(forBlockIDs: subtreeIDs)) ?? 0
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "These blocks are referenced in \(count) place\(count == 1 ? "" : "s"). Delete anyway?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var doc = app.document(for: pageName)
        Self.removeBlocks(Set(ids), from: &doc.blocks)
        if doc.blocks.isEmpty { doc.blocks = [Block(content: "")] } // keep one block
        commitStructural(doc, label: ids.count == 1 ? "Delete Block" : "Delete Blocks")
        clearSelection()
        reloadAndFocus(nil, selection: nil)
    }

    /// Recursively drops any block whose id is in `ids` (with its subtree).
    private static func removeBlocks(_ ids: Set<UUID>, from blocks: inout [Block]) {
        blocks.removeAll { ids.contains($0.id) }
        for i in blocks.indices { removeBlocks(ids, from: &blocks[i].children) }
    }

    private func indentOutdentSelected(row i: Int, outdent: Bool) {
        guard rows.indices.contains(i) else { return }
        let id = rows[i].block.id
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              (outdent ? OutlineOps.outdent(path, in: &doc.blocks)
                       : OutlineOps.indent(path, in: &doc.blocks)) else { return }
        commitStructural(doc, label: outdent ? "Outdent" : "Indent")
        reloadAndFocus(nil, selection: nil)
        if let newIndex = rows.firstIndex(where: { $0.block.id == id }) {
            setSelection([newIndex], anchor: newIndex)
        }
    }

    private func moveSelection(by delta: Int) {
        guard selectedRows.count == 1, let i = selectedRows.first, rows.indices.contains(i) else { return }
        let id = rows[i].block.id
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              OutlineOps.move(path, by: delta, in: &doc.blocks) else { return }
        commitStructural(doc, label: "Move Block")
        reloadAndFocus(nil, selection: nil)
        if let newIndex = rows.firstIndex(where: { $0.block.id == id }) {
            setSelection([newIndex], anchor: newIndex)
        }
    }

    // MARK: - Commits

    /// Structural ops record one undo entry against the session-start snapshot,
    /// so a burst of keystrokes plus the op is a single undo step (SPEC §13).
    private func commitStructural(_ doc: PageDocument, label: String) {
        let before = editSessionBefore ?? app.document(for: pageName)
        app.commit(doc, undoLabel: label, before: before)
        editSessionBefore = doc
    }

    /// Closes the current text-editing session into a single undo step. Plain
    /// typing (content or properties) commits without undo entries; this turns
    /// "everything typed in this block since focus" into one undoable change,
    /// so Cmd+Z after editing doesn't jump to a far older state.
    private func flushEditSessionUndo() {
        guard let before = editSessionBefore, let id = focusedBlockID else { return }
        let current = app.document(for: pageName)
        guard let b = before.blocks.block(id: id), let c = current.blocks.block(id: id) else {
            return
        }
        if b.content != c.content || b.properties != c.properties {
            app.commit(current, undoLabel: "Edit Block", before: before)
        }
        editSessionBefore = current
    }

    // MARK: - Row actions

    private func rowCallbacks(for id: UUID) -> OutlineRowCallbacks {
        OutlineRowCallbacks(
            toggleFold: { [weak self] in self?.toggleFold(id) },
            zoomIn: { [weak self] in
                guard let self else { return }
                // Clicking the bullet zooms into the block (SPEC §5.4).
                self.nav.navigate(to: .page(name: self.pageName, zoom: id))
            },
            showContextMenu: { [weak self] event, view in
                self?.showContextMenu(for: id, event: event, in: view)
            },
            openLink: { [weak self] url, inSidebar in
                self?.handleLink(url, blockID: id, inSidebar: inSidebar)
            },
            focusContent: { [weak self] renderedIndex in
                self?.focusFromClick(id, renderedIndex: renderedIndex)
            },
            selectBlock: { [weak self] extend, toggle in
                self?.selectViaClick(id, extend: extend, toggle: toggle)
            },
            pagePreview: { [weak self] name in
                self?.previewAttributedString(forPage: name)
            }
        )
    }

    private func toggleFold(_ id: UUID) {
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        doc.blocks.update(at: path) { $0.collapsed.toggle() }
        app.commit(doc)
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
            ? editor.selectedRange() : nil)
    }

    private func handleLink(_ url: URL, blockID: UUID, inSidebar: Bool) {
        // The rendered TODO/DONE checkbox carries this URL (SPEC §5.2).
        if url.absoluteString == "everseq://toggle-todo" {
            toggleTodo(blockID)
            return
        }
        nav.openURL(url, inSidebar: inSidebar)
    }

    private func toggleTodo(_ id: UUID) {
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let block = doc.blocks.block(at: path),
              let state = block.todoState else { return }
        let rest = String(block.content.dropFirst(state.rawValue.count))
        doc.blocks.update(at: path) { $0.content = state.toggled.rawValue + rest }
        app.commit(doc, undoLabel: state == .todo ? "Mark Done" : "Mark Todo")
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
            ? editor.selectedRange() : nil)
    }

    private func focusFromClick(_ id: UUID, renderedIndex: Int) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        // Approximate caret placement: rendered text matches raw source for
        // plain blocks; clamp when markup makes the lengths differ.
        let length = (rows[index].block.content as NSString).length
        focusBlock(id, selection: NSRange(location: min(max(0, renderedIndex), length), length: 0))
    }

    /// First ~10 blocks of a page for the hover preview popover (SPEC §6.1).
    private func previewAttributedString(forPage name: String) -> NSAttributedString? {
        let doc = app.document(for: name)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: doc.displayTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]))
        for row in OutlineOps.visibleRows(in: doc.blocks).prefix(10) {
            let indent = String(repeating: "    ", count: row.depth)
            out.append(NSAttributedString(string: "\n\(indent)\u{2022} ", attributes: [
                .font: BlockRenderer.baseFont(),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            out.append(renderForPreview(row.block.content))
        }
        // A preview is a non-interactive glance — drop link styling so refs/embeds
        // don't show as blue underlined links (and no `everseq://` tooltips).
        out.removeAttribute(.link, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Like `render(_:)` but for a hover preview: embeds and queries are *not*
    /// expanded (they'd recursively transclude / run a query inside a tiny
    /// popover) — they show as a muted chip instead.
    private func renderForPreview(_ content: String) -> NSAttributedString {
        BlockRenderer.render(content: content, context: BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: false))
    }

    private func createFirstBlock() {
        var doc = app.document(for: pageName)
        let block = Block(content: "")
        if let zoom, let path = doc.blocks.path(to: zoom) {
            doc.blocks.update(at: path) {
                $0.children.append(block)
                $0.collapsed = false
            }
        } else {
            doc.blocks.append(block)
        }
        app.commit(doc, undoLabel: "New Block")
        reloadAndFocus(block.id, selection: NSRange(location: 0, length: 0))
    }

    // MARK: - Context menu (SPEC §7.1, §13)

    private func showContextMenu(for id: UUID, event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let copyRef = NSMenuItem(
            title: "Copy Block Reference", action: #selector(copyBlockRef(_:)), keyEquivalent: ""
        )
        copyRef.target = self
        copyRef.representedObject = id
        menu.addItem(copyRef)
        let copyMarkdown = NSMenuItem(
            title: "Copy Subtree as Markdown",
            action: #selector(copySubtreeMarkdown(_:)), keyEquivalent: ""
        )
        copyMarkdown.target = self
        copyMarkdown.representedObject = id
        menu.addItem(copyMarkdown)

        menu.addItem(.separator())
        contextMenuBlockID = id
        let colorItem = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: "")
        colorItem.submenu = backgroundColorMenu(for: id)
        menu.addItem(colorItem)

        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: "Delete Block", action: #selector(deleteBlockAction(_:)), keyEquivalent: ""
        )
        delete.target = self
        delete.representedObject = id
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// The color palette submenu (Logseq-style). A checkmark marks the block's
    /// current color; "None" clears it.
    private func backgroundColorMenu(for id: UUID) -> NSMenu {
        let current = app.document(for: pageName).blocks.block(id: id)?
            .properties.first { $0.key == BlockColor.propertyKey }?.value
        let submenu = NSMenu()
        let none = NSMenuItem(title: "None", action: #selector(setBlockColor(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""        // empty = clear
        none.state = current == nil ? .on : .off
        submenu.addItem(none)
        submenu.addItem(.separator())
        for color in BlockColor.allCases {
            let item = NSMenuItem(
                title: color.displayName, action: #selector(setBlockColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.image = Self.colorSwatch(color.swatch)
            item.state = current == color.rawValue ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    /// A small filled-circle swatch for a color menu item.
    private static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func setBlockColor(_ sender: NSMenuItem) {
        guard let id = contextMenuBlockID, let name = sender.representedObject as? String else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        doc.blocks.update(at: path) { block in
            block.properties.removeAll { $0.key == BlockColor.propertyKey }
            if !name.isEmpty {
                block.properties.append(BlockProperty(key: BlockColor.propertyKey, value: name))
            }
        }
        commitStructural(doc, label: "Background Color")
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil ? editor.selectedRange() : nil)
    }

    @objc private func copyBlockRef(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        // Persist `id::` so the reference stays durable (SPEC §7.1).
        try? app.store.persistBlockID(id, inPageNamed: pageName)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("((\(id.uuidString.lowercased())))", forType: .string)
        app.dataVersion += 1
    }

    @objc private func copySubtreeMarkdown(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(OutlineOps.copyMarkdown(rows[index].block), forType: .string)
    }

    @objc private func deleteBlockAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteBlock(id)
    }

    private func deleteBlock(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        // Deleting a referenced block prompts (SPEC §7.4).
        let subtreeIDs = [rows[index].block.id] + rows[index].block.children.flattened.map(\.id)
        let count = (try? app.store.cache.incomingRefCount(forBlockIDs: subtreeIDs)) ?? 0
        if count > 0 {
            let alert = NSAlert()
            alert.messageText =
                "This block is referenced in \(count) place\(count == 1 ? "" : "s"). Delete anyway?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        let wasFocused = focusedBlockID == id
        let previousID = index > 0 ? rows[index - 1].block.id : nil
        _ = OutlineOps.delete(path, in: &doc.blocks)
        commitStructural(doc, label: "Delete Block")
        reloadAndFocus(wasFocused ? nil : focusedBlockID, selection: nil)
        if wasFocused, let previousID,
           let prev = app.document(for: pageName).blocks.block(id: previousID) {
            let end = (prev.content as NSString).length
            attachEditor(to: previousID, selection: NSRange(location: end, length: 0),
                         startSession: false)
        }
    }

    // MARK: - Offset conversion (NSTextView UTF-16 <-> OutlineOps Characters)

    static func characterOffset(forUTF16Offset offset: Int, in string: String) -> Int {
        let clamped = max(0, min(offset, string.utf16.count))
        let utf16Index = string.utf16.index(string.utf16.startIndex, offsetBy: clamped)
        let index = String.Index(utf16Index, within: string) ?? string.endIndex
        return string.distance(from: string.startIndex, to: index)
    }

    static func utf16Offset(forCharacterOffset offset: Int, in string: String) -> Int {
        let index = string.index(string.startIndex, offsetBy: max(0, min(offset, string.count)))
        return string.utf16.distance(from: string.utf16.startIndex, to: index)
    }
}

// MARK: - In-page find participant (Cmd+F)

extension OutlineEditorController: FindParticipant {
    /// Window-coordinate top edge; the coordinator orders outlines top→bottom.
    var findSortKey: CGFloat {
        guard tableView.window != nil else { return 0 }
        return tableView.convert(tableView.bounds, to: nil).maxY
    }

    func findUpdate(query: String) -> Int {
        // Editing shows raw source (no highlight); end it so matches show.
        if focusedBlockID != nil { endEditing() }
        findActive = !query.isEmpty
        findQuery = query
        findCurrentLocal = nil
        findMatches = []
        if !query.isEmpty {
            for (i, row) in rows.enumerated() {
                let text = row.rendered.string as NSString
                var start = 0
                while start < text.length {
                    let found = text.range(
                        of: query, options: .caseInsensitive,
                        range: NSRange(location: start, length: text.length - start))
                    guard found.location != NSNotFound else { break }
                    findMatches.append((row: i, range: found))
                    start = NSMaxRange(found)
                }
            }
        }
        tableView.reloadData()
        return findMatches.count
    }

    func findSetCurrent(_ localIndex: Int?) {
        findCurrentLocal = localIndex
        tableView.reloadData()
        if let localIndex, findMatches.indices.contains(localIndex) {
            tableView.scrollRowToVisible(findMatches[localIndex].row)
        }
    }

    func findClear() {
        findActive = false
        findQuery = ""
        findMatches = []
        findCurrentLocal = nil
        tableView.reloadData()
    }
}

// MARK: - Table data source / delegate

extension OutlineEditorController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        max(rows.count, 1) // one placeholder row when empty
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else {
            let cell = tableView.makeView(
                withIdentifier: PlaceholderRowCell.reuseIdentifier, owner: nil
            ) as? PlaceholderRowCell ?? PlaceholderRowCell(frame: .zero)
            cell.identifier = PlaceholderRowCell.reuseIdentifier
            cell.onClick = { [weak self] in self?.createFirstBlock() }
            return cell
        }
        let model = rows[row]
        let cell = tableView.makeView(
            withIdentifier: OutlineRowCell.reuseIdentifier, owner: nil
        ) as? OutlineRowCell ?? OutlineRowCell(frame: .zero)
        cell.identifier = OutlineRowCell.reuseIdentifier
        var isQuote = false
        var isCode = false
        switch BlockKind.classify(model.block.content) {
        case .quote: isQuote = true
        case .fence: isCode = true
        default: break
        }
        // A block containing an embed or a query gets the grey region
        // background (§7.6, §17). A block that is *nothing but* one of those also
        // hides its own bullet, since the generated rows draw theirs; a block
        // mixing text + an embed/query keeps its bullet for the text.
        let nodes = InlineParser.parse(model.block.content)
        let isEmbed = nodes.contains {
            switch $0 { case .embed, .query: return true; default: return false }
        }
        let isPureEmbed = isEmbed && nodes.allSatisfy {
            switch $0 {
            case .embed, .query, .lineBreak: return true
            case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
        // Hide the bullet on empty leaf blocks — but never on the focused one,
        // so a freshly-created block you're about to type in keeps its bullet.
        let isEmptyLeaf = !model.hasChildren && model.block.content.isEmpty
            && model.block.id != focusedBlockID
        // `background-color:: <name>` tints the block as a soft colored box (SPEC §5.6).
        let blockColor = model.block.properties
            .first { $0.key == BlockColor.propertyKey }
            .flatMap { BlockColor(rawValue: $0.value) }?.background
        cell.configure(
            depth: model.depth,
            hasChildren: model.hasChildren,
            collapsed: model.block.collapsed,
            isQuote: isQuote,
            isCode: isCode,
            isEmbed: isEmbed,
            isEmptyLeaf: isEmptyLeaf,
            selected: selectedRows.contains(row),
            lineHeight: BlockRenderer.lineHeight(forSource: model.block.content),
            blockColor: blockColor,
            callbacks: rowCallbacks(for: model.block.id)
        )
        if model.block.id == focusedBlockID {
            cell.embedEditor(editor)
        } else {
            cell.showRendered(findHighlighted(row: row) ?? model.rendered)
            // A pure-embed block hands its bullet to the transcluded subtree.
            if isPureEmbed { cell.setBulletHidden(true) }
        }
        return cell
    }

    /// Returns a copy of the row's rendered text with find matches highlighted
    /// (current match emphasized), or nil when find is inactive/no matches.
    private func findHighlighted(row: Int) -> NSAttributedString? {
        guard findActive, !findQuery.isEmpty, rows.indices.contains(row) else { return nil }
        let ranges = findMatches.filter { $0.row == row }.map(\.range)
        guard !ranges.isEmpty else { return nil }
        let current = findCurrentLocal.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }
        let copy = rows[row].rendered.mutableCopy() as! NSMutableAttributedString
        let length = copy.length
        for range in ranges where NSMaxRange(range) <= length {
            let isCurrent = current?.row == row && current?.range == range
            copy.addAttribute(
                .backgroundColor,
                value: isCurrent
                    ? NSColor.systemYellow
                    : NSColor.systemYellow.withAlphaComponent(0.4),
                range: range
            )
            if isCurrent {
                copy.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
        return copy
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 26 }
        let model = rows[row]
        let contentWidth = OutlineRowCell.contentWidth(
            forDepth: model.depth, rowWidth: max(tableView.bounds.width, 100)
        )
        if model.block.id == focusedBlockID {
            // Focused rows show the full editable source (content + property
            // lines); measure that with the editor's own TextKit 2 layout.
            let textHeight = BlockEditorTextView.measureHeight(
                for: model.block.editableSource, width: contentWidth
            )
            return max(OutlineRowCell.minRowHeight,
                       textHeight + OutlineRowCell.verticalPadding * 2)
        }
        return OutlineRowCell.height(for: model.rendered, contentWidth: contentWidth)
    }
}

// MARK: - Editor actions (SPEC §5.4, §13)

extension OutlineEditorController: BlockEditorActions {

    func editorTextDidChange(_ text: String) {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        // The editor text is the block's full source — re-split into content
        // and user properties (§3.2), preserving id/collapsed.
        doc.blocks.update(at: path) { $0.setEditableSource(text) }
        app.commit(doc) // content keystrokes: debounced save, no undo entry
        rows[index].block = doc.blocks.block(at: path) ?? rows[index].block
        // No bullet toggle here: the focused block always shows its bullet, so
        // emptying it mid-edit must not hide the dot. Unfocused empty leaves
        // hide it at configure time (when focus moves away and the row reloads).
        let current = tableView.rect(ofRow: index).height
        let updated = self.tableView(tableView, heightOfRow: index)
        if abs(current - updated) > 0.5 {
            noteHeightChanged([index])
        }
    }

    func editorSplit(atUTF16Offset offset: Int) {
        guard let id = focusedBlockID else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let block = doc.blocks.block(at: path) else { return }
        // The editor shows the full source (content + property lines). Splitting
        // only ever divides the *content*; clamp the caret into the content
        // region so properties always stay with the original block — Enter in
        // the property area just makes a new empty block below.
        let contentUTF16 = (block.content as NSString).length
        let caret = min(max(offset, 0), contentUTF16)
        let characterOffset = Self.characterOffset(forUTF16Offset: caret, in: block.content)
        guard let newID = OutlineOps.split(path, at: characterOffset, in: &doc.blocks) else {
            return
        }
        commitStructural(doc, label: "New Block")
        reloadAndFocus(newID, selection: NSRange(location: 0, length: 0))
    }

    func editorIndent() {
        structuralOnFocused(label: "Indent") { OutlineOps.indent($0, in: &$1) }
    }

    func editorOutdent() {
        structuralOnFocused(label: "Outdent") { OutlineOps.outdent($0, in: &$1) }
    }

    func editorMoveBlock(by delta: Int) {
        structuralOnFocused(label: "Move Block") { OutlineOps.move($0, by: delta, in: &$1) }
    }

    /// Cmd+Enter: cycle the focused block's task state — plain → TODO → DONE →
    /// TODO. Caret shifts with the text when the keyword is added.
    func editorToggleTodo() {
        guard let id = focusedBlockID else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let block = doc.blocks.block(at: path) else { return }
        let old = block.content
        let new: String
        if let state = block.todoState {
            new = state.toggled.rawValue + String(old.dropFirst(state.rawValue.count))
        } else {
            new = "TODO " + old
        }
        let delta = (new as NSString).length - (old as NSString).length
        let caret = max(0, editor.selectedRange().location + delta)
        doc.blocks.update(at: path) { $0.content = new }
        commitStructural(doc, label: "Toggle Todo")
        reloadAndFocus(id, selection: NSRange(location: caret, length: 0))
    }

    private func structuralOnFocused(label: String, _ op: ([Int], inout [Block]) -> Bool) {
        guard let id = focusedBlockID else { return }
        let selection = editor.selectedRange()
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id), op(path, &doc.blocks) else { return }
        commitStructural(doc, label: label)
        reloadAndFocus(id, selection: selection)
    }

    func editorDeleteEmptyBlock() {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }),
              !rows[index].hasChildren else { return }
        guard rows.count > 1 else { return } // keep the page's last block
        deleteBlock(id)
    }

    func editorMergeWithPrevious() {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }), index > 0 else {
            return
        }
        // Don't merge a block that carries properties — that would silently
        // drop them (merge only moves content). Leave it as a normal block.
        if !(rows[index].block.properties.isEmpty) { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let (receiver, characterOffset) = OutlineOps.mergeWithPrevious(
                  path, in: &doc.blocks
              ) else { return }
        commitStructural(doc, label: "Merge Blocks")
        let content = doc.blocks.block(id: receiver)?.content ?? ""
        let caret = Self.utf16Offset(forCharacterOffset: characterOffset, in: content)
        reloadAndFocus(receiver, selection: NSRange(location: caret, length: 0))
    }

    func editorMergeWithNext() {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }),
              index + 1 < rows.count else { return }
        let next = rows[index + 1]
        // Symmetric with backward merge: can't pull up a block that has children,
        // and won't silently drop a block's properties (merge only moves content).
        guard !next.hasChildren, next.block.properties.isEmpty else { return }
        let caretOffset = (rows[index].block.content as NSString).length
        var doc = app.document(for: pageName)
        // Merging the next block "into its previous" (= this block) is exactly a
        // forward delete: its content appends here and the caret stays at the join.
        guard let nextPath = doc.blocks.path(to: next.block.id),
              OutlineOps.mergeWithPrevious(nextPath, in: &doc.blocks) != nil else { return }
        commitStructural(doc, label: "Merge Blocks")
        reloadAndFocus(id, selection: NSRange(location: caretOffset, length: 0))
    }

    func editorEndEditing() {
        let id = focusedBlockID
        endEditing()
        // Esc moves from text editing into node selection on that block (§13).
        if let id, let index = rows.firstIndex(where: { $0.block.id == id }) {
            setSelection([index], anchor: index)
            tableView.window?.makeFirstResponder(tableView)
        }
    }

    func editorFocusAdjacent(by delta: Int) {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        let target = index + delta
        guard rows.indices.contains(target) else { return }
        let block = rows[target].block
        let caret = delta < 0 ? (block.content as NSString).length : 0
        focusBlock(block.id, selection: NSRange(location: caret, length: 0))
    }

    func editorCopySubtreeMarkdown() -> String? {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }) else { return nil }
        return OutlineOps.copyMarkdown(rows[index].block)
    }

    func editorPasteBlocks(_ text: String) {
        guard let id = focusedBlockID else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let current = doc.blocks.block(at: path) else { return }
        let pasted = OutlineOps.blocksFromPasted(text)
        guard !pasted.isEmpty, let last = pasted.last else { return }
        var insertAt = path
        if current.content.isEmpty && current.children.isEmpty {
            // Pasting into an empty block replaces it.
            _ = doc.blocks.remove(at: path)
        } else {
            insertAt[insertAt.count - 1] += 1
        }
        for (i, block) in pasted.enumerated() {
            var p = insertAt
            p[p.count - 1] += i
            doc.blocks.insert(block, at: p)
        }
        commitStructural(doc, label: "Paste") // one undo step (SPEC §13)
        let caret = (last.content as NSString).length
        reloadAndFocus(last.id, selection: NSRange(location: caret, length: 0))
    }

    func editorFocusLost() {
        // Deferred check: programmatic reloads re-acquire first responder
        // synchronously; end the session only if focus genuinely moved away.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusedBlockID != nil, !self.suppressFocusLoss else { return }
            if self.tableView.window?.firstResponder !== self.editor {
                self.endEditing()
            }
        }
    }
}
