import SwiftUI
import AppKit
import KnopoCore
import UniformTypeIdentifiers




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
    /// Whether this outline is a right-sidebar pane (SPEC §5.4): panes are for
    /// reference, so they never put the caret in a block on their own.
    var inPane = false

    var body: some View {
        OutlineEditorRepresentable(
            app: app, nav: nav, pageName: pageName, zoom: zoom,
            inPane: inPane, dataVersion: app.dataVersion,
            // Reading these here makes the view (and updateNSView) react to find.
            findActive: nav.findActive, findQuery: nav.findQuery,
            findStepToken: nav.findStepToken, findForward: nav.findStepForward,
            // Reacts to a result-click's scroll-to/flash request.
            highlightToken: nav.highlightToken,
            // …and to a `⌘J` writing-focus request.
            focusWritingToken: nav.focusWritingToken
        )
    }
}

private struct OutlineEditorRepresentable: NSViewRepresentable {
    let app: AppState
    let nav: Navigator
    let pageName: String
    let zoom: UUID?
    let inPane: Bool
    /// @Published on AppState; bumps on external/index changes so
    /// `updateNSView` runs and the controller can diff and reload.
    let dataVersion: Int
    let findActive: Bool
    let findQuery: String
    let findStepToken: Int
    let findForward: Bool
    let highlightToken: Int
    /// `Navigator.focusWritingToken`. Held only so that a `⌘J` request makes this
    /// view differ from its last value and SwiftUI runs `updateNSView` — the
    /// request itself is read off `nav` in `present`, which never runs otherwise.
    let focusWritingToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OutlineTableView {
        let controller = OutlineEditorController(app: app, nav: nav)
        controller.inPane = inPane
        controller.applyPaneRole()
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
            // Navigating away (this representable is replaced) must close any
            // open autocomplete: its panel is a child window retained by the
            // main window, so without this it lingers until the window closes.
            // `endEditing` also flushes the in-progress edit session.
            controller.endEditing()
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
final class OutlineTableView: NSTableView, NSMenuItemValidation {

    var onWidthChange: (() -> Void)?
    /// Every layout pass, so a pending reveal can notice that the rows moved under
    /// it — including AppKit's own re-measures, which no delegate call announces.
    var onDidLayout: (() -> Void)?
    var onLiveResizeEnd: (() -> Void)?
    /// Clipboard actions for node selection (SPEC §13), so the Edit menu's Cut,
    /// Copy and Paste act on the selected blocks — and grey out with no selection —
    /// rather than only their shortcuts working.
    var onCut: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var hasBlockSelection: (() -> Bool)?
    /// Select All, which AppKit would otherwise answer with its own row selection —
    /// invisible here, since the outline draws the node selection it keeps itself.
    var onSelectAllBlocks: (() -> Bool)?
    /// Returns true if the controller consumed the key (node-selection mode).
    var onKeyDown: ((NSEvent) -> Bool)?
    /// A drag left the table (or ended without a drop) — cancels spring-loading.
    var onDragExited: (() -> Void)?
    private var lastLayoutWidth: CGFloat = -1

    /// Tracer for AppKit's "reentrant operation in its NSTableView delegate"
    /// warning (slated to become an assert): counts nesting into the table's
    /// own layout/update passes — where AppKit runs the delegate callbacks —
    /// and prints the offending stack when a mutating call arrives from inside
    /// one. Silent unless the bug fires.
    private var updateDepth = 0

    private func tracedMutation(_ name: String, _ body: () -> Void) {
        if updateDepth > 0 {
            print("REENTRANT NSTableView mutation: \(name)")
            Thread.callStackSymbols.prefix(16).forEach { print("   \($0)") }
        }
        updateDepth += 1
        defer { updateDepth -= 1 }
        body()
    }

    override func reloadData() {
        tracedMutation("reloadData") { super.reloadData() }
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        tracedMutation("reloadData(forRowIndexes:)") {
            super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }
    }

    override func insertRows(at indexes: IndexSet,
                             withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        tracedMutation("insertRows") {
            super.insertRows(at: indexes, withAnimation: animationOptions)
        }
    }

    override func removeRows(at indexes: IndexSet,
                             withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        tracedMutation("removeRows") {
            super.removeRows(at: indexes, withAnimation: animationOptions)
        }
    }

    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        tracedMutation("noteHeightOfRows") {
            super.noteHeightOfRows(withIndexesChanged: indexSet)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) { onPaste?() }

    override func selectAll(_ sender: Any?) {
        if onSelectAllBlocks?() == true { return }
        super.selectAll(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)):
            return hasBlockSelection?() ?? false
        default:
            return true
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
    }

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
        updateDepth += 1
        super.layout()
        updateDepth -= 1
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            onWidthChange?()
        }
        onDidLayout?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnd?()
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
        /// Source represented by `rendered`. The focused row's live block is
        /// updated on every keystroke while its hidden preview intentionally is
        /// not, so `block.content` alone cannot validate preview reuse.
        var renderedContent: String
        var renderedProperties: [BlockProperty]
        var renderDependsOnOtherBlocks: Bool
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
    /// A block to scroll to and flash. It outlives its first attempt on purpose.
    ///
    /// Row heights are measured against the table's width, and the table is asked
    /// for every height before SwiftUI puts it in the hierarchy — bounds 100 pt
    /// wide, no clip view, no window, nothing to read a real width from. Measured
    /// that narrow every row wraps many times over, so the rows stand several times
    /// too tall and the first offset can be far from the block: this is what sent a
    /// result click somewhere random. The heights are then re-measured, more than
    /// once, as the layout settles — and AppKit's own passes announce none of it
    /// through the delegate. So the reveal is re-applied from the table's layout
    /// pass until the row stops moving under it, and abandoned after a short window,
    /// past which the layout is the user's again.
    private struct Reveal {
        let blockID: UUID
        /// Where the row sat when it was last scrolled to; nil before the first.
        var rowMinY: CGFloat?
        /// After this the layout is the user's again — an edit or a window resize
        /// must not drag the view back to a block clicked seconds ago.
        let until: TimeInterval
    }

    /// The part of a scrolling outline the reader can actually see: the visible rect
    /// less the band the window toolbar covers. The scroll view runs under the
    /// toolbar (`contentInsets.top` is 52 pt here), and that band counts as visible
    /// to AppKit — which is why `scrollRowToVisible` was content to leave a clicked
    /// row as a sliver tucked beneath it.
    static func shownRect(visibleRect: NSRect, topOverlap: CGFloat) -> NSRect {
        var shown = visibleRect
        shown.origin.y += topOverlap
        shown.size.height -= topOverlap
        return shown
    }

    /// Whether a reveal has nothing left to do: the row it aimed at is in sight and
    /// the re-measures have stopped moving it. Aiming again while either is untrue is
    /// the point of keeping the request — the row being *seen* is the goal, not the
    /// scroll having been issued. A row taller than the viewport counts as shown once
    /// it covers it.
    static func revealHasSettled(
        rowRect: NSRect, visibleRect: NSRect, topOverlap: CGFloat, scrolledTo: CGFloat?
    ) -> Bool {
        guard let scrolledTo, abs(scrolledTo - rowRect.minY) <= 1 else { return false }
        let shown = shownRect(visibleRect: visibleRect, topOverlap: topOverlap)
        if shown.contains(rowRect) { return true }
        return rowRect.height >= shown.height && rowRect.intersects(shown)
    }
    private var revealRequest: Reveal?
    /// Coalesces the deferred reveal: the reload, layout and height passes all ask.
    private var revealScheduled = false
    /// Reloads the table, then lets a pending reveal aim at the new geometry.
    private func reloadAllRows() {
        tableView.reloadData()
        revealIfPossible()
    }
    /// The cell showing the current flash and the block it was lit for, so the
    /// flash can be taken off when that cell is reused for another row, or when a
    /// later reveal lights a different one.
    private weak var flashedCell: OutlineRowCell?
    private var flashedBlockID: UUID?
    /// Whether this outline is a right-sidebar pane. Panes are for reference: they
    /// never take focus on presentation, and a main outline may take focus from one
    /// (§5.4). Applied to the editor by `applyPaneRole`.
    var inPane = false

    /// Lets other outlines recognise this outline's editor as a pane's, when they
    /// decide whether taking focus is allowed.
    func applyPaneRole() {
        editor.isInPane = inPane
    }
    /// The presentation auto-focus has already fired for (see `presentationKey`).
    private var autoFocusedPresentation: String?
    /// Column the caret is carrying across `↑`/`↓` block hops, in editor view
    /// coordinates; nil when the caret last moved for some other reason.
    private var verticalGoalX: CGFloat?
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
    private var renderedWithWeight = BlockRenderer.contentWeight
    private var widthRefreshScheduled = false
    private var needsWidthRefreshAfterLiveResize = false

    /// Bullet drag-and-drop (SPEC §5.4). The pasteboard carries only a marker —
    /// the dragged blocks live here, and drops are accepted from this controller
    /// alone (same page), so ids never round-trip through the pasteboard.
    static let blockDragType = NSPasteboard.PasteboardType("com.knopo.block-drag")
    private var draggingIDs: [UUID] = []
    /// Spring-loading (Finder-style): a drag hovering over a collapsed row for
    /// a moment expands it, so the drop can land *inside*. The pending target
    /// is tracked by block id (row indices shift when rows expand).
    private var springBlockID: UUID?
    private var springWork: DispatchWorkItem?

