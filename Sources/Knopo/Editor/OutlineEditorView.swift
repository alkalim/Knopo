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
    /// Shared scroll views know their width before AppKit measures the rows.
    var initialWidth: CGFloat? = nil
    /// Feed outlines can coexist with an incoming day page during navigation.
    var inJournalFeed = false

    var body: some View {
        OutlineEditorRepresentable(
            app: app, nav: nav, pageName: pageName, zoom: zoom,
            inPane: inPane, inJournalFeed: inJournalFeed, initialWidth: initialWidth, dataVersion: app.dataVersion,
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
    let inJournalFeed: Bool
    let initialWidth: CGFloat?
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

    func makeNSView(context: Context) -> OutlineContainerView {
        let controller = OutlineEditorController(app: app, nav: nav)
        let container = OutlineContainerView(tableView: controller.tableView)
        controller.inPane = inPane
        controller.inJournalFeed = inJournalFeed
        controller.applyPaneRole()
        context.coordinator.controller = controller
        context.coordinator.find = nav.find
        container.onWindowChange = { [weak controller, weak find = nav.find] attached in
            guard let controller else { return }
            if attached { find?.register(controller) }
            else {
                controller.endEditing()
                find?.unregister(controller)
            }
        }
        controller.initialLayoutWidth = initialWidth
        if let initialWidth {
            // Avoid a full text-layout pass at the table's zero-width default.
            controller.tableView.setFrameSize(NSSize(width: initialWidth, height: 0))
        }
        controller.present(pageName: pageName, zoom: zoom)
        return container
    }

    func updateNSView(_ nsView: OutlineContainerView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        // Width changes use the table's layout path. Do not refresh queries
        // and embeds on every resize frame unless the data also changed.
        let refreshContent = controller.initialLayoutWidth == initialWidth
            || context.coordinator.dataVersion != dataVersion
        let widthChanged = controller.initialLayoutWidth != initialWidth
        if widthChanged {
            // SwiftUI can update this input before it resizes the scroll view.
            OutlineScrollAnchor.preserve(beforeResizing: nsView, widthChanged: true)
        }
        context.coordinator.dataVersion = dataVersion
        controller.initialLayoutWidth = initialWidth
        controller.present(pageName: pageName, zoom: zoom, refreshContent: refreshContent)
        // Any registered outline driving this is fine; the coordinator dedupes.
        nav.find.sync(active: findActive, query: findQuery,
                      stepToken: findStepToken, forward: findForward)
    }

    static func dismantleNSView(_ nsView: OutlineContainerView, coordinator: Coordinator) {
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
        var dataVersion: Int?
    }
}

// MARK: - Self-sizing table view

/// Animates the outline's height while AppKit rows keep their final geometry.
final class OutlineContainerView: NSView {
    let tableView: OutlineTableView
    var onWindowChange: ((Bool) -> Void)?
    private var heightAnimationID: UUID?
    var isAnimatingHeight: Bool { heightAnimationID != nil }
    @objc private dynamic var animatedHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    init(tableView: OutlineTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(tableView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: heightAnimationID == nil ? tableView.intrinsicContentSize.height : animatedHeight)
    }

    override func layout() {
        super.layout()
        tableView.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                height: max(bounds.height, tableView.intrinsicContentSize.height))
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == #keyPath(animatedHeight) { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    func performRowUpdates(animated: Bool, _ updates: () -> Void) {
        performHeightUpdates(from: intrinsicContentSize.height, animated: animated,
                             duration: 0.16, updates)
    }

    func animateEditHeight(from height: CGFloat, duration: CFTimeInterval) {
        guard abs(height - tableView.intrinsicContentSize.height) > 0.5 else { return }
        performHeightUpdates(from: height, animated: true, duration: duration) {}
    }

    private func performHeightUpdates(from startHeight: CGFloat, animated: Bool,
                                      duration: CFTimeInterval,
                                      _ updates: () -> Void) {
        cancelHeightAnimation()
        let animationID = UUID()
        if animated {
            animatedHeight = startHeight
            heightAnimationID = animationID
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? duration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            updates()
            if animated { animator().animatedHeight = tableView.intrinsicContentSize.height }
        }, completionHandler: { [weak self] in
            guard let self, self.heightAnimationID == animationID else { return }
            self.heightAnimationID = nil
            self.invalidateIntrinsicContentSize()
        })
    }

    func cancelHeightAnimation() {
        guard heightAnimationID != nil else { return }
        heightAnimationID = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().animatedHeight = animatedHeight
        }
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
        if window == nil { cancelHeightAnimation() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 {
            OutlineScrollAnchor.preserve(beforeResizing: self)
            cancelHeightAnimation()
        }
        super.setFrameSize(newSize)
    }
}

/// The outline lives inside the page's SwiftUI ScrollView, so the table
/// reports its full content height as intrinsic size and never scrolls itself.
final class OutlineTableView: NSTableView, NSMenuItemValidation {

    var blockEditAnimation = BlockEditAnimation() {
        didSet { oldValue.cancel() }
    }
    var onWidthChange: (() -> Void)?
    /// Every layout pass, so a pending reveal can notice that the rows moved under
    /// it — including AppKit's own re-measures, which no delegate call announces.
    var onDidLayout: (() -> Void)?
    var onLiveResizeEnd: (() -> Void)?
    var usesSharedScrollView = false
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