    // Node selection (SPEC §13): block-level multi-select when not editing.
    private var selectedRows: Set<Int> = []
    /// The fixed end of a keyboard shift-selection; `selectionActive` is the end
    /// that Shift+↑/↓ moves. Together they let Shift+↑ shrink a downward
    /// selection (and vice versa) instead of always growing.
    private var selectionAnchor: Int?
    private var selectionActive: Int?
    /// The one controller that currently holds a node-selection. Several outline
    /// editors can be on screen at once (journal home, right-sidebar panes), but
    /// a selection is global: establishing one here clears any other's.
    @MainActor private static weak var selectionOwner: OutlineEditorController?

    // In-page find (Cmd+F) — this outline's slice, driven by FindCoordinator.
    private var findActive = false
    private var findQuery = ""
    private var findMatches: [(row: Int, range: NSRange)] = []
    /// Index into `findMatches` that is the window-global current match, or nil.
    private var findCurrentLocal: Int?
    /// Rows currently carrying highlight, and the row of the emphasized current
    /// match — tracked so find can reload only the rows whose highlight changed.
    private var findRows: Set<Int> = []
    private var findCurrentRow: Int?

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
        tableView.onDidLayout = { [weak self] in self?.revealIfPossible() }
        tableView.onLiveResizeEnd = { [weak self] in self?.liveResizeDidEnd() }
        tableView.onKeyDown = { [weak self] in self?.handleSelectionKeyDown($0) ?? false }
        tableView.onCut = { [weak self] in self?.cutSelection() }
        tableView.onCopy = { [weak self] in self?.copySelection() }
        tableView.onPaste = { [weak self] in self?.pasteSelection() }
        tableView.hasBlockSelection = { [weak self] in self?.hasSelection ?? false }
        tableView.onSelectAllBlocks = { [weak self] in self?.selectAllBlocks() ?? false }
        tableView.onDragExited = { [weak self] in self?.cancelSpringLoad() }
        tableView.registerForDraggedTypes([Self.blockDragType, .fileURL])
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
            try? self.app.persistBlockID(hit.blockID, inPageNamed: hit.pageDisplayName)
            self.app.dataVersion += 1
        }
        // `/link`: open the two-field panel at the caret (§5.5.2).
        autocomplete.onLinkCommand = { [weak self] in self?.presentLinkPanel() }
        // `/image`: open the image file picker at the caret (§5.5.5).
        autocomplete.onImageCommand = { [weak self] in self?.presentImagePicker() }
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

    /// Opens an image-only file sheet; selected files are copied into assets/
    /// and inserted where the `/image` trigger was removed.
    private func presentImagePicker() {
        guard focusedBlockID != nil, let window = tableView.window else { return }
        let caret = editor.selectedRange().location
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        suppressFocusLoss = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.suppressFocusLoss = false
            self.tableView.window?.makeFirstResponder(self.editor)
            guard response == .OK,
                  let markdown = self.editorImportImageAssets(panel.urls) else { return }
            let loc = min(caret, (self.editor.string as NSString).length)
            self.editor.setSelectedRange(NSRange(location: loc, length: 0))
            self.editor.insertText(markdown,
                                   replacementRange: NSRange(location: loc, length: 0))
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
        let weightChanged = BlockRenderer.contentWeight != renderedWithWeight
        renderedWithBrackets = BlockRenderer.bracketsEnabled
        renderedWithZoom = BlockRenderer.zoom
        renderedWithDensity = BlockRenderer.density
        renderedWithWeight = BlockRenderer.contentWeight
        if pageName != self.pageName || zoom != self.zoom {
            revealRequest = nil
            self.pageName = pageName
            self.zoom = zoom
            focusedBlockID = nil
            editSessionBefore = nil
            renderCache.removeAll() // another page's blocks; free the memory
            autocomplete.dismiss()
            editor.removeFromSuperview()
            rebuildRows()
            reloadAllRows()
            tableView.invalidateIntrinsicContentSize()
        } else if bracketsChanged || fontZoomChanged || densityChanged || weightChanged {
            // A global rendering preference flipped (brackets, content zoom, or
            // text density): re-render the cached rows and re-measure heights.
            reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                ? editor.selectedRange() : nil, reuseStaticRenders: false)
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
        // `⌘J`: the caret goes to today, wherever it happens to be now — taking it
        // from another day in the feed if that's where it was. Panes sit this out,
        // so the request lands in the document area and not in a reference card.
        if !inPane, nav.focusWritingIn == pageName {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pageName == pageName,
                      self.nav.focusWritingIn == pageName else { return }
                self.nav.focusWritingIn = nil
                self.focusForWritingIfNeeded(explicit: true)
            }
        }
        focusForWritingIfNeeded()
        applyPendingHighlightIfNeeded()
    }

    /// An outline whose only block is empty would otherwise render as nothing at
    /// all — no text, and no bullet (an unfocused empty leaf hides it, §5.2). So
    /// put the caret there instead: the bullet returns, and the editor draws its
    /// hint. This is where a new journal day and a not-yet-created page land.
    /// What presenting an outline should do about focus, given its rows.
    enum WritingFocus: Equatable {
        /// Put the caret in this block — it is already an empty tail.
        case focus(UUID)
        /// Today's journal has content: add a trailing block to write in.
        case appendTrailing
        /// Leave focus alone; this outline was opened to read.
        case none
    }

    /// A journal day is somewhere you go to *write*, so today's opens ready to
    /// type — the caret in an empty block at the end, appending one when the day
    /// already has content. Past days stay quiet (they're opened to read, and a
    /// caret appended there would dirty an old file). Other pages open ready only
    /// when there is nothing to read at all: a single empty block, which is what a
    /// page you've merely linked to looks like.
    static func writingFocus(
        forPage pageName: String,
        isEmptyTail: Bool,
        tailBlockID: UUID?,
        rowCount: Int,
        today: JournalDate = JournalDate.today()
    ) -> WritingFocus {
        let isToday = JournalDate(pageName: pageName)?.pageName == today.pageName
        if isEmptyTail, let tailBlockID {
            // Blank page, or a trailing block left by an earlier visit — reuse it
            // rather than stacking another empty block on every visit.
            return isToday || rowCount == 1 ? .focus(tailBlockID) : .none
        }
        return isToday ? .appendTrailing : .none
    }

    /// - Parameter explicit: the user asked for this (`⌘J`), rather than it being
    ///   the automatic "this page opens ready to write". An explicit request fires
    ///   however many times it is asked for, and may take the caret from another
    ///   day in the feed — which the automatic path must never do.
    private func focusForWritingIfNeeded(explicit: Bool = false) {
        // Already writing here: nothing to ask for.
        guard focusedBlockID == nil else { return }
        // Otherwise once per presentation: `present` runs on every data change,
        // and re-focusing would yank the caret back after a click elsewhere.
        guard explicit || autoFocusedPresentation != presentationKey else { return }
        // Nothing at all to show — an emptied file, a preamble-only file, or a
        // zoom into a childless block. Give the page the block it needs, so every
        // empty outline looks the same: one blank block with the hint in it.
        if rows.isEmpty {
            autoFocusedPresentation = presentationKey
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rows.isEmpty else { return }
                let id = self.materialiseFirstBlock()
                guard explicit || self.mayTakeFocus else {
                    self.reloadAndFocus(nil, selection: nil)
                    return
                }
                self.reloadAndFocus(id, selection: NSRange(location: 0, length: 0))
                self.revealFocusedRow(id)
            }
            return
        }
        guard !inPane, zoom == nil else { return }
        let tail = rows[rows.count - 1]
        let intent = Self.writingFocus(
            forPage: pageName,
            isEmptyTail: tail.block.content.isEmpty && !tail.hasChildren,
            tailBlockID: tail.block.id,
            rowCount: rows.count)
        guard intent != .none else { return }
        autoFocusedPresentation = presentationKey
        // Deferred for the same reason as the hook above — the table has to be
        // laid out and in a window before the editor can take first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusedBlockID == nil,
                  explicit || self.mayTakeFocus else { return }
            switch intent {
            case .focus(let id):
                guard self.rows.contains(where: { $0.block.id == id }) else { return }
                self.focusBlock(id, selection: NSRange(location: 0, length: 0))
                self.revealFocusedRow(id)
            case .appendTrailing:
                self.appendBlockToWriteIn()
            case .none:
                break
            }
        }
    }

    /// Whether this outline may put the caret in a block right now. Panes never
    /// do — they are reference cards. Nor may an outline take focus from another
    /// *main* one: the journal feed stacks one per day, and the midnight rollover
    /// adds an empty one while you may be typing in yesterday's. Taking focus from
    /// a pane *is* allowed; the pane ends its own editing when its editor resigns
    /// (`editorFocusLost`).
    private var mayTakeFocus: Bool {
        guard !inPane else { return false }
        if let focused = tableView.window?.firstResponder as? BlockEditorTextView,
           !focused.isInPane {
            return false
        }
        return true
    }

    /// Whether a row hides its bullet (SPEC §5.2). An empty leaf does — an outline
    /// shouldn't be littered with dots for blocks holding nothing — with two
    /// exceptions. The focused one keeps it, so a block you are about to type in
    /// doesn't lose its dot. And a page's *only* block keeps it, because that is
    /// the whole page: hidden, an empty page renders as nothing at all, and the
    /// bullet is the affordance every outliner uses to say "a block lives here".
    static func hidesBullet(
        content: String, hasChildren: Bool, isFocused: Bool, isOnlyRow: Bool
    ) -> Bool {
        content.isEmpty && !hasChildren && !isFocused && !isOnlyRow
    }

    /// Creates the block an empty outline needs — a child of the zoom root when
    /// zoomed. In memory only (no `commit`), so opening a page never writes to it;
    /// the block reaches disk once you type in it.
    private func materialiseFirstBlock() -> UUID {
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
        app.store.updatePage(doc)
        return block.id
    }

    /// Scrolls a programmatically focused block into view. Focusing doesn't scroll
    /// on its own, and today's journal is easily taller than the window — so the
    /// caret would land below the fold and `⌘J` would look like it did nothing.
    /// A row of margin below it keeps the caret off the very edge.
    private func revealFocusedRow(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let row = self.rows.firstIndex(where: { $0.block.id == id }) else { return }
            // The focused row is taller than its rendered form (it holds the
            // editor), so let the table finish laying out before measuring it.
            self.tableView.layoutSubtreeIfNeeded()
            self.tableView.scrollRowToVisible(row)
            var withMargin = self.tableView.rect(ofRow: row)
            withMargin.size.height += OutlineRowCell.minRowHeight
            self.tableView.scrollToVisible(withMargin)
        }
    }

    /// Adds the trailing block today's journal opens into. Deliberately *not* a
    /// `commit`: no save is scheduled, so merely visiting the journal can never
    /// dirty the file — the block reaches disk only once you type in it (or the
    /// page is saved for some other reason).
    private func appendBlockToWriteIn() {
        var doc = app.document(for: pageName)
        let block = Block(content: "")
        doc.blocks.append(block)
        app.store.updatePage(doc)
        reloadAndFocus(block.id, selection: NSRange(location: 0, length: 0))
        revealFocusedRow(block.id)
    }

    /// Identifies one page/zoom presentation, so auto-focus fires once for it.
    private var presentationKey: String {
        "\(pageName)#\(zoom?.uuidString ?? "")"
    }

    /// One row as the highlight matcher sees it — enough to recognise the clicked
    /// block without a table.
    struct HighlightCandidate: Equatable {
        let id: UUID
        let path: [Int]
        let content: String
    }

    /// Which row a result click should scroll to and flash, or nil for none.
    ///
    /// The clicked id comes from the *index*, which parsed the page separately from
    /// the copy on screen, and only `id::`-pinned blocks keep an id across parses —
    /// so most clicks fall through to the preorder position recorded with the
    /// request. That position is trusted only while the block sitting there still
    /// carries the clicked content: read against an index that has moved on since,
    /// it names an unrelated block, which is how a click landed somewhere random.
    /// A content search is the last resort, nearest the recorded position because a
    /// page can repeat itself. Nothing matching flashes nothing — the page stays
    /// where it opened rather than jumping somewhere that wasn't clicked.
    static func highlightRow(
        _ target: BlockHighlight, in candidates: [HighlightCandidate],
        pathAtPosition: (Int) -> [Int]?
    ) -> Int? {
        if let byID = candidates.firstIndex(where: { $0.id == target.blockID }) { return byID }
        let byPosition = target.position.flatMap(pathAtPosition)
            .flatMap { path in candidates.firstIndex { $0.path == path } }
        if let byPosition, candidates[byPosition].content == target.content { return byPosition }
        // An empty clicked block can only be found by id or position: searching for
        // no content would match the first blank row on the page.
        guard !target.content.isEmpty else { return nil }
        let matches = candidates.indices.filter { candidates[$0].content == target.content }
        guard let first = matches.first else { return nil }
        guard let byPosition else { return first }
        return matches.min { abs($0 - byPosition) < abs($1 - byPosition) } ?? first
    }

    /// Scrolls to and flashes a block when a result click requested it — for the
    /// page this outline shows, on the surface the click asked for.
    private func applyPendingHighlightIfNeeded() {
        guard nav.highlightToken != lastHighlightToken else { return }
        guard let hl = nav.highlightTarget, hl.pageKey == PageName.key(pageName),
              hl.inSidebar == inPane else { return }
        lastHighlightToken = nav.highlightToken
        // Spent here: the click that made the request is the only navigation it
        // applies to. Left standing it would fire again in the next outline created
        // for this page — which has handled no token at all — so a later page-title
        // click, sidebar pick, or ⌘K would jump to this block all over again.
        nav.consumeHighlight()
        guard let index = Self.highlightRow(
            hl,
            in: rows.map {
                HighlightCandidate(id: $0.block.id, path: $0.path, content: $0.block.content)
            },
            pathAtPosition: { app.document(for: pageName).blocks.path(atPreorderPosition: $0) }
        ) else { return }
        requestReveal(of: rows[index].block.id)
    }

    /// Asks for a block to be scrolled to and flashed: as soon as the geometry means
    /// something, and again after each re-measure that moves the row, until the
    /// layout settles.
    private func requestReveal(of blockID: UUID) {
        revealRequest = Reveal(blockID: blockID, rowMinY: nil,
                               until: CACurrentMediaTime() + 2)
        revealIfPossible()
    }

    /// Deferred: the callers are the table's own reload/layout/height passes, and
    /// scrolling or fetching a cell from inside one of those is the reentrancy this
    /// controller avoids everywhere else — the cell handed back mid-pass is
    /// reconfigured immediately afterwards, taking the flash with it.
    private func revealIfPossible() {
        guard revealRequest != nil, !revealScheduled else { return }
        revealScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.revealScheduled = false
            self?.revealNow()
        }
    }

    private func revealNow() {
        guard let request = revealRequest else { return }
        guard CACurrentMediaTime() < request.until else {
            revealRequest = nil
            return
        }
        guard let row = rows.firstIndex(where: { $0.block.id == request.blockID }) else { return }
        // Settled for now — but the request is kept until its window runs out: more
        // re-measures follow, and each can move the row out of view again.
        let topOverlap = tableView.enclosingScrollView?.contentInsets.top ?? 0
        if Self.revealHasSettled(rowRect: tableView.rect(ofRow: row),
                                 visibleRect: tableView.visibleRect,
                                 topOverlap: topOverlap,
                                 scrolledTo: request.rowMinY) {
            return
        }
        // Scroll so the row clears the toolbar band and has a row's worth of margin
        // around it. `scrollRowToVisible` stops as soon as a row is *minimally* inside
        // the clip, and the clip's top is under the toolbar, so it was content to
        // leave the clicked row as a sliver beneath it.
        let margin = OutlineRowCell.minRowHeight
        var target = tableView.rect(ofRow: row)
        target.origin.y -= topOverlap + margin
        target.size.height += topOverlap + margin * 2
        tableView.scrollToVisible(target)
        tableView.layoutSubtreeIfNeeded()
        revealRequest?.rowMinY = tableView.rect(ofRow: row).minY
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? OutlineRowCell else { return }
        // Cells are reused, so a flash still running on another row goes out first —
        // including one this reveal itself left on a cell that has since moved on.
        if flashedCell !== cell { flashedCell?.cancelFlash() }
        cell.flash()
        flashedCell = cell
        flashedBlockID = request.blockID
    }

    /// Diffs the store's current state against the displayed rows; reloads
    /// (preserving focus) only when something actually changed — the common
    /// no-op being our own debounced save bumping `dataVersion`.
    private func refreshIfChanged() {
        let doc = app.document(for: pageName)
        let fresh = OutlineOps.visibleRows(in: doc.blocks, zoomRoot: zoom)
        if !matchesCurrent(fresh) {
            reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                ? editor.selectedRange() : nil)
            return
        }
        // This page's own blocks are unchanged — but a `{{query}}` / `{{embed}}`
        // renders from the *index* (other pages), so its results can change with
        // no change here: e.g. a TODO toggled in another pane or window. Re-run
        // those blocks on any data change, unless an edit is in progress here (a
        // reload would re-attach the editor and drop the caret).
        guard focusedBlockID == nil else { return }
        let hasGenerated = fresh.contains {
            $0.block.content.contains("{{query") || $0.block.content.contains("{{embed")
        }
        if hasGenerated { reloadAndFocus(nil, selection: nil) }
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

    private func rebuildRows(reusingStaticRendersFrom oldRows: [Row]? = nil) {
        let doc = app.document(for: pageName)
        let visible = OutlineOps.visibleRows(in: doc.blocks, zoomRoot: zoom)
        let oldByID = oldRows.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.block.id, $0) }) }
        rows = visible.map { visibleRow in
            let old = oldByID?[visibleRow.block.id]
            let sameRenderedContent = old.map { oldRow in
                oldRow.renderedContent == visibleRow.block.content
            } ?? false
            let dependsOnOtherBlocks = sameRenderedContent
                ? old!.renderDependsOnOtherBlocks
                : Self.renderDependsOnOtherBlocks(visibleRow.block.content)
            let canReuse = sameRenderedContent
                && old?.renderedProperties == visibleRow.block.properties
                && old?.depth == visibleRow.depth
                && !dependsOnOtherBlocks
            let rendered = canReuse ? old!.rendered
                : cachedRender(visibleRow.block, depth: visibleRow.depth)
            return Row(block: visibleRow.block, depth: visibleRow.depth, path: visibleRow.path,
                       hasChildren: visibleRow.hasChildren, rendered: rendered,
                       renderedContent: visibleRow.block.content,
                       renderedProperties: visibleRow.block.properties,
                       renderDependsOnOtherBlocks: dependsOnOtherBlocks)
        }
        pruneRenderCacheIfNeeded()
    }

    private static func renderDependsOnOtherBlocks(_ content: String) -> Bool {
        content.contains("{{query") || content.contains("{{embed") || content.contains("((")
    }

    // MARK: - Render/height cache

    /// Structural edits rebuild every row (`rebuildRows`) and `reloadData`
    /// re-asks every row's height, though a split/move touches only a couple of
    /// blocks. Caching the rendered string and its measured height per block —
    /// validated by a signature of everything the render reads — collapses both
    /// O(all blocks) passes to O(changed blocks).
    private struct RenderCacheEntry {
        var signature: Int
        var rendered: NSAttributedString
        /// Measured height at `measuredWidth` (a function of depth and table
        /// width); a differing width re-measures.
        var height: CGFloat?
        var measuredWidth: CGFloat = 0
    }

    private var renderCache: [UUID: RenderCacheEntry] = [:]

    /// Hash of every input `renderBlock` depends on. Returns nil for blocks
    /// whose output also depends on *other* blocks/pages and so can't be
    /// validated from their own inputs: `{{query}}` / `{{embed}}` blocks render
    /// from the index and must re-run each rebuild (live cross-page refresh
    /// counts on it). `((block ref))` blocks show the target's text, so any
    /// commit anywhere (`dataVersion`) re-renders them. When in doubt a
    /// signature must over-invalidate — a wasted render is invisible, a stale
    /// one is on screen.
    private func renderSignature(for block: Block, contentWidth: CGFloat) -> Int? {
        if block.content.contains("{{query") || block.content.contains("{{embed") {
            return nil
        }
        var hasher = Hasher()
        hasher.combine(block.content)
        hasher.combine(block.properties)
        hasher.combine(BlockRenderer.bracketsEnabled)
        hasher.combine(BlockRenderer.zoom)
        hasher.combine(BlockRenderer.density)
        hasher.combine(BlockRenderer.contentWeight)
        // A table lays its columns out against the row width (§5.2), so its
        // render — alone among blocks — goes stale when the width changes.
        if BlockKind.classify(block.content).isTable { hasher.combine(contentWidth) }
        if block.content.contains("((") { hasher.combine(app.dataVersion) }
        return hasher.finalize()
    }

    private func cachedRender(_ block: Block, depth: Int) -> NSAttributedString {
        let width = contentWidth(forDepth: depth)
        guard let signature = renderSignature(for: block, contentWidth: width) else {
            renderCache[block.id] = nil
            return renderBlock(block, contentWidth: width)
        }
        if let entry = renderCache[block.id], entry.signature == signature {
            return entry.rendered
        }
        let rendered = renderBlock(block, contentWidth: width)
        renderCache[block.id] = RenderCacheEntry(signature: signature, rendered: rendered)
        return rendered
    }

    /// Width available to a row's content at this depth — the same number
    /// `layout()` gives the row, so renders and measurements agree.
    private func contentWidth(forDepth depth: Int) -> CGFloat {
        OutlineRowCell.contentWidth(
            forDepth: depth, rowWidth: max(tableView.bounds.width, 100))
    }

    /// Block ids drift across re-parses (only `id::`-persisted blocks keep
    /// theirs), so orphaned entries accumulate; drop them once they clearly
    /// outnumber the live rows.
    private func pruneRenderCacheIfNeeded() {
        guard renderCache.count > max(128, rows.count * 2) else { return }
        let live = Set(rows.map(\.block.id))
        renderCache = renderCache.filter { live.contains($0.key) }
    }

    private func render(
        _ content: String, todoBlockID: UUID? = nil,
        contentWidth: CGFloat? = nil,
        tableWidth: BlockRenderer.TableWidth = .max
    ) -> NSAttributedString {
        BlockRenderer.render(content: content, context: BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: false, // the row cell draws one continuous bar
            resolveEmbed: { [weak self] target in self?.renderEmbed(target) },
            resolveQuery: { [weak self] expr in self?.renderQuery(expr) },
            contentWidth: contentWidth,
            tableWidth: tableWidth,
            todoBlockID: todoBlockID
        ))
    }

    private func renderEmbed(_ target: EmbedTarget) -> NSAttributedString? {
        renderEmbed(target, embedDepth: 0, visited: [])
    }

    /// A filled circle inline bullet, as a text attachment so it sits vertically
    /// centered on the line. Same diameter and color as `BulletView`'s dot, so
    /// embedded/query rows read as structure like the outline's own bullets.
    /// The drawing handler runs at draw time, so the dynamic color follows the
    /// appearance; the cache is keyed by diameter, which changes with zoom.
    private static var embedBulletCache: (diameter: CGFloat, image: NSImage)?

    private static func embedBulletImage(diameter: CGFloat) -> NSImage {
        if let cached = embedBulletCache, cached.diameter == diameter { return cached.image }
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.cacheMode = .never
        embedBulletCache = (diameter, image)
        return image
    }

    private static func embedBullet() -> NSAttributedString {
        let d = BulletView.dotDiameter()
        let attachment = NSTextAttachment()
        attachment.image = embedBulletImage(diameter: d)
        // Center the dot against the x-height of the body line.
        let y = ((BlockRenderer.baseFont().xHeight - d) / 2).rounded()
        attachment.bounds = CGRect(x: 0, y: y, width: d, height: d)
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
            link = KnopoURL.block(id)
        case .page(let name):
            let blocks = app.document(for: name).blocks
            guard !blocks.isEmpty else { return nil }
            rootBlocks = blocks
            link = KnopoURL.page(name)
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
            },
            tables: false // a transcluded table shows as its raw source (§5.2)
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
                let indent = String(repeating: "    ", count: depth)
                let start = body.length
                body.append(NSAttributedString(string: indent,
                                               attributes: [.font: BlockRenderer.baseFont()]))
                body.append(Self.embedBullet())
                var blockContext = inner
                blockContext.todoBlockID = block.id  // toggle the embedded block, not the source
                body.append(BlockRenderer.render(content: block.content, context: blockContext))
                applyHangingIndent(body, range: NSRange(location: start, length: body.length - start),
                                   hang: bulletHangWidth(indent: indent))
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
        if let linkAll { addNavigationLink(body, linkAll, over: full) }
        body.addAttribute(.embedRegion, value: true, range: full)
        // Pin per line by its tallest font, so an embedded `## heading` keeps its
        // full height instead of being clipped to the base line height.
        BlockRenderer.pinLineHeightPerParagraph(body)
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

    /// Paints `url` as the click target across `range`, but leaves any TODO
    /// checkbox's `knopo://toggle-todo` link intact — so a checkbox inside a
    /// query result or embed still toggles instead of navigating to the source.
    private func addNavigationLink(_ body: NSMutableAttributedString, _ url: URL, over range: NSRange) {
        body.enumerateAttribute(.link, in: range) { value, sub, _ in
            if let existing = value as? URL, existing.host == "toggle-todo" { return }
            body.addAttribute(.link, value: url, range: sub)
        }
    }

    /// Width of a query/embed row's leading indent + bullet, so wrapped lines can
    /// hang-indent under the content rather than dropping to the region's edge.
    private func bulletHangWidth(indent: String) -> CGFloat {
        let s = NSMutableAttributedString(string: indent, attributes: [.font: BlockRenderer.baseFont()])
        s.append(Self.embedBullet())
        return ceil(s.size().width)
    }

    /// Hangs wrapped lines under the content (after the bullet) by setting
    /// `headIndent` to the bullet-prefix width. `finishRegion` later adds the
    /// region's left padding to both indents, keeping the offset.
    private func applyHangingIndent(_ text: NSMutableAttributedString, range: NSRange, hang: CGFloat) {
        guard range.length > 0 else { return }
        let base = text.attribute(.paragraphStyle, at: range.location + range.length - 1,
                                  effectiveRange: nil) as? NSParagraphStyle
        let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = hang
        text.addAttribute(.paragraphStyle, value: style, range: range)
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
            inlineQuoteBar: true,
            tables: false) // a table in a result row shows as its raw source (§5.2)
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
                    .link: KnopoURL.page(hit.pageDisplayName)]))
            }
            // An empty block (e.g. a page-properties block surfaced by a
            // page-property query) has nothing to show; the clickable page header
            // above already lists the page, so skip the blank bullet row.
            if hit.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let row = NSMutableAttributedString(
                string: "    ", attributes: [.font: BlockRenderer.baseFont()])
            row.append(Self.embedBullet())
            var hitContext = inner
            hitContext.todoBlockID = hit.blockID  // toggle this hit's block, not the host
            row.append(BlockRenderer.render(content: hit.content, context: hitContext))
            // The whole result row navigates to that block — except its TODO
            // checkbox, which keeps its toggle link. Carry the page name (not a
            // bare block id) — the index id may not survive a re-parse, so a
            // name-less block link can fail to resolve its page.
            addNavigationLink(row, KnopoURL.block(hit.blockID, onPage: hit.pageDisplayName),
                              over: NSRange(location: 0, length: row.length))
            applyHangingIndent(row, range: NSRange(location: 0, length: row.length),
                               hang: bulletHangWidth(indent: "    "))
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
    private func renderBlock(_ block: Block, contentWidth: CGFloat) -> NSAttributedString {
        // Tracked so a `{{query}}` can exclude its own host block from results.
        renderingBlockID = block.id
        defer { renderingBlockID = nil }
        let tableWidth = block.properties
            .first { $0.key == BlockRenderer.TableWidth.propertyKey }
            .map { BlockRenderer.TableWidth(propertyValue: $0.value) } ?? .max
        let out = render(block.content, todoBlockID: block.id,
                         contentWidth: contentWidth, tableWidth: tableWidth)
            .mutableCopy() as! NSMutableAttributedString
        let shown = block.properties.filter {
            !Block.hiddenPropertyKeys.contains($0.key)
                && !Block.editOnlyPropertyKeys.contains($0.key)
        }
        guard !shown.isEmpty else { return out }
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyLength = out.length
        for prop in shown {
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: valueAttrs))
            }
            out.append(NSAttributedString(string: "\(prop.key): ", attributes: keyAttrs))
            out.append(NSAttributedString(string: prop.value, attributes: valueAttrs))
        }
        // Pin the appended property lines to the block's line height (so
        // focused/unfocused heights stay equal — same lines, same metrics). Only
        // those lines: the body was pinned by the renderer, which gives a table's
        // rows their own taller metrics.
        BlockRenderer.pinLineHeight(
            out, BlockRenderer.lineHeight(forSource: block.content),
            range: NSRange(location: bodyLength, length: out.length - bodyLength))
        return out
    }

    /// Full reload from the store, then re-attaches the shared editor to the
    /// given block (if still visible).
    private func reloadAndFocus(
        _ id: UUID?, selection: NSRange?, reuseStaticRenders: Bool = true
    ) {
        let old = rows
        let previousFocus = focusedBlockID
        rebuildRows(reusingStaticRendersFrom: reuseStaticRenders ? old : nil)
        // Move the focus marker BEFORE applying row updates: unlike the old
        // full `reloadData()` (lazy — cells materialized after `attachEditor`
        // updated the marker), row-level reloads reconfigure synchronously, and
        // `viewFor` embeds the editor into whichever row matches
        // `focusedBlockID`. With the stale marker, the previously-focused row
        // would reconfigure into editing state (rendered text hidden) and then
        // lose the editor to the new row — leaving it blank.
        let newFocus = id.flatMap { target in
            rows.contains { $0.block.id == target } ? target : nil
        }
        focusedBlockID = newFocus
        let reloadedIDs = applyRowChanges(from: old)
        // The row that hosted the editor isn't necessarily in the changed set —
        // Enter at the end of a block leaves its content (and so its cached
        // render) untouched — but its cell is in editing state. Reload it so it
        // shows its rendered content again once the editor moves elsewhere.
        if let previousFocus, previousFocus != newFocus,
           !reloadedIDs.contains(previousFocus),
           let prevIndex = rows.firstIndex(where: { $0.block.id == previousFocus }) {
            reloadRow(prevIndex)
        }
        tableView.invalidateIntrinsicContentSize()
        if let newFocus {
            attachEditor(to: newFocus, selection: selection, startSession: false)
        } else {
            editor.removeFromSuperview()
        }
    }

    /// Applies the old→new `rows` difference with row-level table updates. A
    /// full `reloadData()` drops every materialized cell and re-creates (and
    /// re-lays-out) each visible one — the dominant cost of a structural edit
    /// on a large page, where a split/indent/move touches only a couple of
    /// rows. Unchanged rows keep their live cells untouched.
    private func applyRowChanges(from old: [Row]) -> Set<UUID> {
        guard tableView.numberOfRows == old.count else {
            reloadAllRows()
            return Set(rows.map(\.block.id))
        }
        let diff = rows.map(\.block.id).difference(from: old.map(\.block.id))
        // A wholesale change (an external reload re-mints every volatile id)
        // diffs into ~2n edits; a plain reload is cheaper.
        guard diff.count <= max(8, rows.count / 2) else {
            reloadAllRows()
            return Set(rows.map(\.block.id))
        }
        if !diff.isEmpty {
            tableView.beginUpdates()
            for change in diff {
                switch change {
                case .remove(let offset, _, _):
                    tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                case .insert(let offset, _, _):
                    tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                }
            }
            tableView.endUpdates()
        }
        // Surviving rows whose visuals changed re-configure. The rendered
        // comparison is by identity: the render cache returns the same instance
        // for an unchanged block, and deliberately fresh instances for
        // re-rendered ones — including `{{query}}`/`{{embed}}` blocks, which are
        // never cached so their results stay live.
        var oldByID: [UUID: Row] = [:]
        for row in old { oldByID[row.block.id] = row }
        var changed: [Int] = []
        for (index, row) in rows.enumerated() {
            guard let prev = oldByID[row.block.id] else { continue } // freshly inserted
            if prev.rendered !== row.rendered
                || prev.depth != row.depth
                || prev.hasChildren != row.hasChildren
                || prev.block.collapsed != row.block.collapsed {
                changed.append(index)
            }
        }
        if !changed.isEmpty {
            let previousHeights = changed.map { tableView.rect(ofRow: $0).height }
            tableView.reloadData(
                forRowIndexes: IndexSet(changed), columnIndexes: IndexSet(integer: 0))
            let heightChanges = zip(changed, previousHeights).compactMap { index, previous in
                abs(previous - self.tableView(tableView, heightOfRow: index)) > 0.5
                    ? index : nil
            }
            noteHeightChanged(heightChanges)
        }
        return Set(changed.map { rows[$0].block.id })
    }

    private func reloadRow(_ index: Int) {
        guard index >= 0, index < tableView.numberOfRows else { return }
        let previousHeight = tableView.rect(ofRow: index).height
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)
        )
        if abs(previousHeight - self.tableView(tableView, heightOfRow: index)) > 0.5 {
            noteHeightChanged([index])
        }
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

    /// Re-renders the rows whose rendered form depends on the row width — tables,
    /// whose columns are laid out to fit it (§5.2). Their cache entries went stale
    /// with the width, so `cachedRender` re-runs them and leaves everything else
    /// untouched.
    private func rerenderWidthDependentRows() {
        for index in rows.indices where BlockKind.classify(rows[index].block.content).isTable {
            let rendered = cachedRender(rows[index].block, depth: rows[index].depth)
            guard rendered !== rows[index].rendered else { continue }
            rows[index].rendered = rendered
            reloadRow(index)
        }
    }

    private func widthDidChange() {
        guard !isLiveResizing else {
            needsWidthRefreshAfterLiveResize = true
            return
        }
        scheduleWidthRefresh()
    }

    private var isLiveResizing: Bool {
        tableView.inLiveResize || tableView.window?.inLiveResize == true
    }

    private func liveResizeDidEnd() {
        guard needsWidthRefreshAfterLiveResize else { return }
        needsWidthRefreshAfterLiveResize = false
        scheduleWidthRefresh()
    }

    private func scheduleWidthRefresh() {
        guard !widthRefreshScheduled else { return }
        widthRefreshScheduled = true
        // Deferred: noteHeightOfRows inside layout would recurse.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widthRefreshScheduled = false
            guard !self.isLiveResizing else {
                self.needsWidthRefreshAfterLiveResize = true
                return
            }
            self.refreshRowsForWidth()
        }
    }

    private func refreshRowsForWidth() {
        rerenderWidthDependentRows()
        let count = min(rows.count, tableView.numberOfRows)
        if count > 0 {
            noteHeightChanged(Array(0..<count))
        } else {
            tableView.invalidateIntrinsicContentSize()
        }
        revealIfPossible()   // the rows just changed height under any pending reveal
    }

    // MARK: - Focus and the shared editor

    func focusBlock(_ id: UUID, selection: NSRange?) {
        // Editing exits node selection everywhere. Clear another editor's
        // selection (journal home / panes) if it owns one…
        if let owner = Self.selectionOwner, owner !== self { owner.clearSelection() }
        Self.selectionOwner = nil
        // …and clear our own, redrawing the stale rows so their dark-blue
        // highlight doesn't linger next to the focused block.
        if hasSelection {
            let stale = selectedRows
            selectedRows = []
            selectionAnchor = nil
            stale.forEach(reloadRow)
        }
        flushEditSessionUndo() // close the previous block's typing into one undo step
        let previous = focusedBlockID
        attachEditor(to: id, selection: selection, startSession: true)
        if let previous, previous != id,
           let prevIndex = rows.firstIndex(where: { $0.block.id == previous }) {
            rows[prevIndex].rendered = cachedRender(rows[prevIndex].block,
                                                    depth: rows[prevIndex].depth)
            reloadRow(prevIndex)
        }
    }

    private func attachEditor(to id: UUID, selection: NSRange?, startSession: Bool) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        if startSession && focusedBlockID != id {
            editSessionBefore = app.document(for: pageName)
        }
        focusedBlockID = id
        endOtherEditing()
        // Undo/redo has to be able to close this typing run first (§13).
        app.closePendingEdit = { [weak self] in self?.closeEditSessionForUndo() }
        // A hint only on the sole block of an otherwise-empty page (SPEC §5.4);
        // set on every attach, so a reused editor never carries a stale one.
        editor.emptyHint = rows.count == 1 ? BlockRenderer.emptyBlockHint : nil
        // Edit the full source — content plus user `key:: value` lines (§3.2).
        editor.setContent(rows[index].block.editableSource)
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
        let currentHeight = tableView.rect(ofRow: index).height
        if abs(currentHeight - self.tableView(tableView, heightOfRow: index)) > 0.5 {
            noteHeightChanged([index])
        }
        // Deferred, like `revealFocusedRow`: the row's height changes as it takes
        // the editor, so the caret's place isn't final until the table re-lays out.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusedBlockID == id else { return }
            self.editor.revealCaret()
        }
    }

    /// One row per window is being edited at a time. Each outline normally ends
    /// its own session when its editor resigns, but that runs through the editor's
    /// *weak* `actions`, so an outline that has gone away can leave its editor
    /// embedded and lit up with no one to clean it up. The incoming editor is the
    /// one party guaranteed to still be here, so it does the clearing.
    private func endOtherEditing() {
        guard let root = tableView.window?.contentView else { return }
        for stray in Self.embeddedEditors(in: root) where stray !== editor {
            if let owner = stray.actions as? OutlineEditorController {
                owner.endEditing()   // still live: let it close its own session
            } else {
                OutlineRowCell.enclosing(stray)?.discardEmbeddedEditor()
                stray.removeFromSuperview()
            }
        }
    }

    private static func embeddedEditors(in view: NSView) -> [BlockEditorTextView] {
        var found: [BlockEditorTextView] = []
        if let editor = view as? BlockEditorTextView { found.append(editor) }
        for subview in view.subviews { found.append(contentsOf: embeddedEditors(in: subview)) }
        return found
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
            rows[index].rendered = cachedRender(rows[index].block, depth: rows[index].depth)
            reloadRow(index)
        }
    }

    // MARK: - Node selection (SPEC §13)

    private var hasSelection: Bool { !selectedRows.isEmpty }

    private func setSelection(_ rows: Set<Int>, anchor: Int?, active: Int? = nil) {
        if rows.isEmpty {
            if Self.selectionOwner === self { Self.selectionOwner = nil }
        } else {
            // Establishing a selection here clears any other editor's.
            if let owner = Self.selectionOwner, owner !== self { owner.clearSelection() }
            Self.selectionOwner = self
        }
        selectedRows = rows
        selectionAnchor = anchor
        selectionActive = active ?? anchor   // the moving end for Shift+↑/↓
        reloadAllRows()
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
        case 48: // Tab / Shift+Tab
            guard hasSelection else { return false }
            indentOutdentSelection(outdent: flags.contains(.shift))
            return true
        case 53: // Esc clears selection
            guard hasSelection else { return false }
            clearSelection()
            return true
        case 7 where flags.contains(.command): // Cmd+X
            guard hasSelection else { return false }
            cutSelection()
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
            return selectAllBlocks()
        default:
            return false
        }
    }

    /// Selects every visible block. Returns false when there is nothing to select,
    /// leaving `selectAll:` to AppKit.
    @discardableResult
    private func selectAllBlocks() -> Bool {
        guard focusedBlockID == nil, !rows.isEmpty else { return false }
        setSelection(Set(rows.indices), anchor: 0, active: rows.count - 1)
        return true
    }

    private func stepSelection(up: Bool, extend: Bool) {
        let anchor = selectionAnchor ?? selectedRows.min() ?? 0
        if extend {
            // Move the active end one row; Shift toward the anchor shrinks the
            // selection, away from it grows — the range is anchor…active.
            let active = selectionActive ?? farSelectedEnd(from: anchor)
            let next = active + (up ? -1 : 1)
            guard rows.indices.contains(next) else { return }
            selectionAnchor = anchor
            selectionActive = next
            setSelection(Set(min(anchor, next)...max(anchor, next)), anchor: anchor, active: next)
            tableView.scrollRowToVisible(next)
        } else {
            // Plain ↑/↓ collapses to a single block just past the current edge.
            let bound = up ? (selectedRows.min() ?? 0) - 1 : (selectedRows.max() ?? -1) + 1
            guard rows.indices.contains(bound) else { return }
            setSelection([bound], anchor: bound, active: bound)
            tableView.scrollRowToVisible(bound)
        }
    }

    /// The selected row farthest from the anchor — the end a Shift+↑/↓ moves when
    /// no explicit active end is tracked yet.
    private func farSelectedEnd(from anchor: Int) -> Int {
        let lo = selectedRows.min() ?? anchor, hi = selectedRows.max() ?? anchor
        return (anchor - lo) >= (hi - anchor) ? lo : hi
    }

    /// Click-driven selection: shift extends a contiguous range from the
    /// anchor; cmd toggles a single row.
    func selectViaClick(_ id: UUID, extend: Bool, toggle: Bool) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        if focusedBlockID != nil { endEditing() }
        if toggle {
            var next = selectedRows
            let anchor: Int?
            if next.contains(index) { next.remove(index); anchor = selectionAnchor }
            else { next.insert(index); anchor = index }
            setSelection(next, anchor: anchor)
        } else if extend, let anchor = selectionAnchor {
            setSelection(Set(min(anchor, index)...max(anchor, index)), anchor: anchor, active: index)
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
        guard let markdown = selectionMarkdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    /// `⌘X`: the same Markdown `⌘C` would write, and the same removal `⌦` would
    /// make — as one undo step, so one undo brings the blocks back. The pasteboard
    /// is written only once the removal has gone ahead: declining the "referenced
    /// elsewhere" prompt leaves both the page and the clipboard as they were.
    private func cutSelection() {
        guard let markdown = selectionMarkdown() else { return }
        guard deleteSelection(labelledCut: true) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    /// The selected blocks as Markdown, or nil when there is nothing to write.
    private func selectionMarkdown() -> String? {
        // Take exactly the selected rows (re-based to the shallowest one's
        // depth), not each block's whole subtree — selecting a parent plus one
        // child must not drag in the parent's *unselected* children. Exception:
        // a collapsed block's children are hidden and can't be selected, so its
        // full subtree is included.
        let doc = app.document(for: pageName)
        let selected = selectedRows.sorted().filter { rows.indices.contains($0) }
        guard let baseDepth = selected.map({ rows[$0].depth }).min() else { return nil }
        var out = ""
        for row in selected {
            // Resolve the live block (row caches go stale for a block whose
            // descendant was just edited — see `copySubtreeMarkdown`).
            guard let block = doc.blocks.block(id: rows[row].block.id) else { continue }
            let pad = String(repeating: "  ", count: max(0, rows[row].depth - baseDepth))
            if !block.children.isEmpty, block.collapsed {
                for line in OutlineOps.copyMarkdown(block).components(separatedBy: "\n")
                where !line.isEmpty {
                    out += pad + line + "\n"
                }
            } else {
                let lines = block.content.isEmpty ? [""] : block.content.components(separatedBy: "\n")
                out += pad + "- " + lines[0] + "\n"
                for line in lines.dropFirst() { out += pad + "  " + line + "\n" }
            }
        }
        return out.isEmpty ? nil : out
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

    /// Removes the selected blocks. Returns false when there was nothing to remove
    /// or the reference prompt was declined, so `cutSelection` can leave the
    /// pasteboard alone.
    @discardableResult
    private func deleteSelection(labelledCut: Bool = false) -> Bool {
        let ids = selectedRows.sorted().compactMap { rows.indices.contains($0) ? rows[$0].block.id : nil }
        guard !ids.isEmpty else { return false }
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
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        var doc = app.document(for: pageName)
        Self.removeBlocks(Set(ids), from: &doc.blocks)
        if doc.blocks.isEmpty { doc.blocks = [Block(content: "")] } // keep one block
        commitStructural(doc, label: Self.removalLabel(count: ids.count, isCut: labelledCut))
        clearSelection()
        reloadAndFocus(nil, selection: nil)
        return true
    }

    /// Undo-menu wording for a removal: a cut is one action, not a copy and a delete.
    static func removalLabel(count: Int, isCut: Bool) -> String {
        switch (isCut, count == 1) {
        case (true, true): return "Cut Block"
        case (true, false): return "Cut Blocks"
        case (false, true): return "Delete Block"
        case (false, false): return "Delete Blocks"
        }
    }

    /// Recursively drops any block whose id is in `ids` (with its subtree).
    private static func removeBlocks(_ ids: Set<UUID>, from blocks: inout [Block]) {
        blocks.removeAll { ids.contains($0.id) }
        for i in blocks.indices { removeBlocks(ids, from: &blocks[i].children) }
    }

    /// Tab / Shift+Tab on a node selection: indent the selected run under the
    /// block above it, or outdent it one level. Acts on the top-most selected
    /// blocks (a selected child rides with its selected ancestor); they must be
    /// contiguous siblings, else it's a no-op. A single block keeps the classic
    /// outdent (which adopts trailing siblings); a run uses a plain group-lift.
    private func indentOutdentSelection(outdent: Bool) {
        let selectedIDs = Set(selectedRows.compactMap {
            rows.indices.contains($0) ? rows[$0].block.id : nil
        })
        let ids = topMostSelectedRows().compactMap {
            rows.indices.contains($0) ? rows[$0].block.id : nil
        }
        guard !ids.isEmpty else { return }
        var doc = app.document(for: pageName)
        let paths = ids.compactMap { doc.blocks.path(to: $0) }
        guard paths.count == ids.count else { return }
        let ok: Bool
        if paths.count == 1 {
            ok = outdent ? OutlineOps.outdent(paths[0], in: &doc.blocks)
                         : OutlineOps.indent(paths[0], in: &doc.blocks)
        } else {
            ok = outdent ? OutlineOps.outdentRun(paths, in: &doc.blocks)
                         : OutlineOps.indentRun(paths, in: &doc.blocks)
        }
        guard ok else { return }
        commitStructural(doc, label: outdent ? "Outdent" : "Indent")
        reloadAndFocus(nil, selection: nil)
        let newSelection = Set(rows.indices.filter { selectedIDs.contains(rows[$0].block.id) })
        if !newSelection.isEmpty { setSelection(newSelection, anchor: newSelection.min()) }
    }

    /// ⌥↑/⌥↓ with a node selection: moves the selected blocks (subtrees) as one
    /// unit. A selected descendant travels with its selected ancestor, so only
    /// the top-most blocks move; they must be contiguous siblings.
    private func moveSelection(by delta: Int) {
        let ids = topMostSelectedRows().compactMap {
            rows.indices.contains($0) ? rows[$0].block.id : nil
        }
        guard !ids.isEmpty else { return }
        // Captured by id so the same blocks can be re-selected at their new rows.
        let selectedIDs = Set(selectedRows.compactMap {
            rows.indices.contains($0) ? rows[$0].block.id : nil
        })
        var doc = app.document(for: pageName)
        let paths = ids.compactMap { doc.blocks.path(to: $0) }
        guard paths.count == ids.count,
              OutlineOps.moveRun(paths, by: delta, in: &doc.blocks) else { return }
        commitStructural(doc, label: ids.count == 1 ? "Move Block" : "Move Blocks")
        reloadAndFocus(nil, selection: nil)
        let newSelection = Set(rows.indices.filter { selectedIDs.contains(rows[$0].block.id) })
        setSelection(newSelection, anchor: newSelection.min())
    }

    // MARK: - Bullet drag-and-drop (SPEC §5.4)

    /// Starts a bullet drag. When the pressed block is part of the node
    /// selection the whole selection travels (top-most blocks; descendants ride
    /// with their ancestors); otherwise just this block and its subtree.
    private func beginDragSession(for id: UUID, event: NSEvent, from view: NSView) {
        guard let row = rows.firstIndex(where: { $0.block.id == id }) else { return }
        if focusedBlockID != nil { endEditing() }
        let dragRows: [Int]
        if selectedRows.contains(row) {
            dragRows = topMostSelectedRows()
        } else {
            clearSelection()
            dragRows = [row]
        }
        draggingIDs = dragRows.compactMap { rows.indices.contains($0) ? rows[$0].block.id : nil }
        guard !draggingIDs.isEmpty else { return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(pageName, forType: Self.blockDragType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        // Drag image: a snapshot of the pressed row.
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
           let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) {
            cell.cacheDisplay(in: cell.bounds, to: rep)
            let image = NSImage(size: cell.bounds.size)
            image.addRepresentation(rep)
            item.setDraggingFrame(view.convert(cell.bounds, from: cell), contents: image)
        } else {
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 160, height: 20), contents: nil)
        }
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Insertion path for a proposed drop. Between rows
    /// (`.above`) inserts as the sibling before that row's block; onto a row
    /// (`.on`) inserts as its first child.
    private func insertionPath(row: Int, operation: NSTableView.DropOperation,
                               in doc: PageDocument) -> [Int]? {
        if operation == .on {
            guard rows.indices.contains(row),
                  let targetPath = doc.blocks.path(to: rows[row].block.id) else { return nil }
            return targetPath + [0]
        } else if rows.indices.contains(row) {
            return doc.blocks.path(to: rows[row].block.id)
        } else if let zoom, let zoomPath = doc.blocks.path(to: zoom) {
            // Below the last row of a zoomed outline: append to the zoom root.
            return zoomPath + [doc.blocks.block(at: zoomPath)?.children.count ?? 0]
        } else {
            return [doc.blocks.count]
        }
    }

    /// Internal block-move destination, rejecting drops into dragged subtrees.
    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> [Int]? {
        let doc = app.document(for: pageName)
        let draggedPaths = draggingIDs.compactMap { doc.blocks.path(to: $0) }
        guard !draggedPaths.isEmpty, draggedPaths.count == draggingIDs.count,
              let dest = insertionPath(row: row, operation: operation, in: doc) else { return nil }
        for p in draggedPaths where dest.count >= p.count && Array(dest.prefix(p.count)) == p {
            return nil
        }
        return dest
    }

    /// Called from every `validateDrop` proposal. Hovering `.on` a collapsed
    /// row for a moment expands it mid-drag (Finder folder spring-loading), so
    /// the drop can land inside; moving the proposal elsewhere cancels the
    /// pending expansion. Expand-on-drop remains the fallback for a drop that
    /// lands before the spring fires.
    private func updateSpringLoad(row: Int, operation: NSTableView.DropOperation) {
        let target: UUID? = (operation == .on && rows.indices.contains(row)
            && rows[row].block.collapsed) ? rows[row].block.id : nil
        guard target != springBlockID else { return }
        cancelSpringLoad()
        guard let target else { return }
        springBlockID = target
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.springBlockID == target else { return }
            self.springBlockID = nil
            self.toggleFold(target)
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func cancelSpringLoad() {
        springWork?.cancel()
        springWork = nil
        springBlockID = nil
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? NSURL).map { $0 as URL } }
            .filter(GraphStore.isImageFile) ?? []
        return urls.isEmpty ? nil : urls
    }

    // MARK: - Commits

    /// Records a structural op as its own undo step. Any keystrokes typed since
    /// the block was focused are first flushed into a *separate* undo step, so
    /// undoing the op reverts only the op — not the typing that preceded it
    /// (each Cmd+Z undoes one action, SPEC §13).
    private func commitStructural(_ doc: PageDocument, label: String) {
        flushEditSessionUndo()
        let before = app.document(for: pageName)
        app.commit(doc, undoLabel: label, before: before)
        editSessionBefore = doc
    }

    /// Closes the current text-editing session into a single undo step. Plain
    /// typing (content or properties) commits without undo entries; this turns
    /// "everything typed in this block since focus" into one undoable change,
    /// so Cmd+Z after editing doesn't jump to a far older state.
    /// Closes the current typing run so an undo can act on it, then re-baselines
    /// the run once that undo has landed — otherwise the next close would measure
    /// against the pre-undo state and push an entry reinstating what was undone.
    private func closeEditSessionForUndo() {
        flushEditSessionUndo()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusedBlockID != nil else { return }
            self.editSessionBefore = self.app.document(for: self.pageName)
        }
    }

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
            },
            beginDrag: { [weak self] event, view in
                self?.beginDragSession(for: id, event: event, from: view)
            },
            resizeImage: { [weak self] imageIndex, width in
                self?.resizeImage(id, imageIndex: imageIndex, width: width)
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
        // The rendered TODO/DONE checkbox carries this URL (SPEC §5.2). In a
        // query result or embed it names the source block via `?block=`;
        // otherwise it's the clicked row's own block.
        if url.scheme == "knopo", url.host == "toggle-todo" {
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "block" }?
                .value.flatMap { UUID(uuidString: $0) } ?? blockID
            if app.toggleTodo(blockID: target) {
                reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                    ? editor.selectedRange() : nil)
            }
            return
        }
        nav.openURL(url, inSidebar: inSidebar)
    }

    private func resizeImage(_ id: UUID, imageIndex: Int, width: CGFloat) {
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id),
              let block = doc.blocks.block(at: path),
              let content = InlineParser.settingImageWidth(
                block.content, imageIndex: imageIndex, width: Int(width.rounded())
              ) else { return }
        doc.blocks.update(at: path) { $0.content = content }
        app.commit(doc, undoLabel: "Resize Image")
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
            ? editor.selectedRange() : nil)
    }

    private func focusFromClick(_ id: UUID, renderedIndex: Int) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        let length = (rows[index].block.content as NSString).length
        let offset = Self.sourceOffset(inRendered: rows[index].rendered, at: renderedIndex)
            // Nothing recorded (a fence, a table, a generated region): the
            // rendered text tracks the source closely enough to clamp.
            ?? min(max(0, renderedIndex), length)
        focusBlock(id, selection: NSRange(location: min(offset, length), length: 0))
    }

    /// Where a click in rendered text lands in the block's source. The rendered
    /// form hides markers and rewrites titles, so the two index spaces differ;
    /// `BlockRenderer` records each run's source offset and whether the run is
    /// verbatim, which is what makes an offset *within* a run meaningful.
    /// Returns nil when the run carries no offset.
    static func sourceOffset(inRendered rendered: NSAttributedString, at index: Int) -> Int? {
        guard rendered.length > 0 else { return nil }
        let probe = min(max(0, index), rendered.length - 1)
        var effective = NSRange(location: 0, length: 0)
        guard let offset = rendered.attribute(
            BlockRenderer.sourceOffsetKey, at: probe, effectiveRange: &effective) as? Int
        else { return nil }
        let verbatim = rendered.attribute(
            BlockRenderer.sourceVerbatimKey, at: probe, effectiveRange: nil) != nil
        // A verbatim run maps character for character; anything else maps as a
        // whole to where its token starts in the source.
        return verbatim ? offset + max(0, min(index, rendered.length) - effective.location) : offset
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
        // don't show as blue underlined links (and no `knopo://` tooltips).
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
            inlineQuoteBar: false,
            tables: false)) // no room for a grid in a popover (§5.2)
    }


    // MARK: - Context menu (SPEC §7.1, §13)

    private func showContextMenu(for id: UUID, event: NSEvent, in view: NSView) {
        // Right-clicking a block that's part of a multi-block selection acts on
        // the whole selection (like Finder), not just that one block.
        if selectedRows.count > 1,
           let row = rows.firstIndex(where: { $0.block.id == id }), selectedRows.contains(row) {
            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy \(selectedRows.count) Blocks",
                                  action: #selector(copySelectionAction), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete \(selectedRows.count) Blocks",
                                    action: #selector(deleteSelectionAction), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
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

    @objc private func copySelectionAction() { copySelection() }
    @objc private func deleteSelectionAction() { deleteSelection() }

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
        // Read the live document, not the row cache: after typing in a child, a
        // parent row's cached `.children` still holds the child's stale (often
        // empty) content, so copying from it drops or blanks that child.
        guard let id = sender.representedObject as? UUID,
              let block = app.document(for: pageName).blocks.block(id: id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(OutlineOps.copyMarkdown(block), forType: .string)
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
        let previouslyHighlighted = findRows
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
        findRows = Set(findMatches.map(\.row))
        findCurrentRow = nil
        // Only rows whose highlight changed need re-rendering — a full reload on
        // every keystroke re-renders the whole page and makes typing crawl.
        reloadFindRows(previouslyHighlighted.union(findRows))
        return findMatches.count
    }

    func findSetCurrent(_ localIndex: Int?) {
        findCurrentLocal = localIndex
        let newCurrentRow = localIndex.flatMap {
            findMatches.indices.contains($0) ? findMatches[$0].row : nil
        }
        // Re-render only the old and new current rows (the emphasized match), not
        // the whole table.
        reloadFindRows(Set([findCurrentRow, newCurrentRow].compactMap { $0 }))
        findCurrentRow = newCurrentRow
        if let newCurrentRow {
            // Defer: the just-reloaded row's rect is briefly stale, so scrolling
            // immediately can land short (notably in the journal's shared scroll).
            DispatchQueue.main.async { [weak self] in
                guard let self, newCurrentRow < self.tableView.numberOfRows else { return }
                self.tableView.scrollRowToVisible(newCurrentRow)
            }
        }
    }

    func findClear() {
        findActive = false
        findQuery = ""
        findMatches = []
        findCurrentLocal = nil
        let previouslyHighlighted = findRows
        findRows = []
        findCurrentRow = nil
        reloadFindRows(previouslyHighlighted)
    }

    /// Reloads just the given rows' cells (skips out-of-range indexes). Find
    /// highlighting never changes text length, so row heights are unaffected.
    private func reloadFindRows(_ indexes: Set<Int>) {
        let valid = IndexSet(indexes.filter { $0 >= 0 && $0 < tableView.numberOfRows })
        guard !valid.isEmpty else { return }
        tableView.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - Table data source / delegate

extension OutlineEditorController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count // an empty outline gets a real block instead (§5.4)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let model = rows[row]
        let cell = tableView.makeView(
            withIdentifier: OutlineRowCell.reuseIdentifier, owner: nil
        ) as? OutlineRowCell ?? OutlineRowCell(frame: .zero)
        cell.identifier = OutlineRowCell.reuseIdentifier
        // Cells are reused: this one may be the one carrying the flash, now handed
        // a different block. Left alone, the flash would go on lighting up a row
        // nobody clicked (two lit rows, once the real one is flashed as well).
        if cell === flashedCell, model.block.id != flashedBlockID {
            cell.cancelFlash()
            flashedCell = nil
        }
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
        let isEmptyLeaf = Self.hidesBullet(
            content: model.block.content, hasChildren: model.hasChildren,
            isFocused: model.block.id == focusedBlockID, isOnlyRow: rows.count == 1)
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
        guard rows.indices.contains(row) else { return OutlineRowCell.minRowHeight }
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
        // Measuring is a full TextKit layout pass and `reloadData` asks for
        // every row — reuse the height while the block's render signature and
        // content width are unchanged.
        if let signature = renderSignature(for: model.block, contentWidth: contentWidth),
           var entry = renderCache[model.block.id], entry.signature == signature {
            if let height = entry.height, entry.measuredWidth == contentWidth {
                return height
            }
            let height = OutlineRowCell.height(for: model.rendered, contentWidth: contentWidth)
            entry.height = height
            entry.measuredWidth = contentWidth
            renderCache[model.block.id] = entry
            return height
        }
        return OutlineRowCell.height(for: model.rendered, contentWidth: contentWidth)
    }

    // MARK: Drag and drop (SPEC §5.4)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if (info.draggingSource as? OutlineEditorController) === self {
            guard dropDestination(row: row, operation: operation) != nil else {
                updateSpringLoad(row: -1, operation: .above)
                return []
            }
            updateSpringLoad(row: row, operation: operation)
            return .move
        }
        let doc = app.document(for: pageName)
        guard imageFileURLs(from: info.draggingPasteboard) != nil,
              insertionPath(row: row, operation: operation, in: doc) != nil else {
            updateSpringLoad(row: -1, operation: .above)
            return []
        }
        updateSpringLoad(row: row, operation: operation)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        cancelSpringLoad()
        if (info.draggingSource as? OutlineEditorController) !== self {
            guard let fileURLs = imageFileURLs(from: info.draggingPasteboard) else { return false }
            var doc = app.document(for: pageName)
            guard let dest = insertionPath(row: row, operation: operation, in: doc) else {
                return false
            }
            let blocks = fileURLs.compactMap { url -> Block? in
                guard let name = try? app.store.importAsset(from: url) else { return nil }
                return Block(content: GraphStore.imageMarkdown(assetNamed: name))
            }
            guard !blocks.isEmpty else { return false }
            for (offset, block) in blocks.enumerated() {
                var path = dest
                path[path.count - 1] += offset
                doc.blocks.insert(block, at: path)
            }
            // Dropping into a collapsed parent: expand it so the result is visible.
            if operation == .on, rows.indices.contains(row),
               let parentPath = doc.blocks.path(to: rows[row].block.id) {
                doc.blocks.update(at: parentPath) { $0.collapsed = false }
            }
            commitStructural(doc, label: blocks.count == 1 ? "Insert Image" : "Insert Images")
            clearSelection()
            reloadAndFocus(nil, selection: nil)
            return true
        }

        guard let dest = dropDestination(row: row, operation: operation) else { return false }
        var doc = app.document(for: pageName)
        let paths = draggingIDs.compactMap { doc.blocks.path(to: $0) }
        guard paths.count == draggingIDs.count,
              OutlineOps.move(paths, to: dest, in: &doc.blocks) else { return false }
        // Dropping into a collapsed parent: expand it so the result is visible.
        if operation == .on, rows.indices.contains(row),
           let parentPath = doc.blocks.path(to: rows[row].block.id) {
            doc.blocks.update(at: parentPath) { $0.collapsed = false }
        }
        let movedIDs = Set(draggingIDs)
        commitStructural(doc, label: movedIDs.count == 1 ? "Move Block" : "Move Blocks")
        clearSelection()
        reloadAndFocus(nil, selection: nil)
        let newSelection = Set(rows.indices.filter { movedIDs.contains(rows[$0].block.id) })
        if !newSelection.isEmpty { setSelection(newSelection, anchor: newSelection.min()) }
        return true
    }
}