    func performRowUpdates(animated: Bool, _ updates: () -> Void) {
        if let container = superview as? OutlineContainerView {
            container.performRowUpdates(animated: animated, updates)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                updates()
            }
        }
    }

    func cancelHeightAnimation() {
        (superview as? OutlineContainerView)?.cancelHeightAnimation()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        (superview as? OutlineContainerView)?.invalidateIntrinsicContentSize()
    }

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
        blockEditAnimation.cancel()
        cancelHeightAnimation()
        tracedMutation("reloadData") { super.reloadData() }
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        blockEditAnimation.cancel()
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
        blockEditAnimation.cancel()
        cancelHeightAnimation()
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
        // NSTableView does not implement this optional callback. Calling super
        // throws and prevents AppKit from finishing the drag session.
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        let height = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 28
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 28))
    }

    override var visibleRect: NSRect {
        guard (superview as? OutlineContainerView)?.isAnimatingHeight == true,
              let clip = enclosingScrollView?.contentView else { return super.visibleRect }
        // Keep moving rows alive beyond the container's temporary clip.
        // The surrounding scroll view still limits how many rows are prepared.
        let extent = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                            height: max(bounds.height, intrinsicContentSize.height))
        return extent.intersection(convert(clip.bounds, from: clip))
    }

    private var preparingVisibleRows = false

    override func tile() {
        let wasPreparing = preparingVisibleRows
        preparingVisibleRows = true
        defer { preparingVisibleRows = wasPreparing }
        super.tile()
    }

    @discardableResult
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        // NSTableView.tile scrolls its origin into view while resizing columns.
        // These tables share a scroll view, so an offscreen day must not move it.
        guard !usesSharedScrollView || (!preparingVisibleRows && updateDepth == 0) else { return false }
        return super.scrollToVisible(rect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 {
            OutlineScrollAnchor.preserve(beforeResizing: self)
            blockEditAnimation.cancel()
            (delegate as? OutlineEditorController)?.invalidateWidthMeasurement()
        }
        let wasPreparing = preparingVisibleRows
        preparingVisibleRows = true
        super.setFrameSize(newSize)
        preparingVisibleRows = wasPreparing
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OutlineScrollAnchor.register(self)
        if window != nil { (delegate as? OutlineEditorController)?.invalidateWidthMeasurement() }
        if window == nil { blockEditAnimation.cancel() }
    }

    override func layout() {
        let wasPreparing = preparingVisibleRows
        preparingVisibleRows = true
        if let column = tableColumns.first, abs(column.width - bounds.width) > 0.5 {
            column.width = bounds.width
        }
        updateDepth += 1
        super.layout()
        preparingVisibleRows = wasPreparing
        updateDepth -= 1
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            onWidthChange?()
        }
        onDidLayout?()
    }

    override func rows(in rect: NSRect) -> NSRange {
        // In a shared scroll view, AppKit's preparation rect can extend by the
        // pane's offset in the document. Later panes then build every row.
        // Keep a half-viewport prefetch margin during row preparation. AppKit
        // retains the first responder's row separately from this range.
        // Explicit geometry queries and standalone outlines stay unrestricted.
        guard usesSharedScrollView, preparingVisibleRows || updateDepth > 0 else {
            return super.rows(in: rect)
        }
        let viewport = enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) }
            ?? visibleRect
        let visible = viewport.intersection(bounds)
        guard !visible.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        let buffered = visible.insetBy(dx: 0, dy: -visible.height / 2)
        let clipped = rect.intersection(buffered)
        guard !clipped.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return super.rows(in: clipped)
    }

    override func viewWillDraw() {
        (delegate as? OutlineEditorController)?.refreshVisibleWidth()
        let wasPreparing = preparingVisibleRows
        preparingVisibleRows = true
        defer { preparingVisibleRows = wasPreparing }
        super.viewWillDraw()
    }

    override func accessibilityChildren() -> [Any]? {
        guard usesSharedScrollView else { return super.accessibilityChildren() }
        // Walking offscreen row children makes AppKit construct their cells.
        // Expose visible rows and the editor's row in the child tree.
        // accessibilityRows still provides every row for table navigation.
        // Use the untyped protocol API because AppKit's row proxies do not
        // conform to NSAccessibilityRow. Compare their identity as AnyObject.
        let accessibility = self as NSAccessibilityProtocol
        var children = accessibility.accessibilityVisibleRows() ?? []
        if let editor = window?.firstResponder as? NSView, editor.isDescendant(of: self) {
            let index = row(for: editor)
            if index >= 0, let rows = accessibility.accessibilityRows(), index < rows.count {
                let focusedRow = rows[index] as AnyObject
                if !children.contains(where: { ($0 as AnyObject) === focusedRow }) {
                    children.append(focusedRow)
                }
            }
        }
        return children
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
        var marker: OutlineNumbering.Marker?
        var geometry: OutlineMarkerLayout.Geometry
        var rendered: NSAttributedString
        var renderedWidth: CGFloat
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
        let rightPaneNavigationToken: Int
        /// Whether to flash the row on arrival - a caret is its own answer.
        let flashes: Bool
        /// Whether to bring what precedes the row along with it: a caret to write
        /// at belongs at the foot of the view, a clicked result wherever it lands.
        let showsRunUp: Bool
        /// Where the row sat when it was last scrolled to; nil before the first.
        var rowMinY: CGFloat?
        let settlingTime: TimeInterval
        /// Starts when the outline reaches a window and can scroll. After this
        /// deadline, edits and resizing must not pull the reader back.
        var until: TimeInterval?
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
    @discardableResult
    private func reloadAllRows() -> Set<UUID> {
        tableView.reloadData()
        revealIfPossible()
        return Set(rows.map(\.block.id))
    }
    /// The cell showing the current flash and the block it was lit for, so the
    /// flash can be taken off when that cell is reused for another row, or when a
    /// later reveal lights a different one.
    private weak var flashedCell: OutlineRowCell?
    private(set) var flashedBlockID: UUID?
    /// Whether this outline is a right-sidebar pane. Panes are for reference: they
    /// never take focus on presentation, and a main outline may take focus from one
    /// (§5.4). Applied to the editor by `applyPaneRole`.
    var inPane = false
    /// A result opens a standalone page. The feed's own outline for that day
    /// must leave the highlight request alone.
    var inJournalFeed = false

    /// Lets other outlines recognise this outline's editor as a pane's, when they
    /// decide whether taking focus is allowed.
    func applyPaneRole() {
        editor.isInPane = inPane
        tableView.usesSharedScrollView = inPane || inJournalFeed
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
    /// Typing and structural undo share one session and its starting state.
    private struct EditSession {
        var before: PageDocument
        var initial: OutlineEditorSnapshot
        var current: OutlineEditorSnapshot
    }
    private var editSession: EditSession?

    private func currentOutlineEditorSnapshot() -> OutlineEditorSnapshot? {
        guard var state = editSession?.current, state.id == focusedBlockID else { return nil }
        state.text = editor.string
        state.selection = editor.selectedRange()
        return state
    }

    func restoreEditing(_ state: OutlineEditorSnapshot?, onPage page: String) {
        guard pageName == page, let state else { return }
        Self.selectionOwner?.clearSelection()
        let doc = app.document(for: page)
        guard doc.blocks.block(id: state.id) != nil else { return }
        editSession = EditSession(before: doc, initial: state, current: state)
        reloadAndFocus(state.id, selection: state.selection)
    }

    func rebaseEditingAfterUndo() {
        guard let state = currentOutlineEditorSnapshot() else { return }
        editSession?.before = app.document(for: pageName)
        editSession?.initial = state
    }

    private func undoEditing(before: OutlineEditorSnapshot?, after: OutlineEditorSnapshot?) -> OutlineEditorUndo {
        OutlineEditorUndo(owner: self, page: pageName, before: before, after: after,
                          restore: inJournalFeed ? JournalDayHost.restorer(for: pageName, containing: tableView) : nil)
    }

    /// True while the link panel holds focus; suppresses end-of-edit teardown
    /// when the editor temporarily resigns first responder (§5.5.2).
    private var suppressFocusLoss = false
    /// Bracket setting the cached rows were rendered with; a change forces a
    /// re-render (cached `NSAttributedString`s don't otherwise update).
    private var renderedWithBrackets = BlockRenderer.bracketsEnabled
    private var renderedWithZoom = BlockRenderer.zoom
    private var renderedWithDensity = BlockRenderer.density
    private var renderedWithWeight = BlockRenderer.contentWeight
    private var renderedWithDateFormat: JournalDateFormat
    private var widthRefreshScheduled = false
    private var measuredTableWidth: CGFloat?
    private var needsFullWidthRefresh = false

    /// Bullet drag-and-drop (SPEC §5.4). The pasteboard carries only a marker —
    /// the dragged blocks live here, and drops are accepted from this controller
    /// alone (same page), so ids never round-trip through the pasteboard.
    static let blockDragType = NSPasteboard.PasteboardType("com.knopo.block-drag")
    private var draggingIDs: [UUID] = []
    /// Wait until the drop or paste finishes before opening a modal alert.
    var presentAssetImportAlert: (NSAlert) -> Void = { alert in
        DispatchQueue.main.async { alert.runModal() }
    }
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
        self.renderedWithDateFormat = app.journalDateFormat
        super.init()
        tableView.blockEditAnimation = BlockEditAnimation(reducesMotion: { [preferences = app.preferences] in
            !preferences.animationsEnabled
        })
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
        tableView.onDidLayout = { [weak self] in
            self?.revealIfPossible()
            self?.autocomplete.reposition()
        }
        tableView.onLiveResizeEnd = { [weak self] in self?.widthDidChange() }
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
        autocomplete.onNumberedListCommand = { [weak self] range in
            self?.enableNumbering(removing: range)
        }
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
                  let markdown = self.editorImportAssets(panel.urls) else { return }
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

    func present(pageName: String, zoom: UUID?, refreshContent: Bool = true) {
        // `zoom` here is the block-zoom UUID; `BlockRenderer.zoom` is the content
        // font-zoom — both flow through here.
        let bracketsChanged = BlockRenderer.bracketsEnabled != renderedWithBrackets
        let fontZoomChanged = BlockRenderer.zoom != renderedWithZoom
        let densityChanged = BlockRenderer.density != renderedWithDensity
        let weightChanged = BlockRenderer.contentWeight != renderedWithWeight
        let dateFormatChanged = BlockRenderer.journalDateFormat != renderedWithDateFormat
        renderedWithBrackets = BlockRenderer.bracketsEnabled
        renderedWithZoom = BlockRenderer.zoom
        renderedWithDensity = BlockRenderer.density
        renderedWithWeight = BlockRenderer.contentWeight
        renderedWithDateFormat = BlockRenderer.journalDateFormat
        if pageName != self.pageName || zoom != self.zoom {
            revealRequest = nil
            self.pageName = pageName
            self.zoom = zoom
            focusedBlockID = nil
            editSession = nil
            renderCache.removeAll() // another page's blocks; free the memory
            autocomplete.dismiss()
            editor.removeFromSuperview()
            rebuildRows()
            reloadAllRows()
            tableView.invalidateIntrinsicContentSize()
        } else if bracketsChanged || fontZoomChanged || densityChanged || weightChanged
                    || dateFormatChanged {
            // A global rendering preference flipped (brackets, content zoom, or
            // text density): re-render the cached rows and re-measure heights.
            reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                ? editor.selectedRange() : nil, reuseStaticRenders: false)
        } else if refreshContent {
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
        applyPendingHighlightIfNeeded()
        focusForWritingIfNeeded()
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
        // Already writing here: nothing for the automatic path to ask for, but
        // `⌘J` still moves the caret to the writing block, every press (§10).
        guard explicit || focusedBlockID == nil else { return }
        // Otherwise once per presentation: `present` runs on every data change,
        // and re-focusing would yank the caret back after a click elsewhere.
        guard explicit || autoFocusedPresentation != presentationKey else { return }
        // Nothing at all to show — an emptied file or a preamble-only file. (A
        // zoom always shows its root.) Give the page the block it needs, so every
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
            guard let self,
                  explicit || (self.focusedBlockID == nil && self.mayTakeFocus) else { return }
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

    /// Creates the block an empty outline needs. In memory only (no `commit`), so
    /// opening a page never writes to it; the block reaches disk once you type in it.
    private func materialiseFirstBlock() -> UUID {
        var doc = app.document(for: pageName)
        let block = Block(content: "")
        doc.blocks.append(block)
        app.store.updatePage(doc)
        return block.id
    }

    /// Scrolls a programmatically focused block into view, at the foot of it with
    /// the day above. A standing request, not one scroll: the row grows to fit the
    /// editor and the feed re-measures after, each pass putting the offset back.
    /// Its window is short, so it stops fighting the reader's own scrolling.
    private func revealFocusedRow(_ id: UUID) {
        requestReveal(of: id, flash: false, runUp: true, within: 0.5)
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
        guard !inJournalFeed, zoom == nil else { return }
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
        ) else {
            if inPane {
                let token = nav.rightPaneNavigationToken
                DispatchQueue.main.async { [weak self] in
                    self?.nav.revealRightPane(ifCurrent: token)
                }
            }
            return
        }
        // There is something to reveal, so this is a reading visit. Today's
        // journal must not replace it with its automatic writing focus, now or
        // on a later pass.
        autoFocusedPresentation = presentationKey
        requestReveal(of: rows[index].block.id)
    }

    /// Asks for a block to be scrolled to and flashed: as soon as the geometry means
    /// something, and again after each re-measure that moves the row, until the
    /// layout settles.
    private func requestReveal(of blockID: UUID, flash: Bool = true,
                               runUp: Bool = false, within window: TimeInterval = 2) {
        revealRequest = Reveal(blockID: blockID, rightPaneNavigationToken: nav.rightPaneNavigationToken,
                               flashes: flash, showsRunUp: runUp,
                               rowMinY: nil, settlingTime: window, until: nil)
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
        // Opening a pane supersedes any block reveal still settling in the sidebar.
        if inPane, request.rightPaneNavigationToken != nav.rightPaneNavigationToken {
            revealRequest = nil
            return
        }
        if let until = request.until, CACurrentMediaTime() >= until {
            revealRequest = nil
            return
        }
        guard tableView.window != nil, let scroll = tableView.enclosingScrollView,
              scroll.documentVisibleRect.width > 0,
              scroll.documentVisibleRect.height > 0 else { return }
        guard let row = rows.firstIndex(where: { $0.block.id == request.blockID }) else { return }
        if request.until == nil {
            revealRequest?.until = CACurrentMediaTime() + request.settlingTime
        }
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
        if request.showsRunUp {
            // Grown upwards to a windowful, so the row lands at the foot of the
            // view and a day that fits stops against the top of the feed. The
            // window's height, not this table's, which is shorter than it.
            let windowful = tableView.enclosingScrollView?.documentVisibleRect.height
                ?? tableView.visibleRect.height
            let runUp = max(0, windowful - target.height)
            target.origin.y -= runUp
            target.size.height += runUp
        }
        OutlineScrollAnchor.cancel(in: tableView)
        tableView.scrollToVisible(target)
        tableView.layoutSubtreeIfNeeded()
        revealRequest?.rowMinY = tableView.rect(ofRow: row).minY
        guard request.flashes else { return }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? OutlineRowCell else { return }
        // Cells are reused, so a flash still running on another row goes out first —
        // including one this reveal itself left on a cell that has since moved on.
        if flashedCell !== cell { flashedCell?.cancelFlash() }
        cell.flash(animationsEnabled: { [preferences = app.preferences] in preferences.animationsEnabled })
        flashedCell = cell
        flashedBlockID = request.blockID
    }

    /// Diffs the store's current state against the displayed rows; reloads
    /// (preserving focus) only when something actually changed — the common
    /// no-op being our own debounced save bumping `dataVersion`.
    private func refreshIfChanged() {
        let doc = app.document(for: pageName)
        let fresh = OutlineOps.visibleRows(in: doc.blocks, zoomRoot: zoom)
        let source = SourceNumbering(app: app, page: pageName)
        let geometry = OutlineMarkerLayout.geometry(rows: fresh, markers: source.markers, widths: source.widths)
        if !matchesCurrent(fresh) || rows.contains(where: {
            $0.marker != source.markers[$0.block.id] || $0.geometry != geometry[$0.block.id]
        }) {
            reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
                ? editor.selectedRange() : nil)
            return
        }
        // References, embeds, and queries can change without edits to this page.
        // Refresh their previews without reattaching the active editor.
        for index in rows.indices {
            let row = rows[index]
            guard row.block.id != focusedBlockID,
                  Self.renderDependsOnOtherBlocks(row.block.content) else { continue }
            let rendered = cachedRender(row.block, contentWidth: contentWidth(for: row))
            guard !rendered.isEqual(to: row.rendered) else { continue }
            rows[index].rendered = rendered
            rows[index].renderedWidth = contentWidth(for: row)
            reloadRow(index)
        }
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
        if let state = editSession?.current, let block = doc.blocks.block(id: state.id) {
            var expected = block
            expected.setEditableSource(state.text, numberingSnapshot: state.numberingSnapshot)
            if expected.content != block.content || expected.properties != block.properties {
                editSession = nil
            }
        }
        let source = SourceNumbering(app: app, page: pageName)
        let markers = source.markers
        let geometry = OutlineMarkerLayout.geometry(rows: visible, markers: markers, widths: source.widths)
        let oldByID = oldRows.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.block.id, $0) }) }
        rows = visible.map { visibleRow in
            let old = oldByID?[visibleRow.block.id]
            let layout = geometry[visibleRow.id]!
            let width = OutlineMarkerLayout.contentWidth(origin: layout.contentOrigin, rowWidth: rowLayoutWidth)
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
                && old.map { renderSignature(for: $0.block, contentWidth: $0.renderedWidth) }
                    == renderSignature(for: visibleRow.block, contentWidth: width)
            let rendered = canReuse ? old!.rendered
                : cachedRender(visibleRow.block, contentWidth: width)
            return Row(block: visibleRow.block, depth: visibleRow.depth, path: visibleRow.path,
                       hasChildren: visibleRow.hasChildren, marker: markers[visibleRow.id],
                       geometry: layout, rendered: rendered, renderedWidth: width,
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
    var initialLayoutWidth: CGFloat?

    private var rowLayoutWidth: CGFloat {
        // Keep the width hint through attachment and SwiftUI's initial probes.
        // The deferred measurement records the table's actual placed width.
        if let measuredTableWidth { return max(100, measuredTableWidth) }
        return max(initialLayoutWidth ?? tableView.bounds.width, 100)
    }

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
        hasher.combine(BlockRenderer.journalDateFormat)
        // A table lays its columns out against the row width (§5.2), so its
        // render — alone among blocks — goes stale when the width changes.
        if BlockKind.classify(block.content).isTable { hasher.combine(contentWidth) }
        if block.content.contains("((") { hasher.combine(app.dataVersion) }
        return hasher.finalize()
    }

    private func cachedRender(_ block: Block, contentWidth width: CGFloat) -> NSAttributedString {
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
    private func contentWidth(for row: Row) -> CGFloat {
        OutlineMarkerLayout.contentWidth(origin: row.geometry.contentOrigin, rowWidth: rowLayoutWidth)
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
        tableWidth: BlockRenderer.TableWidth = .max, numberedHost: Bool = false
    ) -> NSAttributedString {
        var context = BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            inlineQuoteBar: false, // the row cell draws one continuous bar
            resolveEmbed: { [weak self] target in
                self?.renderEmbed(target, contentWidth: contentWidth)
            },
            resolveQuery: { [weak self] expr in self?.renderQuery(expr) },
            contentWidth: contentWidth,
            tableWidth: tableWidth,
            todoBlockID: todoBlockID
        )
        context.generatedRegionOnNewLine = numberedHost
        return BlockRenderer.render(content: content, context: context)
    }

    /// Internal so layout tests can render a transclusion without opening a window.
    func renderEmbed(
        _ target: EmbedTarget, contentWidth: CGFloat? = nil
    ) -> NSAttributedString? {
        renderEmbed(target, embedDepth: 0, visited: [], contentWidth: contentWidth)
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
        return bullet
    }

    /// Read-only render of a `{{embed …}}` target's subtree (§7.6): an indented,
    /// bulleted, navigable transclusion with a left bar to mark it as embedded.
    /// Nested embeds resolve up to `maxEmbedDepth`; cycles (a target already in
    /// `visited`) and over-deep nesting return nil → rendered literally.
    private func renderEmbed(
        _ target: EmbedTarget, embedDepth: Int, visited: Set<EmbedTarget>,
        contentWidth: CGFloat?
    ) -> NSAttributedString? {
        guard embedDepth < 4, !visited.contains(target) else { return nil }
        let rootBlocks: [Block]
        let source: SourceNumbering
        let link: URL
        switch target {
        case .block(let id):
            guard let hit = app.store.resolveBlock(id) else { return nil }
            rootBlocks = [hit.block]
            source = SourceNumbering(app: app, page: hit.pageName)
            link = KnopoURL.block(id)
        case .page(let name):
            let blocks = app.document(for: name).blocks
            guard !blocks.isEmpty else { return nil }
            rootBlocks = blocks
            source = SourceNumbering(app: app, page: name)
            link = KnopoURL.page(name)
        }
        let nextVisited = visited.union([target])
        let body = NSMutableAttributedString()
        var count = 0
        func walk(_ blocks: [Block], origin: CGFloat) {
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
                let start = body.length
                let prefix = sourceMarkerPrefix(source.markers[block.id], slot: source.widths[block.id] ?? 0,
                                                origin: origin)
                body.append(prefix.text)
                let hang = prefix.hang
                let tableOrigin = Self.generatedRegionHorizontalPad + hang
                let available = contentWidth.map {
                    max(1, $0 - tableOrigin - Self.generatedRegionHorizontalPad)
                }
                var blockContext = BlockRenderer.Context(
                    resolveBlockRef: { [weak app] id in
                        app?.store.resolveBlock(id)?.block.content
                    },
                    assetsDir: app.store.assetsDir,
                    inlineQuoteBar: true,
                    resolveEmbed: { [weak self] t in
                        self?.renderEmbed(
                            t, embedDepth: embedDepth + 1, visited: nextVisited,
                            contentWidth: available)
                    },
                    contentWidth: available,
                    tableWidth: tableWidth(for: block)
                )
                blockContext.generatedRegionOnNewLine = block.isNumbered
                blockContext.todoBlockID = block.id  // toggle the embedded block, not the source
                let rendered = BlockRenderer.render(content: block.content, context: blockContext)
                    .mutableCopy() as! NSMutableAttributedString
                body.append(rendered)
                applySourceMarkerLayout(body, range: NSRange(location: start, length: body.length - start),
                                        prefix: prefix)
                if !block.collapsed {
                    walk(block.children, origin: prefix.hang + OutlineRowCell.indentPerDepth
                         - OutlineMarkerLayout.generatedGutter)
                }
            }
        }
        walk(rootBlocks, origin: 0)
        guard body.length > 0 else { return nil }
        // Breathing room between embedded blocks and within multi-line ones, so
        // a transclusion isn't cramped (matches the query-result treatment).
        finishRegion(body, linkAll: link, interlineSpacing: 6, lineSpacing: 4) // click → source
        return body
    }

    /// Moves paragraph indents, marker tabs, and table grids in the same coordinate system.
    private func translateLayout(_ text: NSMutableAttributedString, range: NSRange, by offset: CGFloat) {
        guard range.length > 0 else { return }
        let ns = text.string as NSString
        var position = range.location
        while position < NSMaxRange(range) {
            let paragraph = NSIntersectionRange(ns.paragraphRange(
                for: NSRange(location: position, length: 0)), range)
            var base: NSParagraphStyle?
            text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, _, stop in
                if let value = value as? NSParagraphStyle { base = value; stop.pointee = true }
            }
            let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += offset
            style.headIndent += offset
            style.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: $0.location + offset, options: $0.options)
            }
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
            position = NSMaxRange(paragraph)
        }
        text.enumerateAttribute(BlockRenderer.tableKey, in: range) { value, range, _ in
            guard let grid = value as? BlockRenderer.TableGeometry else { return }
            text.addAttribute(BlockRenderer.tableKey, value: BlockRenderer.TableGeometry(
                columnEdges: grid.columnEdges.map { $0 + offset }, rowCount: grid.rowCount), range: range)
        }
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
        let first = NSRange(location: 0,
                            length: firstBreak == NSNotFound ? body.length : firstBreak)
        if !containsTable(body, in: first) {
            addParagraphSpacing(to: body, before: 8, range: first)
        }
        let lastBreak = ns.range(of: "\n", options: .backwards).location
        let last = lastBreak == NSNotFound ? full
            : NSRange(location: lastBreak + 1, length: body.length - lastBreak - 1)
        if !containsTable(body, in: last) {
            addParagraphSpacing(to: body, after: 8, range: last)
        }
        let rightPad = Self.generatedRegionHorizontalPad
        translateLayout(body, range: full, by: Self.generatedRegionHorizontalPad)
        body.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)
                .flatMap { $0.mutableCopy() as? NSMutableParagraphStyle } ?? NSMutableParagraphStyle()
            let isTable = containsTable(body, in: range)
            if style.tailIndent == 0 { style.tailIndent = -rightPad }
            // Breathing room between rows (paragraphs) so a result list isn't
            // cramped; keeps the larger boundary spacing on the first/last line.
            if interlineSpacing > 0, !isTable {
                style.paragraphSpacing = max(style.paragraphSpacing, interlineSpacing)
            }
            // …and between the wrapped/hard-broken lines *within* one block.
            if lineSpacing > 0, !isTable {
                style.lineSpacing = max(style.lineSpacing, lineSpacing)
            }
            body.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private static let generatedRegionHorizontalPad: CGFloat = 14

    private func containsTable(_ text: NSAttributedString, in range: NSRange) -> Bool {
        var found = false
        text.enumerateAttribute(BlockRenderer.tableKey, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Paints `url` as the click target across `range`, but leaves any TODO
    /// checkbox's `knopo://toggle-todo` link intact — so a checkbox inside a
    /// query result or embed still toggles instead of navigating to the source.
    /// Renders one generated row the way a query result does, for tests.
    func renderGeneratedRow(content: String, navigatingTo url: URL) -> NSAttributedString {
        let row = NSMutableAttributedString(attributedString: BlockRenderer.render(
            content: content,
            context: BlockRenderer.Context(
                resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
                assetsDir: app.store.assetsDir, inlineQuoteBar: true, tables: false)))
        addNavigationLink(row, url, over: NSRange(location: 0, length: row.length))
        return row
    }

    /// Makes a generated row navigate somewhere. Anything inside it that
    /// already links - a ref, a block ref, a TODO checkbox - keeps its target.
    private func addNavigationLink(_ body: NSMutableAttributedString, _ url: URL, over range: NSRange) {
        body.enumerateAttribute(.link, in: range) { value, sub, _ in
            guard value == nil else { return }
            body.addAttribute(.link, value: url, range: sub)
        }
    }

    private struct MarkerPrefix {
        var text: NSAttributedString
        var origin: CGFloat
        var hang: CGFloat
        var tabs: [NSTextTab]
    }

    private func sourceMarkerPrefix(
        _ marker: OutlineNumbering.Marker?, slot: CGFloat, origin: CGFloat
    ) -> MarkerPrefix {
        let right = origin + max(OutlineMarkerLayout.minimumSlot, slot)
        let hang = right + OutlineMarkerLayout.gap
        let attributes: [NSAttributedString.Key: Any] = [
            .font: OutlineMarkerLayout.font, .foregroundColor: NSColor.secondaryLabelColor]
        let text = NSMutableAttributedString(string: "\t", attributes: attributes)
        if let marker { text.append(NSAttributedString(string: marker.label, attributes: attributes)) }
        else { text.append(Self.embedBullet()) }
        text.append(NSAttributedString(string: "\t", attributes: attributes))
        let markerRight = marker == nil
            ? right - OutlineMarkerLayout.bulletCenterOffset + BulletView.dotDiameter() / 2 : right
        return MarkerPrefix(text: text, origin: origin, hang: hang,
            tabs: [NSTextTab(textAlignment: .right, location: markerRight),
                   NSTextTab(textAlignment: .left, location: hang)])
    }

    private func applySourceMarkerLayout(
        _ text: NSMutableAttributedString, range: NSRange, prefix: MarkerPrefix
    ) {
        guard range.length > 0 else { return }
        translateLayout(text, range: range, by: prefix.hang)
        let first = NSIntersectionRange((text.string as NSString).paragraphRange(
            for: NSRange(location: range.location, length: 0)), range)
        let style = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = prefix.origin
        style.tabStops = prefix.tabs + style.tabStops.filter { $0.location > prefix.hang }
        text.addAttribute(.paragraphStyle, value: style, range: first)
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
            line(NSAttributedString(string: L("No matching blocks"), attributes: [
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
        var sources: [String: SourceNumbering] = [:]
        for hit in result.hits {
            if sources[hit.pageDisplayName] == nil {
                sources[hit.pageDisplayName] = SourceNumbering(app: app, page: hit.pageDisplayName)
            }
            let source = sources[hit.pageDisplayName]!
            let marker = source.markers[hit.blockID]
            if hit.pageDisplayName != lastPage {
                lastPage = hit.pageDisplayName
                // Journal pages show their pretty date ("Apr 21st, 2026"), not
                // the raw ISO / Logseq underscore filename form.
                let title = app.displayTitle(for: hit.pageDisplayName)
                line(NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .link: KnopoURL.page(hit.pageDisplayName)]))
            }
            // An empty block (e.g. a page-properties block surfaced by a
            // page-property query) has nothing to show; the clickable page header
            // above already lists the page, so skip the blank bullet row.
            if marker == nil && hit.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let prefix = sourceMarkerPrefix(marker, slot: source.widths[hit.blockID] ?? 0, origin: OutlineRowCell.indentPerDepth)
            let row = NSMutableAttributedString(attributedString: prefix.text)
            var hitContext = inner
            hitContext.todoBlockID = hit.blockID  // toggle this hit's block, not the host
            row.append(BlockRenderer.render(content: hit.content, context: hitContext))
            // The row navigates to that block where nothing else links. Carry
            // the page name, not a bare block id: the index id may not survive
            // a re-parse, and then the page cannot be resolved.
            addNavigationLink(row, KnopoURL.block(hit.blockID, onPage: hit.pageDisplayName),
                              over: NSRange(location: 0, length: row.length))
            applySourceMarkerLayout(row, range: NSRange(location: 0, length: row.length), prefix: prefix)
            line(row)
        }
        if result.total > result.hits.count {
            line(NSAttributedString(
                string: String(localized: "showing \(result.hits.count) of \(result.total)",
                               comment: "Query result footer: how many of the matches are listed"),
                attributes: [
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

    private func tableWidth(for block: Block) -> BlockRenderer.TableWidth {
        block.properties.first { $0.key == BlockRenderer.TableWidth.propertyKey }
            .map { BlockRenderer.TableWidth(propertyValue: $0.value) } ?? .max
    }

    /// Renders a block's content plus a dimmed `key:: value` area for its user
    /// properties, so properties are visible (and editable on focus) — §3.2.
    private func renderBlock(_ block: Block, contentWidth: CGFloat) -> NSAttributedString {
        // Tracked so a `{{query}}` can exclude its own host block from results.
        renderingBlockID = block.id
        defer { renderingBlockID = nil }
        let body = render(block.content, todoBlockID: block.id,
                         contentWidth: contentWidth, tableWidth: tableWidth(for: block), numberedHost: block.isNumbered)
        let shown = block.properties.filter {
            !Block.hiddenPropertyKeys.contains($0.key)
                && !Block.editOnlyPropertyKeys.contains($0.key)
        }
        guard !shown.isEmpty else { return body }
        let out = body.mutableCopy() as! NSMutableAttributedString
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

    private func animateStructuralEdit(insertedID: UUID? = nil, removingIDs: Set<UUID> = [],
                                       contentMove: (from: UUID, to: UUID)? = nil,
                                       duration: CFTimeInterval = BlockEditAnimation.defaultDuration,
                                       _ updates: () -> Void) {
        defer { tableView.blockEditAnimation.didFinishEdit() }
        // Merging into an empty block keeps its ID but moves the other block's text.
        // Slide that text from its old row instead of fading a duplicate there.
        let fadingIDs = contentMove.map { removingIDs.subtracting([$0.from]).union([$0.to]) }
            ?? removingIDs
        var snapshot = tableView.blockEditAnimation.prepare(
            in: tableView, removingIDs: fadingIDs, rowAt: animationRow(at:))
        if let move = contentMove, let position = snapshot?.positions[move.from] {
            snapshot?.positions[move.to] = position
        }
        updates()
        if let snapshot {
            tableView.blockEditAnimation.animate(
                in: tableView, from: snapshot, insertedID: insertedID,
                duration: duration, rowAt: animationRow(at:))
        }
    }

    private func animationRow(at index: Int) -> (id: UUID, x: CGFloat)? {
        guard rows.indices.contains(index) else { return nil }
        return (rows[index].block.id, rows[index].geometry.contentOrigin)
    }

    /// Full reload from the store, then re-attaches the shared editor to the
    /// given block (if still visible).
    private func reloadAndFocus(
        _ id: UUID?, selection: NSRange?, reuseStaticRenders: Bool = true,
        folding: Bool = false, indenting: Bool = false
    ) {
        tableView.blockEditAnimation.cancel()
        if !folding { tableView.cancelHeightAnimation() }
        let old = rows
        let previousFocus = focusedBlockID
        rebuildRows(reusingStaticRendersFrom: reuseStaticRenders ? old : nil)
        remapSelection(from: old)
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
        let reloadedIDs: Set<UUID>
        if reuseStaticRenders {
            reloadedIDs = applyRowChanges(from: old, folding: folding, indenting: indenting)
        } else {
            // Global style changes affect every row. Updating all their heights
            // in place makes AppKit prepare rows across the old and new frames.
            // A full reload discards that geometry and creates only visible cells.
            reloadedIDs = reloadAllRows()
        }
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
            // Keep the editor attached when only the outline structure changed.
            // Reattaching repeats highlighting and text layout before the slide.
            if !(folding || indenting) || previousFocus != newFocus || editor.window == nil
                || reloadedIDs.contains(newFocus)
                || (editSession?.current.id == newFocus && editSession?.current.text != editor.string) {
                attachEditor(to: newFocus, selection: selection, startSession: false)
            } else if indenting {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.focusedBlockID == newFocus else { return }
                    self.editor.revealCaret()
                }
            }
        } else {
            editor.removeFromSuperview()
        }
    }

    /// Applies the old→new `rows` difference with row-level table updates. A
    /// full `reloadData()` drops every materialized cell and re-creates (and
    /// re-lays-out) each visible one — the dominant cost of a structural edit
    /// on a large page, where a split/indent/move touches only a couple of
    /// rows. Unchanged rows keep their live cells untouched.
    private func applyRowChanges(from old: [Row], folding: Bool = false,
                                 indenting: Bool = false) -> Set<UUID> {
        guard tableView.numberOfRows == old.count else {
            return reloadAllRows()
        }
        let diff = rows.map(\.block.id).difference(from: old.map(\.block.id))
        // A wholesale change (an external reload re-mints every volatile id)
        // diffs into ~2n edits; a plain reload is cheaper.
        // Folding can hide most of a page. Keep the surviving cells in place.
        guard folding || diff.count <= max(8, rows.count / 2) else {
            return reloadAllRows()
        }
        if !diff.isEmpty {
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in diff {
                switch change {
                case .remove(let offset, _, _):
                    removed.insert(offset)
                case .insert(let offset, _, _):
                    inserted.insert(offset)
                }
            }
            let animate = folding && tableView.window != nil
                && app.preferences.animationsEnabled
            tableView.performRowUpdates(animated: animate) {
                tableView.beginUpdates()
                if !removed.isEmpty {
                    tableView.removeRows(at: removed,
                                         withAnimation: animate ? [.slideUp, .effectFade] : [])
                }
                if !inserted.isEmpty {
                    tableView.insertRows(at: inserted,
                                         withAnimation: animate ? [.slideDown, .effectFade] : [])
                }
                tableView.endUpdates()
            }
        }
        // Surviving rows whose visuals changed re-configure. The rendered
        // comparison is by identity: the render cache returns the same instance
        // for an unchanged block, and deliberately fresh instances for
        // re-rendered ones — including `{{query}}`/`{{embed}}` blocks, which are
        // never cached so their results stay live.
        var oldByID: [UUID: Row] = [:]
        for row in old { oldByID[row.block.id] = row }
        var changed: [Int] = []
        var reloaded: [Int] = []
        for (index, row) in rows.enumerated() {
            guard let prev = oldByID[row.block.id] else { continue } // freshly inserted
            let needsRenderReload = prev.rendered !== row.rendered
                && !(folding && row.block.id == focusedBlockID)
            if needsRenderReload
                || prev.depth != row.depth
                || prev.hasChildren != row.hasChildren
                || prev.marker != row.marker || prev.geometry != row.geometry {
                changed.append(index)
                let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                    as? OutlineRowCell
                if row.block.id == focusedBlockID, let cell,
                   OutlineRowCell.enclosing(editor) === cell {
                    // Typing leaves the static render stale. Refresh the row
                    // without replacing or re-highlighting its editor.
                    configure(cell, at: index)
                } else if indenting && !needsRenderReload {
                    cell?.updateMarker(row.marker, geometry: row.geometry, source: row.block.content)
                    cell?.updateStructure(
                        depth: row.depth, hasChildren: row.hasChildren && row.block.id != zoom,
                        collapsed: row.block.collapsed && row.block.id != zoom,
                        isEmptyLeaf: !row.block.isNumbered && Self.hidesBullet(
                            content: row.block.content, hasChildren: row.hasChildren,
                            isFocused: row.block.id == focusedBlockID, isOnlyRow: rows.count == 1))
                } else {
                    reloaded.append(index)
                }
            } else if prev.block.collapsed != row.block.collapsed {
                let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                    as? OutlineRowCell
                cell?.updateFoldState(collapsed: row.block.collapsed && row.block.id != zoom)
            }
        }
        if !changed.isEmpty {
            let previousHeights = changed.map { tableView.rect(ofRow: $0).height }
            if !reloaded.isEmpty {
                tableView.reloadData(
                    forRowIndexes: IndexSet(reloaded), columnIndexes: IndexSet(integer: 0))
            }
            let heightChanges = zip(changed, previousHeights).compactMap { index, previous in
                abs(previous - self.tableView(tableView, heightOfRow: index)) > 0.5
                    ? index : nil
            }
            noteHeightChanged(heightChanges)
        }
        return Set(reloaded.map { rows[$0].block.id })
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

    /// Re-renders tables and embeds when their available width changes.
    /// An embed can contain tables at any depth.
    private func rerenderWidthDependentRow(_ index: Int) -> Bool {
        let row = rows[index]
        let width = contentWidth(for: row)
        guard row.renderedWidth != width else { return false }
        guard BlockKind.classify(row.block.content).isTable
            || (row.block.content.contains("{{embed")
                && containsTable(row.rendered, in: NSRange(location: 0, length: row.rendered.length))) else { return false }
        let rendered = cachedRender(row.block, contentWidth: width)
        guard rendered !== row.rendered else { return false }
        rows[index].rendered = rendered
        rows[index].renderedWidth = width
        return row.block.id != focusedBlockID
    }

    private var widthNeedsMeasurement: Bool {
        measuredTableWidth.map { abs($0 - max(100, tableView.bounds.width)) > 0.5 } ?? true
    }

    func invalidateWidthMeasurement() {
        // Queue work even when SwiftUI returns to an already measured width.
        // AppKit may have replaced row heights during an intermediate probe.
        needsFullWidthRefresh = true
        scheduleWidthRefresh()
    }

    func refreshVisibleWidth() {
        guard needsFullWidthRefresh,
              measuredTableWidth == nil || !OutlineScrollAnchor.isLiveResizing(tableView),
              let scroll = tableView.enclosingScrollView,
              tableView.convert(scroll.contentView.bounds, from: scroll.contentView).intersects(tableView.bounds) else { return }
        // A newly exposed day can attach after the queued width pass. Give its
        // first frame correct heights. Established tables stay deferred.
        if measuredTableWidth == nil { refreshRowsForWidth() }
        else { scheduleWidthRefresh() }
    }

    private func widthDidChange() {
        guard needsFullWidthRefresh || widthNeedsMeasurement else { return }
        scheduleWidthRefresh()
    }

    private func scheduleWidthRefresh() {
        guard !widthRefreshScheduled else { return }
        widthRefreshScheduled = true
        // Defer row-height changes until SwiftUI has finished placing its views.
        // Invalidating intrinsic height from setFrameSize can keep the native
        // window resize in a loop that recreates journal days.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widthRefreshScheduled = false
            self.refreshRowsForWidth()
        }
    }

    private func refreshRowsForWidth() {
        guard tableView.window != nil else {
            needsFullWidthRefresh = true
            return
        }
        let viewport = tableView.enclosingScrollView.map {
            tableView.convert($0.contentView.bounds, from: $0.contentView)
        } ?? tableView.bounds
        let live = OutlineScrollAnchor.isLiveResizing(tableView)
        // Lazy journal days keep their old height until they become visible.
        // Other outlines finish measuring after the drag, before the next scroll.
        if !viewport.intersects(tableView.bounds), inJournalFeed || live {
            needsFullWidthRefresh = true
            return
        }
        measuredTableWidth = max(100, tableView.bounds.width)
        let count = min(rows.count, tableView.numberOfRows)
        needsFullWidthRefresh = live
        let first = needsFullWidthRefresh ? max(0, tableView.row(at: NSPoint(x: 0, y: viewport.minY))) : 0
        var remaining = needsFullWidthRefresh ? viewport.height * 1.5 : CGFloat.infinity
        var changedRenders = IndexSet()
        var changedHeights: [Int] = []
        // Use new heights to fill the viewport. Old heights underestimate how
        // many rows become visible when a narrow window is widened.
        for index in min(first, count)..<count {
            guard remaining > 0 else { break }
            if rerenderWidthDependentRow(index) { changedRenders.insert(index) }
            let old = tableView.rect(ofRow: index)
            let height = self.tableView(tableView, heightOfRow: index)
            if abs(old.height - height) > 0.5 { changedHeights.append(index) }
            let clipped = index == first ? max(0, viewport.minY - old.minY) : 0
            remaining -= max(OutlineRowCell.minRowHeight / 2, height - clipped)
        }
        // Only anchor an actual change. Newly attached days often already
        // have the right heights and must not interrupt normal scrolling.
        if !changedHeights.isEmpty || !changedRenders.isEmpty {
            OutlineScrollAnchor.preserve(beforeResizing: tableView, widthChanged: true)
        }
        // Keep the editor in its cell, including any marked text. Height
        // updates do not need to reset its content, focus, or scroll position.
        noteHeightChanged(changedHeights)
        if !changedRenders.isEmpty {
            tableView.reloadData(forRowIndexes: changedRenders,
                                 columnIndexes: IndexSet(integer: 0))
        }
        revealIfPossible()
    }

    func scrollAnchorBlock(at row: Int) -> UUID? {
        rows.indices.contains(row) ? rows[row].block.id : nil
    }

    func scrollAnchorRow(for blockID: UUID) -> Int? {
        rows.firstIndex { $0.block.id == blockID }
    }

    // MARK: - Focus and the shared editor

    func focusBlock(_ id: UUID, selection: NSRange?) {
        tableView.blockEditAnimation.cancel()
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
                                                    contentWidth: contentWidth(for: rows[prevIndex]))
            rows[prevIndex].renderedWidth = contentWidth(for: rows[prevIndex])
            reloadRow(prevIndex)
        }
    }

    private func attachEditor(to id: UUID, selection: NSRange?, startSession: Bool) {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return }
        let block = rows[index].block
        if editSession?.current.id != id {
            let state = OutlineEditorSnapshot(block: block, selection: selection ?? NSRange(location: 0, length: 0))
            editSession = EditSession(before: app.document(for: pageName), initial: state, current: state)
        }
        if startSession && focusedBlockID != id {
            editSession?.before = app.document(for: pageName)
            if let state = editSession?.current { editSession?.initial = state }
        }
        focusedBlockID = id
        endOtherEditing()
        // Undo/redo has to be able to close this typing run first (§13).
        app.closePendingEdit = { [weak self] in self?.closeEditSessionForUndo() }
        app.focusedOutline = self
        // A hint only on the sole block of an otherwise-empty page (SPEC §5.4);
        // set on every attach, so a reused editor never carries a stale one.
        editor.emptyHint = rows.count == 1 ? BlockRenderer.emptyBlockHint : nil
        // Edit the full source — content plus user `key:: value` lines (§3.2).
        editor.setContent(editSession?.current.text ?? block.editableSource)
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
        editSession = nil
        editor.removeFromSuperview()
        if tableView.window?.firstResponder === editor {
            tableView.window?.makeFirstResponder(tableView)
        }
        if let index = rows.firstIndex(where: { $0.block.id == id }) {
            rows[index].rendered = cachedRender(rows[index].block, contentWidth: contentWidth(for: rows[index]))
            rows[index].renderedWidth = contentWidth(for: rows[index])
            reloadRow(index)
        }
    }

    // MARK: - Node selection (SPEC §13)

    private var hasSelection: Bool { !selectedRows.isEmpty }

    private func remapSelection(from old: [Row]) {
        guard hasSelection else { return }
        let ids = Set(selectedRows.compactMap { old.indices.contains($0) ? old[$0].block.id : nil })
        let anchorID = selectionAnchor.flatMap { old.indices.contains($0) ? old[$0].block.id : nil }
        let activeID = selectionActive.flatMap { old.indices.contains($0) ? old[$0].block.id : nil }
        // Selection follows surviving blocks as their row indexes change.
        selectedRows = Set(rows.indices.filter { ids.contains(rows[$0].block.id) })
        selectionAnchor = rows.firstIndex { $0.block.id == anchorID } ?? selectedRows.min()
        selectionActive = rows.firstIndex { $0.block.id == activeID } ?? selectedRows.max()
        if selectedRows.isEmpty, Self.selectionOwner === self { Self.selectionOwner = nil }
    }

    private func setSelection(_ rows: Set<Int>, anchor: Int?, active: Int? = nil) {
        if rows.isEmpty {
            if Self.selectionOwner === self { Self.selectionOwner = nil }
        } else {
            // Establishing a selection here clears any other editor's.
            if let owner = Self.selectionOwner, owner !== self { owner.clearSelection() }
            Self.selectionOwner = self
        }
        let changed = selectedRows.symmetricDifference(rows)
        selectedRows = rows
        selectionAnchor = anchor
        selectionActive = active ?? anchor   // the moving end for Shift+↑/↓
        // Selection changes only the fill. Reloading here leaves pending height
        // queries that can read the new row indexes during a subsequent deletion.
        for index in changed where index >= 0 && index < tableView.numberOfRows {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                as? OutlineRowCell
            cell?.setBlockSelected(rows.contains(index))
        }
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
        case 49 where flags.isEmpty: // Space → Quick Look
            guard hasSelection else { return false }
            return quickLookSelection()
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
    func selectAllBlocks() -> Bool {
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
    func cutSelection(to pasteboard: NSPasteboard = .general) {
        // A zoom root survives the removal, so it stays off the clipboard too.
        guard let markdown = selectionMarkdown(includingZoomRoot: false) else { return }
        guard deleteSelection(labelledCut: true) else { return }
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    /// The selected blocks as Markdown, or nil when there is nothing to write.
    func selectionMarkdown(includingZoomRoot: Bool = true) -> String? {
        // Take exactly the selected rows (re-based to the shallowest one's
        // depth), not each block's whole subtree — selecting a parent plus one
        // child must not drag in the parent's *unselected* children. Exception:
        // a collapsed block's children are hidden and can't be selected, so its
        // full subtree is included.
        let doc = app.document(for: pageName)
        let liveByID = Dictionary(uniqueKeysWithValues: doc.blocks.flattened.map { ($0.id, $0) })
        let selected = selectedRows.sorted().filter {
            rows.indices.contains($0) && (includingZoomRoot || rows[$0].block.id != zoom)
        }
        guard let baseDepth = selected.map({ rows[$0].depth }).min() else { return nil }
        var forest: [Block] = []
        var stack: [(depth: Int, path: [Int])] = []
        for row in selected {
            guard var block = liveByID[rows[row].block.id] else { continue }
            let depth = max(0, rows[row].depth - baseDepth)
            if !block.collapsed || block.id == zoom { block.children = [] }
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            let parent = stack.last?.path ?? []
            let count = parent.isEmpty ? forest.count : forest.block(at: parent)!.children.count
            let path = parent + [count]
            forest.insert(block, at: path)
            stack.append((depth, path))
        }
        return forest.isEmpty ? nil : OutlineOps.copyMarkdown(forest)
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
        guard let insertAt = pastePath(after: rows[anchorRow].block.id, in: doc.blocks) else { return }
        for (i, block) in pasted.enumerated() {
            var p = insertAt
            p[p.count - 1] += i
            doc.blocks.insert(block, at: p)
        }
        guard commitStructural(doc, label: "Paste") else { return }
        clearSelection()
        reloadAndFocus(nil, selection: nil)
        let pastedIDs = Set(pasted.map(\.id))
        let newSel = Set(rows.indices.filter { pastedIDs.contains(rows[$0].block.id) })
        if let anchor = newSel.min() { setSelection(newSel, anchor: anchor) }
    }

    /// Where blocks pasted after `id` go: right after it and its subtree. After a
    /// zoom root that would be outside the view, so they become its first children.
    private func pastePath(after id: UUID, in blocks: [Block]) -> [Int]? {
        guard var path = blocks.path(to: id) else { return nil }
        if id == zoom { return path + [0] }
        path[path.count - 1] += 1
        return path
    }

    /// Removes the selected blocks. Returns false when there was nothing to remove
    /// or the reference prompt was declined, so `cutSelection` can leave the
    /// pasteboard alone.
    @discardableResult
    func deleteSelection(labelledCut: Bool = false) -> Bool {
        // A zoom root stays: removing it would empty the view. Its selected
        // children are removed as usual.
        let ids = selectedRows.sorted()
            .compactMap { rows.indices.contains($0) ? rows[$0].block.id : nil }
            .filter { $0 != zoom }
        guard !ids.isEmpty else { return false }
        // Aggregate incoming block-references over every selected subtree (§7.4).
        var subtreeIDs: [UUID] = []
        let doc0 = app.document(for: pageName)
        for id in ids {
            guard let block = doc0.blocks.block(id: id) else { continue }
            subtreeIDs.append(contentsOf: [id] + block.children.flattened.map(\.id))
        }
        let count = (try? app.store.cache.incomingRefCount(forBlockIDs: subtreeIDs)) ?? 0
        if count > 0, !Self.confirmDeleteReferenced(blocks: ids.count, places: count) {
            return false
        }
        var doc = app.document(for: pageName)
        Self.removeBlocks(Set(ids), from: &doc.blocks)
        if doc.blocks.isEmpty { doc.blocks = [Block(content: "")] } // keep one block
        guard commitStructural(doc, label: Self.removalLabel(count: ids.count, isCut: labelledCut))
        else { return false }
        animateStructuralEdit(removingIDs: Set(subtreeIDs)) {
            clearSelection()
            reloadAndFocus(nil, selection: nil)
        }
        return true
    }

    /// Confirms deleting referenced blocks (SPEC §7.4). One key for both call
    /// sites, plural on the subject *and* the place count.
    private static func confirmDeleteReferenced(blocks: Int, places: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "\(blocks) blocks are referenced in \(places) places. Delete anyway?",
            comment: "Delete-block confirmation; both counts are pluralized"
        )
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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
        guard commitStructural(doc, label: outdent ? "Outdent" : "Indent") else { return }
        animateStructuralEdit(duration: BlockEditAnimation.indentationDuration) {
            reloadAndFocus(nil, selection: nil, indenting: true)
        }
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
        guard commitStructural(doc, label: ids.count == 1 ? "Move Block" : "Move Blocks") else { return }
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

    static func assetFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? NSURL).map { $0 as URL } }
            .filter(GraphStore.isPreviewAssetFile) ?? []
        return urls.isEmpty ? nil : urls
    }

    // MARK: - Commits

    /// Records a structural op as its own undo step. Any keystrokes typed since
    /// the block was focused are first flushed into a *separate* undo step, so
    /// undoing the op reverts only the op — not the typing that preceded it
    /// (each Cmd+Z undoes one action, SPEC §13).
    /// Returns false, and commits nothing, for an edit that would leave a
    /// zoomed view's subtree (see `OutlineOps.keepsZoomScope`).
    @discardableResult
    private func commitStructural(_ doc: PageDocument, label: String,
                                  focusAfter: UUID? = nil, selectionAfter: NSRange? = nil) -> Bool {
        let before = app.document(for: pageName)
        if let zoom, !OutlineOps.keepsZoomScope(before: before.blocks, after: doc.blocks, root: zoom) {
            NSSound.beep()
            return false
        }
        flushEditSessionUndo()
        let beforeState = currentOutlineEditorSnapshot()
        var afterState = beforeState
        if let id = focusAfter ?? focusedBlockID, let block = doc.blocks.block(id: id) {
            let previous = before.blocks.block(id: id)
            if id != beforeState?.id || block.content != previous?.content
                || block.properties != previous?.properties {
                afterState = OutlineEditorSnapshot(block: block,
                    selection: selectionAfter ?? editor.selectedRange())
            }
            if let selectionAfter { afterState?.selection = selectionAfter }
        }
        app.commit(doc, undoLabel: label, before: app.document(for: pageName),
                   editor: undoEditing(before: beforeState, after: afterState))
        editSession = afterState.map { EditSession(before: doc, initial: $0, current: $0) }
        return true
    }

    /// Records pending typing before global undo restores the document and editor.
    private func closeEditSessionForUndo() {
        flushEditSessionUndo()
    }

    private func flushEditSessionUndo() {
        guard let session = editSession, let state = currentOutlineEditorSnapshot() else { return }
        let before = session.before
        let id = state.id
        let current = app.document(for: pageName)
        guard let b = before.blocks.block(id: id), let c = current.blocks.block(id: id) else {
            return
        }
        if b.content != c.content || b.properties != c.properties
            || state.text != session.initial.text {
            app.commit(current, undoLabel: "Edit Block", before: before,
                       editor: undoEditing(before: session.initial, after: state), numberingChanged: false)
        }
        editSession?.before = current
        editSession?.initial = state
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
            tagPreview: { [weak self] tag in
                self?.previewAttributedString(forTag: tag)
            },
            beginDrag: { [weak self] event, view in
                self?.beginDragSession(for: id, event: event, from: view)
            },
            resizeImage: { [weak self] imageIndex, width in
                self?.resizeImage(id, imageIndex: imageIndex, width: width)
            },
            animationsEnabled: { [preferences = app.preferences] in preferences.animationsEnabled }
        )
    }

    private func toggleFold(_ id: UUID) {
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        if let focusedBlockID, let focusedPath = doc.blocks.path(to: focusedBlockID),
           focusedPath.count > path.count, focusedPath.starts(with: path) {
            // Show rendered text while the edited child slides out.
            endEditing()
        }
        doc.blocks.update(at: path) { $0.collapsed.toggle() }
        app.commit(doc)
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil
            ? editor.selectedRange() : nil, folding: true)
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
    /// No page title: the pointer is on the link that names it. A page with
    /// nothing to show gets the chip its title carries, so the popover is never
    /// blank.
    func previewAttributedString(forPage name: String) -> NSAttributedString? {
        let doc = app.document(for: name)
        let out = NSMutableAttributedString()
        let source = SourceNumbering(app: app, page: name)
        var parentContent: [Int: CGFloat] = [:]
        for row in OutlineOps.visibleRows(in: doc.blocks).prefix(10) {
            let origin = row.depth == 0 ? 0 : (parentContent[row.depth - 1] ?? 0)
                + OutlineRowCell.indentPerDepth - OutlineMarkerLayout.generatedGutter
            let prefix = sourceMarkerPrefix(source.markers[row.id], slot: source.widths[row.id] ?? 0, origin: origin)
            parentContent[row.depth] = prefix.hang
            guard !row.block.content.isEmpty || row.block.isNumbered else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            let start = out.length
            out.append(prefix.text)
            out.append(renderForPreview(row.block.content))
            applySourceMarkerLayout(out, range: NSRange(location: start, length: out.length - start), prefix: prefix)
        }
        if out.length == 0 {
            out.append(Self.pill(doc.fileExists
                ? String(localized: "empty", comment: "Hover preview of a page with no content")
                : L("stub")))
        }
        // A preview is a non-interactive glance — drop link styling so refs/embeds
        // don't show as blue underlined links (and no `knopo://` tooltips).
        out.removeAttribute(.link, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A tag's blocks come from any page, so each line names its own.
    func previewAttributedString(forTag tag: String) -> NSAttributedString? {
        let hits = (try? app.store.cache.blocks(taggedWith: tag))?.prefix(10) ?? []
        let out = NSMutableAttributedString()
        var sources: [String: SourceNumbering] = [:]
        for hit in hits {
            if sources[hit.pageDisplayName] == nil {
                sources[hit.pageDisplayName] = SourceNumbering(app: app, page: hit.pageDisplayName)
            }
            let source = sources[hit.pageDisplayName]!
            let marker = source.markers[hit.blockID]
            if hit.content.isEmpty && marker == nil { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: "\(app.displayTitle(for: hit.pageDisplayName))  ",
                                          attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            if let marker {
                out.append(NSAttributedString(string: marker.label + " ", attributes: [
                    .font: OutlineMarkerLayout.font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            out.append(renderForPreview(hit.content))
        }
        if out.length == 0 { out.append(Self.pill(L("empty"))) }
        out.removeAttribute(.link, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The chip `PageScreen` puts beside a page with no file. Drawn as an image
    /// so it can sit in a text view.
    private static func pill(_ text: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = text as NSString
        let pad = NSSize(width: 9, height: 4)
        let size = text.size(withAttributes: attrs)
        let box = NSSize(width: ceil(size.width) + pad.width * 2,
                         height: ceil(size.height) + pad.height * 2)
        let image = NSImage(size: box, flipped: false) { rect in
            NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                         yRadius: rect.height / 2).fill()
            text.draw(at: NSPoint(x: pad.width, y: pad.height), withAttributes: attrs)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        return NSAttributedString(attachment: attachment)
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
            let copy = NSMenuItem(title: String(localized: "Copy \(selectedRows.count) Blocks",
                                               comment: "Block context menu, multi-selection"),
                                  action: #selector(copySelectionAction), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            let numbered = NSMenuItem(title: L("Numbered List"),
                                      action: #selector(toggleNumberedList(_:)), keyEquivalent: "")
            numbered.target = self
            numbered.representedObject = id
            numbered.state = numberingIsEnabled(on: numberingTargets(for: id)) ? .on : .off
            menu.addItem(numbered)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: String(localized: "Delete \(selectedRows.count) Blocks",
                                                 comment: "Block context menu, multi-selection"),
                                    action: #selector(deleteSelectionAction), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        let menu = NSMenu()
        if let rendered = view as? RenderedTextView,
           let file = rendered.imageFile(at: rendered.convert(event.locationInWindow, from: nil)) {
            addImageFileItems(file, to: menu)
            menu.addItem(.separator())
        }
        let copyRef = NSMenuItem(
            title: L("Copy Block Reference"), action: #selector(copyBlockRef(_:)), keyEquivalent: ""
        )
        copyRef.target = self
        copyRef.representedObject = id
        menu.addItem(copyRef)
        let copyMarkdown = NSMenuItem(
            title: L("Copy Subtree as Markdown"),
            action: #selector(copySubtreeMarkdown(_:)), keyEquivalent: ""
        )
        copyMarkdown.target = self
        copyMarkdown.representedObject = id
        menu.addItem(copyMarkdown)

        menu.addItem(.separator())
        contextMenuBlockID = id
        let numbered = NSMenuItem(title: L("Numbered List"),
                                  action: #selector(toggleNumberedList(_:)), keyEquivalent: "")
        numbered.target = self
        numbered.representedObject = id
        numbered.state = numberingIsEnabled(on: numberingTargets(for: id)) ? .on : .off
        menu.addItem(numbered)
        let colorItem = NSMenuItem(title: L("Background Color"), action: nil, keyEquivalent: "")
        colorItem.submenu = backgroundColorMenu(for: id)
        menu.addItem(colorItem)

        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: L("Delete Block"), action: #selector(deleteBlockAction(_:)), keyEquivalent: ""
        )
        delete.target = self
        delete.representedObject = id
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func numberingTargets(for id: UUID) -> [UUID] {
        if hasSelection, selectedRows.contains(where: { rows[$0].block.id == id }) {
            return topMostSelectedRows().map { rows[$0].block.id }
        }
        return [id]
    }

    private func numberingIsEnabled(on ids: [UUID]) -> Bool {
        let selected = Set(ids)
        let doc = app.document(for: pageName)
        let targets = doc.blocks.flattened.filter { selected.contains($0.id) }
        return !targets.isEmpty && targets.allSatisfy(\.isNumbered)
    }

    @objc private func toggleNumberedList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        setNumbering(on: numberingTargets(for: id))
    }

    /// Applies only to the selected roots. Their children keep their own format.
    func setNumbering(on ids: [UUID]) {
        var doc = app.document(for: pageName)
        var selected = Set(ids)
        let targets = doc.blocks.flattened.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        let enabled = !targets.allSatisfy(\.isNumbered)
        func apply(_ blocks: inout [Block]) {
            for index in blocks.indices {
                if selected.remove(blocks[index].id) != nil { blocks[index].setNumbered(enabled) }
                if selected.isEmpty { return }
                apply(&blocks[index].children)
            }
        }
        apply(&doc.blocks)
        let selection = focusedBlockID == nil ? nil : editor.selectedRange()
        guard commitStructural(doc, label: "Numbered List") else { return }
        animateStructuralEdit(duration: BlockEditAnimation.indentationDuration) {
            reloadAndFocus(focusedBlockID, selection: selection, indenting: true)
        }
    }

    private func enableNumbering(removing range: NSRange) {
        guard let id = focusedBlockID, range.location >= 0,
              NSMaxRange(range) <= editor.string.utf16.count else { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        let text = (editor.string as NSString).replacingCharacters(in: range, with: "")
        doc.blocks.update(at: path) {
            $0.setEditableSource(text, numberingSnapshot: editSession?.current.numberingSnapshot)
            $0.setNumbered(true)
        }
        let selection = NSRange(location: range.location, length: 0)
        guard commitStructural(doc, label: "Numbered List", selectionAfter: selection) else { return }
        reloadAndFocus(id, selection: selection)
    }

    func editorNumberedShortcut() {
        guard let id = focusedBlockID,
              app.document(for: pageName).blocks.block(id: id)?.isNumbered == false else { return }
        enableNumbering(removing: NSRange(location: 0, length: 3))
    }

    private func clearFocusedNumbering() -> Bool {
        guard let id = focusedBlockID,
              app.document(for: pageName).blocks.block(id: id)?.isNumbered == true else { return false }
        setNumbering(on: [id])
        return true
    }

    /// The color palette submenu (Logseq-style). A checkmark marks the block's
    /// current color; "None" clears it.
    private func backgroundColorMenu(for id: UUID) -> NSMenu {
        let current = app.document(for: pageName).blocks.block(id: id)?
            .properties.first { $0.key == BlockColor.propertyKey }?.value
        let submenu = NSMenu()
        let none = NSMenuItem(
            title: String(localized: "None", comment: "Background-color submenu: clears the color"),
            action: #selector(setBlockColor(_:)), keyEquivalent: ""
        )
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
        guard commitStructural(doc, label: "Background Color") else { return }
        reloadAndFocus(focusedBlockID, selection: focusedBlockID != nil ? editor.selectedRange() : nil)
    }

    @objc private func copySelectionAction() { copySelection() }
    @objc private func deleteSelectionAction() { deleteSelection() }

    /// Items for the file behind a right-clicked image or PDF. A click on it
    /// edits the block, so the menu is the way to see the file itself.
    func addImageFileItems(_ file: URL, to menu: NSMenu) {
        let items: [(String, Selector)] = [
            (L("Quick Look"), #selector(quickLookFile(_:))),
            (L("Open in Default App"), #selector(openFileInDefaultApp(_:))),
            (L("Reveal in Finder"), #selector(revealFileInFinder(_:))),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = file
            menu.addItem(item)
        }
    }

    @objc private func quickLookFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        QuickLook.show([file], from: tableView.window)
    }

    /// Opens or closes Quick Look. Tests replace it: no panel opens under `swift test`.
    var toggleQuickLook: ([URL], NSWindow?) -> Void = { QuickLook.toggle($0, from: $1) }

    /// Space on selected blocks, as in Finder. Unhandled when there is nothing to preview.
    private func quickLookSelection() -> Bool {
        let files = Self.previewFiles(in: selectedRows.sorted().compactMap {
            rows.indices.contains($0) ? rows[$0].rendered : nil
        })
        guard !files.isEmpty else { return false }
        toggleQuickLook(files, tableView.window)
        return true
    }

    /// Image and PDF files in rendered blocks, in order, each once. Taken from
    /// the render, so only existing files count. Embedded images are skipped.
    static func previewFiles(in rendered: [NSAttributedString]) -> [URL] {
        var files: [URL] = []
        for text in rendered {
            // By index, which is unique per image. Adjacent copies of one file
            // share a file-attribute run.
            text.enumerateAttribute(
                BlockRenderer.imageIndexKey, in: NSRange(location: 0, length: text.length)
            ) { value, range, _ in
                guard value != nil,
                      text.attribute(.embedRegion, at: range.location, effectiveRange: nil) == nil,
                      let file = text.attribute(
                        BlockRenderer.imageFileKey, at: range.location, effectiveRange: nil) as? URL,
                      !files.contains(file) else { return }
                files.append(file)
            }
        }
        return files
    }

    @objc private func openFileInDefaultApp(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(file)
    }

    @objc private func revealFileInFinder(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
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
        if count > 0, !Self.confirmDeleteReferenced(blocks: 1, places: count) { return }
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id) else { return }
        let wasFocused = focusedBlockID == id
        let previousID = index > 0 ? rows[index - 1].block.id : nil
        _ = OutlineOps.delete(path, in: &doc.blocks)
        let focus = wasFocused ? previousID : focusedBlockID
        let caret = focus.flatMap { doc.blocks.block(id: $0)?.content.utf16.count } ?? 0
        let selection = wasFocused ? NSRange(location: caret, length: 0) : editor.selectedRange()
        guard commitStructural(doc, label: "Delete Block", focusAfter: focus,
                               selectionAfter: selection) else { return }
        animateStructuralEdit(removingIDs: Set(subtreeIDs)) {
            reloadAndFocus(wasFocused ? nil : focusedBlockID, selection: nil)
            if wasFocused, let previousID,
               let prev = app.document(for: pageName).blocks.block(id: previousID) {
                let end = (prev.content as NSString).length
                attachEditor(to: previousID, selection: NSRange(location: end, length: 0),
                             startSession: false)
            }
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

    func findSetCurrent(_ localIndex: Int?, reveal: Bool) {
        findCurrentLocal = localIndex
        let newCurrentRow = localIndex.flatMap {
            findMatches.indices.contains($0) ? findMatches[$0].row : nil
        }
        // Re-render only the old and new current rows (the emphasized match), not
        // the whole table.
        reloadFindRows(Set([findCurrentRow, newCurrentRow].compactMap { $0 }))
        findCurrentRow = newCurrentRow
        if reveal, let newCurrentRow {
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

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        self.tableView.blockEditAnimation.remove(rowView: rowView)
    }

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
        configure(cell, at: row)
        return cell
    }

    private func configure(_ cell: OutlineRowCell, at row: Int) {
        let model = rows[row]
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
        let isEmptyLeaf = !model.block.isNumbered && Self.hidesBullet(
            content: model.block.content, hasChildren: model.hasChildren,
            isFocused: model.block.id == focusedBlockID, isOnlyRow: rows.count == 1)
        // `background-color:: <name>` tints the block as a soft colored box (SPEC §5.6).
        let blockColor = model.block.properties
            .first { $0.key == BlockColor.propertyKey }
            .flatMap { BlockColor(rawValue: $0.value) }?.background
        // A zoom root always shows its children, so it has nothing to fold.
        let isZoomRoot = model.block.id == zoom
        cell.configure(
            depth: model.depth,
            hasChildren: model.hasChildren && !isZoomRoot,
            collapsed: model.block.collapsed && !isZoomRoot,
            isQuote: isQuote,
            isCode: isCode,
            isEmbed: isEmbed,
            isEmptyLeaf: isEmptyLeaf,
            selected: selectedRows.contains(row),
            lineHeight: BlockRenderer.lineHeight(forSource: model.block.content),
            blockColor: blockColor,
            callbacks: rowCallbacks(for: model.block.id)
        )
        cell.updateMarker(model.marker, geometry: model.geometry, source: model.block.content)
        if model.block.id == focusedBlockID {
            cell.embedEditor(editor)
        } else {
            cell.showRendered(findHighlighted(row: row) ?? model.rendered)
            // A pure-embed block hands its bullet to the transcluded subtree.
            if isPureEmbed && !model.block.isNumbered { cell.setBulletHidden(true) }
        }
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
        let contentWidth = contentWidth(for: model)
        if model.block.id == focusedBlockID {
            // Focused rows show the full editable source (content + property
            // lines); measure that with the editor's own TextKit 2 layout.
            let textHeight = BlockEditorTextView.measureHeight(
                for: editSession?.current.id == model.block.id ? (editSession?.current.text ?? model.block.editableSource)
                    : model.block.editableSource, width: contentWidth
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
        guard Self.assetFileURLs(from: info.draggingPasteboard) != nil,
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
            guard let fileURLs = Self.assetFileURLs(from: info.draggingPasteboard) else { return false }
            return importDroppedAssets(fileURLs, row: row, operation: operation)
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
        guard commitStructural(doc, label: movedIDs.count == 1 ? "Move Block" : "Move Blocks") else {
            return false
        }
        clearSelection()
        reloadAndFocus(nil, selection: nil)
        let newSelection = Set(rows.indices.filter { movedIDs.contains(rows[$0].block.id) })
        if !newSelection.isEmpty { setSelection(newSelection, anchor: newSelection.min()) }
        return true
    }

    func importDroppedAssets(_ fileURLs: [URL], row: Int,
                             operation: NSTableView.DropOperation) -> Bool {
        var doc = app.document(for: pageName)
        guard let dest = insertionPath(row: row, operation: operation, in: doc) else {
            return false
        }
        let blocks = importAssetMarkdown(fileURLs.filter(GraphStore.isPreviewAssetFile))
            .map { Block(content: $0) }
        guard !blocks.isEmpty else { return false }
        for (offset, block) in blocks.enumerated() {
            var path = dest
            path[path.count - 1] += offset
            doc.blocks.insert(block, at: path)
        }
        // Expand the parent so the imported blocks are visible.
        if operation == .on, rows.indices.contains(row),
           let parentPath = doc.blocks.path(to: rows[row].block.id) {
            doc.blocks.update(at: parentPath) { $0.collapsed = false }
        }
        guard commitStructural(doc, label: blocks.count == 1 ? "Insert File" : "Insert Files")
        else { return false }
        clearSelection()
        reloadAndFocus(nil, selection: nil)
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
        let wasNumbered = rows[index].block.isNumbered
        let snapshot = editSession?.current.numberingSnapshot ?? rows[index].block.numberingProperties
        doc.blocks.update(at: path) { $0.setEditableSource(text, numberingSnapshot: snapshot) }
        editSession?.current.text = text
        editSession?.current.selection = editor.selectedRange()
        app.commit(doc, numberingChanged: wasNumbered != doc.blocks.block(at: path)?.isNumbered)
        rows[index].block = doc.blocks.block(at: path) ?? rows[index].block
        if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? OutlineRowCell {
            cell.updateMarker(rows[index].marker, geometry: rows[index].geometry, source: rows[index].block.content)
        }
        if wasNumbered != rows[index].block.isNumbered {
            reloadAndFocus(id, selection: editor.selectedRange(), indenting: true)
        }
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
        if block.isNumbered, block.children.isEmpty, editor.string.isEmpty {
            let parentPath = Array(path.dropLast())
            let parentNumbered = doc.blocks.block(at: parentPath)?.isNumbered == true
            if parentNumbered, id != zoom, doc.blocks.block(at: parentPath)?.id != zoom {
                _ = OutlineOps.outdent(path, in: &doc.blocks)
            } else {
                doc.blocks.update(at: path) { $0.setNumbered(false) }
            }
            guard commitStructural(doc, label: "Numbered List") else { return }
            reloadAndFocus(id, selection: NSRange(location: 0, length: 0))
            return
        }
        // The editor shows the full source (content + property lines). Splitting
        // only ever divides the *content*; clamp the caret into the content
        // region so properties always stay with the original block — Enter in
        // the property area just makes a new empty block below.
        let contentUTF16 = (block.content as NSString).length
        let caret = min(max(offset, 0), contentUTF16)
        let characterOffset = Self.characterOffset(forUTF16Offset: caret, in: block.content)
        // The zoom root's new block goes inside it, so it stays in view.
        let split = id == zoom ? OutlineOps.splitZoomRoot : OutlineOps.split
        guard let newID = split(path, characterOffset, &doc.blocks) else {
            return
        }
        guard commitStructural(doc, label: "New Block", focusAfter: newID,
                               selectionAfter: NSRange(location: 0, length: 0)) else { return }
        // Enter at the start inserts above and keeps focus on the original block.
        let insertedID = newID == id ? doc.blocks.block(at: path)?.id : newID
        animateStructuralEdit(insertedID: insertedID) {
            reloadAndFocus(newID, selection: NSRange(location: 0, length: 0))
        }
    }

    func editorIndent() {
        structuralOnFocused(label: "Indent", indenting: true) {
            OutlineOps.indent($0, in: &$1)
        }
    }

    func editorOutdent() {
        structuralOnFocused(label: "Outdent", indenting: true) {
            OutlineOps.outdent($0, in: &$1)
        }
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
        guard commitStructural(doc, label: "Toggle Todo", selectionAfter: NSRange(location: caret, length: 0)) else { return }
        reloadAndFocus(id, selection: NSRange(location: caret, length: 0))
    }

    private func structuralOnFocused(label: String, indenting: Bool = false,
                                     _ op: ([Int], inout [Block]) -> Bool) {
        guard let id = focusedBlockID else { return }
        let selection = editor.selectedRange()
        var doc = app.document(for: pageName)
        guard let path = doc.blocks.path(to: id), op(path, &doc.blocks) else { return }
        guard commitStructural(doc, label: label) else { return }
        if indenting {
            animateStructuralEdit(duration: BlockEditAnimation.indentationDuration) {
                reloadAndFocus(id, selection: selection, indenting: true)
            }
        } else {
            reloadAndFocus(id, selection: selection)
        }
    }

    func editorDeleteEmptyBlock() {
        if clearFocusedNumbering() { return }
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }),
              !rows[index].hasChildren else { return }
        guard rows.count > 1 else { return } // keep the page's last block
        deleteBlock(id)
    }

    func editorMergeWithPrevious() {
        if clearFocusedNumbering() { return }
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
        let content = doc.blocks.block(id: receiver)?.content ?? ""
        let caret = Self.utf16Offset(forCharacterOffset: characterOffset, in: content)
        guard commitStructural(doc, label: "Merge Blocks", focusAfter: receiver,
                               selectionAfter: NSRange(location: caret, length: 0)) else { return }
        let contentMove = rows[index - 1].block.editableSource.isEmpty
            ? (from: id, to: receiver) : nil
        animateStructuralEdit(removingIDs: [id], contentMove: contentMove) {
            reloadAndFocus(receiver, selection: NSRange(location: caret, length: 0))
        }
    }

    func editorMergeWithNext() {
        guard let id = focusedBlockID,
              let index = rows.firstIndex(where: { $0.block.id == id }),
              index + 1 < rows.count else { return }
        let next = rows[index + 1]
        // Symmetric with backward merge: can't pull up a block that has children,
        // and won't silently drop a block's properties (merge only moves content).
        guard !next.hasChildren, next.block.properties.allSatisfy({ Block.numberingPropertyKeys.contains($0.key) }) else { return }
        let caretOffset = (rows[index].block.content as NSString).length
        var doc = app.document(for: pageName)
        // Merging the next block "into its previous" (= this block) is exactly a
        // forward delete: its content appends here and the caret stays at the join.
        guard let nextPath = doc.blocks.path(to: next.block.id),
              OutlineOps.mergeWithPrevious(nextPath, in: &doc.blocks) != nil else { return }
        guard commitStructural(doc, label: "Merge Blocks", focusAfter: id,
                               selectionAfter: NSRange(location: caretOffset, length: 0)) else { return }
        let contentMove = rows[index].block.editableSource.isEmpty
            ? (from: next.block.id, to: id) : nil
        animateStructuralEdit(removingIDs: [next.block.id], contentMove: contentMove) {
            reloadAndFocus(id, selection: NSRange(location: caretOffset, length: 0))
        }
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
        guard let path = doc.blocks.path(to: id) else { return }
        guard let focus = OutlineOps.paste(text, at: path, focusedSourceIsEmpty: editor.string.isEmpty,
                                           zoomRoot: zoom, in: &doc.blocks) else { return }
        let caret = (doc.blocks.block(id: focus)?.content ?? "").utf16.count
        guard commitStructural(doc, label: "Paste", focusAfter: focus,
                               selectionAfter: NSRange(location: caret, length: 0)) else { return }
        reloadAndFocus(focus, selection: NSRange(location: caret, length: 0))
    }

    func editorPersistPastedBlockReference(_ id: UUID) {
        guard let target = app.store.resolveBlock(id), !target.block.idPersisted else { return }
        try? app.persistBlockID(id, inPageNamed: target.pageName)
        app.dataVersion += 1
    }

    func editorImportAssets(_ fileURLs: [URL]) -> String? {
        let markdown = importAssetMarkdown(fileURLs.filter(GraphStore.isPreviewAssetFile))
        return markdown.isEmpty ? nil : markdown.joined(separator: " ")
    }

    private func importAssetMarkdown(_ fileURLs: [URL]) -> [String] {
        var failures: [String] = []
        let markdown = fileURLs.compactMap { url -> String? in
            do {
                let name = try app.store.importAsset(from: url)
                return GraphStore.imageMarkdown(assetNamed: name)
            } catch {
                let reason = NSAlert(for: error).messageText
                if reason.contains(url.lastPathComponent) {
                    failures.append(reason)
                } else {
                    failures.append(String(localized: "\(url.lastPathComponent): \(reason)",
                                           comment: "Failed asset import; filename followed by the error description"))
                }
                return nil
            }
        }
        showAssetImportFailures(failures)
        return markdown
    }

    private func showAssetImportFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some files could not be imported.",
                                   comment: "Alert title after failed image or PDF imports")
        alert.informativeText = failures.joined(separator: "\n\n")
        alert.addButton(withTitle: L("OK"))
        presentAssetImportAlert(alert)
    }

    func editorImportPastedImage(png data: Data) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let preferredName = "pasted-\(formatter.string(from: Date())).png"
        do {
            let name = try app.store.saveAsset(data, preferredName: preferredName)
            return GraphStore.imageMarkdown(assetNamed: name, alt: "image")
        } catch {
            showAssetImportFailures([NSAlert(for: error).messageText])
            return nil
        }
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