extension OutlineEditorController: NSDraggingSource {

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        draggingIDs = []
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
        // After the height update: a keystroke that wrapped a new line has to
        // scroll against the row's *new* size, not the one it had a moment ago.
        editor.revealCaret()
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

    /// `↑`/`↓` off the first/last visual line moves to the adjacent block, landing
    /// in the same column the caret already occupied — the way a vertical move
    /// behaves within one text view. The column is carried across consecutive
    /// hops (a short block in between doesn't pull the caret to its end) and
    /// dropped as soon as the caret moves for any other reason.
    func editorFocusAdjacent(by delta: Int) {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        let target = index + delta
        guard rows.indices.contains(target) else { return }
        let block = rows[target].block
        let goalX = verticalGoalX ?? editor.caretX
        // Without a column to aim at, fall back to the near edge of the text.
        let caret = delta < 0 ? (block.content as NSString).length : 0
        focusBlock(block.id, selection: NSRange(location: caret, length: 0))
        guard let goalX else { return }
        editor.placeCaret(atGoalX: goalX, onFirstLine: delta > 0)
        editor.revealCaret()
        // Set last: focusing and placing both report caret moves, which clear it.
        verticalGoalX = goalX
    }

    func editorCaretMoved() {
        verticalGoalX = nil
        // Only for a caret move in a *focused* editor. `attachEditor` sets the
        // selection before handing over first responder, and scrolling there
        // re-lays out the table under the cell we are attaching to — which
        // detaches the editor again and the block never takes focus at all.
        guard editor.window?.firstResponder === editor else { return }
        editor.revealCaret()
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

    func editorImportImageAssets(_ fileURLs: [URL]) -> String? {
        let markdown = fileURLs.compactMap { url -> String? in
            guard GraphStore.isImageFile(url),
                  let name = try? app.store.importAsset(from: url) else { return nil }
            return GraphStore.imageMarkdown(assetNamed: name)
        }
        return markdown.isEmpty ? nil : markdown.joined(separator: " ")
    }

    func editorImportPastedImage(png data: Data) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let preferredName = "pasted-\(formatter.string(from: Date())).png"
        guard let name = try? app.store.saveAsset(data, preferredName: preferredName) else {
            return nil
        }
        return GraphStore.imageMarkdown(assetNamed: name, alt: "image")
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
