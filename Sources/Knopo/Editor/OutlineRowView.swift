import AppKit
import KnopoCore

/// Per-row callbacks supplied by the outline controller (captured by block id,
/// so they stay valid across row-index shifts).
struct OutlineRowCallbacks {
    var toggleFold: () -> Void = {}
    var zoomIn: () -> Void = {}
    var showContextMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// (url, openInRightSidebar)
    var openLink: (URL, Bool) -> Void = { _, _ in }
    /// UTF-16 index of the click in the *rendered* text; focuses the block.
    var focusContent: (Int) -> Void = { _ in }
    /// Shift/Cmd+click for node selection (extend / toggle), without editing.
    var selectBlock: (_ extend: Bool, _ toggle: Bool) -> Void = { _, _ in }
    /// Renders a page's first ~10 blocks for the hover preview (SPEC §6.1).
    var pagePreview: (String) -> NSAttributedString? = { _ in nil }
    /// Bullet drag: starts a block-move drag session (event, source view).
    var beginDrag: (NSEvent, NSView) -> Void = { _, _ in }
    /// Resizes the n-th image token in this block to the given display width.
    var resizeImage: (_ imageIndex: Int, _ width: CGFloat) -> Void = { _, _ in }
}

/// One outline row (SPEC §5.4): indentation by depth, fold triangle, bullet
/// (click = zoom), and content — either the shared raw-source editor (focused)
/// or rendered Markdown (unfocused).
final class OutlineRowCell: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("OutlineRowCell")
    static let indentPerDepth: CGFloat = 22
    /// Space before a block's text, holding the fold chevron and bullet. Scales
    /// with zoom so the bullet-to-text gap grows with the text size.
    static var gutterWidth: CGFloat { (34 * BlockRenderer.zoom).rounded() }
    static let trailingPad: CGFloat = 6
    /// Row top/bottom padding — the gap *between* blocks. Scales with the
    /// text-density control (View menu); 2 at 100%. The swing around that default
    /// is amplified (slope 2.4 instead of 2) so block separation responds more
    /// strongly to the control than the raw multiplier would.
    static var verticalPadding: CGFloat { max(0, 2 + 2.4 * (BlockRenderer.density - 1)) }
    /// Vertical text inset inside the content container — identical for the
    /// rendered view and the shared editor so focusing a block never changes
    /// its row height (bullets/lines must not shift).
    static let contentInsetV: CGFloat = 4
    static let minRowHeight: CGFloat = 24

    private let foldButton = NSButton(frame: .zero)
    private let bullet = BulletView(frame: .zero)
    private let container = NSView(frame: .zero)
    private let renderedView = RenderedTextView.create()
    private let quoteBar = QuoteBarView(frame: .zero)
    private let codeBackground = CodeBackgroundView(frame: .zero)
    private let embedBackground = EmbedBackgroundView(frame: .zero)
    private let colorBackground = ColorBoxView(frame: .zero)  // background-color:: box
    private var blockColor: NSColor?
    private var depth = 0
    private var isQuote = false
    private var isCode = false
    private var isEmbed = false
    /// First line's pinned height, so the bullet/fold center against it.
    private var firstLineHeight: CGFloat = 17
    private var isSelectedBlock = false
    private var previewPopover: NSPopover?
    /// The fold chevron only appears while the pointer is over the row (like
    /// Logseq) — otherwise it's visual noise. These track the two inputs.
    private var rowHasChildren = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    var callbacks = OutlineRowCallbacks()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        foldButton.isBordered = false
        foldButton.imagePosition = .imageOnly
        foldButton.target = self
        foldButton.action = #selector(foldClicked)
        addSubview(foldButton)

        bullet.onClick = { [weak self] in self?.callbacks.zoomIn() }
        bullet.onContextMenu = { [weak self] event in
            guard let self else { return }
            self.callbacks.showContextMenu(event, self.bullet)
        }
        bullet.onBeginDrag = { [weak self] event in
            guard let self else { return }
            self.callbacks.beginDrag(event, self.bullet)
        }
        addSubview(bullet)

        renderedView.onLinkClick = { [weak self] url, inSidebar in
            self?.callbacks.openLink(url, inSidebar)
        }
        renderedView.onFocusRequest = { [weak self] index in
            self?.callbacks.focusContent(index)
        }
        renderedView.onHoverPageLink = { [weak self] name, rect in
            self?.showPreview(forPage: name, near: rect)
        }
        renderedView.onHoverEnded = { [weak self] in self?.closePreview() }
        renderedView.onImageResize = { [weak self] index, width in
            self?.callbacks.resizeImage(index, width)
        }
        // Backgrounds sit behind the text so a code/embed block reads as one
        // filled box (full content width, no per-line gaps). The color box is
        // furthest back so it tints the whole block (incl. when focused/editing).
        colorBackground.isHidden = true
        container.addSubview(colorBackground)
        embedBackground.isHidden = true
        container.addSubview(embedBackground)
        codeBackground.isHidden = true
        container.addSubview(codeBackground)
        container.addSubview(renderedView)
        quoteBar.isHidden = true
        container.addSubview(quoteBar)
        addSubview(container)
    }

    // MARK: - Configuration

    func configure(depth: Int, hasChildren: Bool, collapsed: Bool,
                   isQuote: Bool, isCode: Bool, isEmbed: Bool, isEmptyLeaf: Bool, selected: Bool,
                   lineHeight: CGFloat, blockColor: NSColor?,
                   callbacks: OutlineRowCallbacks) {
        self.depth = depth
        self.isQuote = isQuote
        self.isCode = isCode
        self.isEmbed = isEmbed
        self.firstLineHeight = lineHeight
        self.callbacks = callbacks
        self.blockColor = blockColor
        colorBackground.color = blockColor ?? .clear
        colorBackground.isHidden = blockColor == nil
        if isSelectedBlock != selected { isSelectedBlock = selected; needsDisplay = true }
        renderedView.onSelectRequest = { [weak self] extend, toggle in
            self?.callbacks.selectBlock(extend, toggle)
        }
        closePreview()
        rowHasChildren = hasChildren
        // Recompute hover from the live pointer position: on cell reuse the
        // enter/exit events may not re-fire for a row that's already under the
        // pointer, so the chevron would otherwise be stuck shown/hidden.
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        updateFoldVisibility()
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        foldButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8 * BlockRenderer.zoom, weight: .bold))
        foldButton.contentTintColor = .tertiaryLabelColor
        bullet.isCollapsed = collapsed
        // An empty leaf block hides its bullet (nothing to zoom/fold/reference);
        // the gutter space stays so text never shifts horizontally.
        bullet.isHidden = isEmptyLeaf
        needsLayout = true
    }

    /// Unfocused: rendered Markdown (SPEC §5.4).
    func showRendered(_ attributed: NSAttributedString) {
        for view in container.subviews
        where view !== renderedView && view !== quoteBar
            && view !== codeBackground && view !== embedBackground
            && view !== colorBackground {
            view.removeFromSuperview()
        }
        renderedView.isHidden = false
        quoteBar.isHidden = !isQuote
        codeBackground.isHidden = !isCode
        // Sized + shown by layout() once the text is laid out (it hugs only the
        // transcluded line fragments, not the whole cell).
        embedBackground.isHidden = true
        renderedView.textStorage?.setAttributedString(attributed)
        renderedView.renderedContentDidChange()
        // TextKit 2 repaints the glyphs on its own layout path without calling
        // the view's draw(), so the inline-code pills (drawn there) would keep
        // stale pixels — or never appear — after an in-place content update.
        renderedView.needsDisplay = true
        needsLayout = true
    }

    /// Focused: the shared raw-source editor moves into this row (SPEC §15).
    /// Raw source shows its own `> ` markers, so the quote bar hides.
    func embedEditor(_ editor: NSTextView) {
        closePreview()
        renderedView.isHidden = true
        quoteBar.isHidden = true
        codeBackground.isHidden = true
        embedBackground.isHidden = true
        if editor.superview !== container {
            editor.removeFromSuperview()
            container.addSubview(editor)
        }
        editor.frame = container.bounds
        editor.autoresizingMask = [.width, .height]
        needsLayout = true
    }

    /// Live bullet toggle as the focused block crosses empty↔non-empty,
    /// without a full reconfigure.
    func setBulletHidden(_ hidden: Bool) {
        bullet.isHidden = hidden
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedBlock {
            if isEmbed {
                // A block whose body is a generated region (embed/query results)
                // would otherwise become a giant blue blob. Mark selection with a
                // slim leading accent bar instead — the read-only results keep
                // their own grey region.
                NSColor.selectedContentBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
            } else {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
                bounds.fill()
            }
        }
        super.draw(dirtyRect)
    }

    @objc private func foldClicked() {
        callbacks.toggleFold()
    }

    // MARK: - Hover (reveal the fold chevron only under the pointer)

    private func updateFoldVisibility() {
        foldButton.isHidden = !(rowHasChildren && hovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateFoldVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateFoldVisibility()
    }

    /// Briefly washes the row in a warm highlight, then fades out — used to draw
    /// the eye to a block just navigated to (from a query/backlink/tag result).
    /// The overlay sits behind the text (which is on a clear background), so the
    /// content stays readable through the wash.
    func flash() {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.45).cgColor
        overlay.layer?.cornerRadius = 4
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .below, relativeTo: container)
        // Hold at full briefly so the eye catches it, then fade out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 1.0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                overlay.animator().alphaValue = 0
            }, completionHandler: { overlay.removeFromSuperview() })
        }
    }

    // MARK: - Layout (manual; matches the static height calculation)

    override func layout() {
        super.layout()
        let indent = CGFloat(depth) * Self.indentPerDepth
        // Center the bullet/fold on the first line's vertical midpoint.
        let firstLineCenter = Self.verticalPadding + Self.contentInsetV + firstLineHeight / 2
        // Fold chevron and bullet sit in the gutter with offsets scaled by zoom,
        // so the whole gutter — and the bullet-to-text gap — grows with the text.
        let z = BlockRenderer.zoom
        let foldSize = (14 * z).rounded()
        foldButton.frame = NSRect(
            x: indent + (7 * z).rounded() - foldSize / 2, y: firstLineCenter - foldSize / 2,
            width: foldSize, height: foldSize)
        let bulletBox = BulletView.dotDiameter() + 8
        bullet.frame = NSRect(
            x: indent + (22 * z).rounded() - bulletBox / 2, y: firstLineCenter - bulletBox / 2,
            width: bulletBox, height: bulletBox)
        bullet.needsDisplay = true
        let contentX = indent + Self.gutterWidth
        container.frame = NSRect(
            x: contentX,
            y: Self.verticalPadding,
            width: max(10, bounds.width - contentX - Self.trailingPad),
            height: max(10, bounds.height - Self.verticalPadding * 2)
        )
        renderedView.frame = container.bounds
        quoteBar.frame = NSRect(
            x: 2, y: Self.contentInsetV,
            width: 3,
            height: max(0, container.bounds.height - Self.contentInsetV * 2)
        )
        // Full-width filled box, snug to the top/bottom text inset.
        let boxFrame = NSRect(
            x: 0, y: Self.contentInsetV - 2,
            width: container.bounds.width,
            height: max(0, container.bounds.height - (Self.contentInsetV - 2) * 2)
        )
        codeBackground.frame = boxFrame
        colorBackground.frame = boxFrame
        // The embed background hugs only the transcluded line fragments (so a
        // block mixing its own text with an embed greys just the embed), full
        // content width, with a couple px of vertical breathing room.
        if isEmbed, let region = renderedView.embedRegionRect() {
            // `renderedView` is a flipped NSTextView; `container` is not — let
            // AppKit map the rect between the two coordinate systems.
            let r = container.convert(region, from: renderedView)
            embedBackground.isHidden = false
            embedBackground.frame = NSRect(
                x: 0, y: r.minY - 2,
                width: container.bounds.width, height: r.height + 4)
        } else {
            embedBackground.isHidden = true
        }
    }

    /// Content width available at a given depth — the controller measures row
    /// heights with the same numbers `layout()` uses.
    static func contentWidth(forDepth depth: Int, rowWidth: CGFloat) -> CGFloat {
        max(40, rowWidth - CGFloat(depth) * indentPerDepth - gutterWidth - trailingPad)
    }

    /// Twin of `renderedView` used for height measurement with the same
    /// TextKit 2 layout the row actually draws with (`boundingRect`
    /// under-measures and made rows shift when focus moved).
    private static let measuringView = RenderedTextView.create()

    static func height(for attributed: NSAttributedString, contentWidth: CGFloat) -> CGFloat {
        let view = measuringView
        view.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 10)
        view.textContainer?.size = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if attributed.length > 0 {
            view.textStorage?.setAttributedString(attributed)
        } else {
            // Empty block: measure a single space at the base line height —
            // same as the focused editor reports — so an empty row is exactly
            // as tall as a one-line row and doesn't jump when focused (§5.4).
            let space = NSMutableAttributedString(
                string: " ",
                attributes: [.font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize)]
            )
            BlockRenderer.pinLineHeight(space, BlockRenderer.lineHeight(forSource: ""))
            view.textStorage?.setAttributedString(space)
        }
        guard let layoutManager = view.textLayoutManager else { return minRowHeight }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let textHeight = ceil(layoutManager.usageBoundsForTextContainer.height)
        return max(minRowHeight, textHeight + contentInsetV * 2 + verticalPadding * 2)
    }

    // MARK: - Hover preview (SPEC §6.1)

    private func showPreview(forPage name: String, near rect: NSRect) {
        closePreview()
        guard let content = callbacks.pagePreview(name) else { return }
        let width: CGFloat = 360
        let measured = content.boundingRect(
            with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let height = min(ceil(measured) + 26, 320)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(content)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = textView
        scroll.hasVerticalScroller = measured + 26 > 320
        scroll.drawsBackground = false
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: width, height: height)
        let anchor = rect.isEmpty
            ? NSRect(x: 0, y: 0, width: max(renderedView.bounds.width, 1), height: 4)
            : rect
        popover.show(relativeTo: anchor, of: renderedView, preferredEdge: .maxY)
        previewPopover = popover
    }

    private func closePreview() {
        previewPopover?.close()
        previewPopover = nil
    }
}

// MARK: - Rendered content view

/// Non-editable rendered Markdown for unfocused rows: links are clickable
/// (Cmd+Click opens in the right sidebar, SPEC §6.1), any other click focuses
/// the block, and hovering a `[[page]]` link for ~0.5 s requests a preview.
extension NSAttributedString.Key {
    /// Marks the transcluded text of a `{{embed}}` so the row can paint a grey
    /// box behind just those line fragments — not the host block's own text or
    /// the whole cell (SPEC §7.6).
    static let embedRegion = NSAttributedString.Key("knopoEmbedRegion")
}

final class RenderedTextView: NSTextView {

    var onLinkClick: (URL, Bool) -> Void = { _, _ in }
    var onFocusRequest: (Int) -> Void = { _ in }
    /// Shift/Cmd+click → node selection (extend / toggle), not editing.
    var onSelectRequest: (_ extend: Bool, _ toggle: Bool) -> Void = { _, _ in }
    var onHoverPageLink: (String, NSRect) -> Void = { _, _ in }
    var onHoverEnded: () -> Void = {}
    var onImageResize: (_ imageIndex: Int, _ width: CGFloat) -> Void = { _, _ in }

    private var hoverWork: DispatchWorkItem?
    private var hoverRange: NSRange?
    private var hoverArea: NSTrackingArea?
    private var hoverImageIndex: Int?
    /// Reach of the right-edge width handle around the image's trailing edge.
    private static let imageHandleInnerReach: CGFloat = 12
    private static let imageHandleOuterSlop: CGFloat = 4
    /// Resize affordances (handle bar, drag outline, size badge) draw in this
    /// overlay, NOT in `draw(_:)`: TextKit 2 renders text and attachments in
    /// fragment subviews layered above the view's own drawing, so anything
    /// painted there ends up *behind* the images.
    private let resizeOverlay = ImageResizeOverlayView()

    static func create() -> RenderedTextView {
        let view = RenderedTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        // Matches the shared editor's inset so focusing doesn't shift rows.
        view.textContainerInset = NSSize(width: 0, height: OutlineRowCell.contentInsetV)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = false
        view.autoresizingMask = [.width, .height]
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = view
        view.resizeOverlay.frame = view.bounds
        view.resizeOverlay.autoresizingMask = [.width, .height]
        view.addSubview(view.resizeOverlay)
        return view
    }

    /// TextKit 2 inserts its fragment views as subviews on demand; keep the
    /// affordance overlay above them whenever it has something to show.
    private func updateResizeOverlay(
        hoverFrame: NSRect?, preview: ImageResizeOverlayView.Preview?
    ) {
        resizeOverlay.hoverFrame = hoverFrame
        resizeOverlay.preview = preview
        if hoverFrame != nil || preview != nil, subviews.last !== resizeOverlay {
            addSubview(resizeOverlay, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: Inline-code pill

    override func draw(_ dirtyRect: NSRect) {
        drawInlineCodePills()
        super.draw(dirtyRect)
    }

    /// A padded, rounded box behind each inline `code` run (keyed on
    /// `BlockRenderer.inlineCodeKey`) — TextKit 2's `.backgroundColor` is a
    /// tight square rect with no breathing room, so we draw our own.
    private func drawInlineCodePills() {
        guard let tlm = textLayoutManager,
              let tcs = textContentStorage,
              let storage = textStorage, storage.length > 0 else { return }
        // Collect the code ranges first so rows without code bail out cheaply.
        var ranges: [NSRange] = []
        storage.enumerateAttribute(
            BlockRenderer.inlineCodeKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value != nil, range.length > 0 { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        // Segment frames are only valid for laid-out text. Without this, the
        // first draw of a row can miss pills entirely, and a reused row can
        // place them at the previous content's offsets.
        tlm.ensureLayout(for: tlm.documentRange)
        let origin = textContainerOrigin
        NSColor.secondarySystemFill.setFill()
        for range in ranges {
            guard let start = tcs.location(tcs.documentRange.location, offsetBy: range.location),
                  let end = tcs.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            // `.highlight` segments are the box geometry TextKit 2 itself uses
            // for selection/background drawing: full line height, uniform across
            // mixed fonts on the line.
            tlm.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
                guard frame.width > 0 else { return true }
                // Horizontal padding is real (thin spaces inside the run), so the
                // pill hugs the segment; -1 just softens the rounded edge.
                let pill = frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                return true
            }
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imageHit = imageHandle(at: point)
        if let image = imageHit {
            trackImageResize(from: event, image: image)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wantsSidebar = flags.contains(.command) || flags.contains(.shift)
        // Handle link clicks directly: deferring to super lets a selectable
        // NSTextView treat Shift+click as text-selection, so the link delegate
        // never fires and the sidebar never opens.
        if let url = linkValue(at: point) {
            onLinkClick(url, wantsSidebar)
            return
        }
        // On non-link text, Shift/Cmd+click is node selection, not editing.
        if wantsSidebar {
            onSelectRequest(flags.contains(.shift), flags.contains(.command))
            return
        }
        // Anything else (including empty space inside a query/embed region)
        // focuses the block, so a query block can still be clicked to edit.
        onFocusRequest(characterIndexForInsertion(at: point))
    }

    private func imageHandle(at point: NSPoint) -> (index: Int, frame: NSRect)? {
        imageHit(at: point) { imageHandleRect(for: $0).contains(point) }
    }

    private func image(at point: NSPoint) -> (index: Int, frame: NSRect)? {
        imageHit(at: point) { $0.contains(point) }
    }

    /// Finds attachments by their rendered frames instead of asking TextKit for
    /// an insertion index. At attachment edges that index can alternate between
    /// the image and the neighboring character, making a small resize handle
    /// effectively disappear under a stationary pointer.
    private func imageHit(
        at point: NSPoint, where contains: (NSRect) -> Bool
    ) -> (index: Int, frame: NSRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var hits: [(index: Int, frame: NSRect)] = []
        storage.enumerateAttribute(
            BlockRenderer.imageIndexKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let index = value as? Int,
                  storage.attribute(.embedRegion, at: range.location, effectiveRange: nil) == nil,
                  let frame = imageFrame(at: range.location), contains(frame) else { return }
            hits.append((index, frame))
        }
        // Expanded handle targets can overlap for adjacent small images. The
        // nearest right edge is the one the pointer is aiming at.
        return hits.min {
            hypot(point.x - $0.frame.maxX, point.y - $0.frame.midY)
                < hypot(point.x - $1.frame.maxX, point.y - $1.frame.midY)
        }
    }

    /// The grab zone for the width handle: a strip along the image's right
    /// edge, full height — matching the vertical handle bar the overlay draws.
    private func imageHandleRect(for frame: NSRect) -> NSRect {
        let reach = min(Self.imageHandleInnerReach, frame.width / 2)
        return NSRect(
            x: frame.maxX - reach,
            y: frame.minY,
            width: reach + Self.imageHandleOuterSlop,
            height: frame.height
        )
    }

    private func imageFrame(for imageIndex: Int) -> NSRect? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var characterIndex: Int?
        storage.enumerateAttribute(
            BlockRenderer.imageIndexKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value as? Int == imageIndex,
                  storage.attribute(.embedRegion, at: range.location, effectiveRange: nil) == nil
            else { return }
            characterIndex = range.location
            stop.pointee = true
        }
        return characterIndex.flatMap(imageFrame(at:))
    }

    private func imageFrame(at characterIndex: Int) -> NSRect? {
        guard let manager = textLayoutManager, let storage = textContentStorage,
              let start = storage.location(
                storage.documentRange.location, offsetBy: characterIndex
              ),
              let end = storage.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        let attachmentBounds = (textStorage?.attribute(
            .attachment, at: characterIndex, effectiveRange: nil
        ) as? NSTextAttachment)?.bounds
        manager.ensureLayout(for: range)
        let origin = textContainerOrigin
        var result: NSRect?
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            guard frame.width > 0, frame.height > 0 else { return true }
            let segment = frame.offsetBy(dx: origin.x, dy: origin.y)
            if let bounds = attachmentBounds, bounds.width > 0, bounds.height > 0 {
                // A segment spans the line's tallest attachment. Pin this image
                // to the segment bottom using its own bounds, so mixed-size
                // images get handles on their actual corners.
                result = NSRect(
                    x: segment.minX + bounds.minX,
                    y: segment.maxY - bounds.height - bounds.minY,
                    width: bounds.width, height: bounds.height
                )
            } else {
                result = segment
            }
            return false
        }
        return result
    }

    private func naturalImageSize(for imageIndex: Int) -> NSSize? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var result: NSSize?
        storage.enumerateAttribute(
            BlockRenderer.imageIndexKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value as? Int == imageIndex,
                  storage.attribute(.embedRegion, at: range.location, effectiveRange: nil) == nil,
                  let attachment = storage.attribute(
                    .attachment, at: range.location, effectiveRange: nil
                  ) as? NSTextAttachment,
                  let image = attachment.image else { return }
            result = image.size
            stop.pointee = true
        }
        return result
    }

    func renderedContentDidChange() {
        hoverImageIndex = nil
        updateResizeOverlay(hoverFrame: nil, preview: nil)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.enumerateAttribute(
            BlockRenderer.imageIndexKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil,
                  storage.attribute(.embedRegion, at: range.location, effectiveRange: nil) == nil,
                  let frame = imageFrame(at: range.location) else { return }
            let cursorRect = imageHandleRect(for: frame).intersection(bounds)
            if !cursorRect.isEmpty {
                addCursorRect(cursorRect, cursor: .resizeLeftRight)
            }
        }
    }

    private func trackImageResize(
        from startEvent: NSEvent, image: (index: Int, frame: NSRect)
    ) {
        guard let window, let natural = naturalImageSize(for: image.index),
              natural.width > 0, natural.height > 0 else { return }
        let start = convert(startEvent.locationInWindow, from: nil)
        let aspect = natural.height / natural.width
        let maximum = max(40, natural.width * 4)
        var width = image.frame.width

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseDragged {
                let point = convert(event.locationInWindow, from: nil)
                width = min(max(image.frame.width + point.x - start.x, 40), maximum)
                let height = width * aspect
                updateResizeOverlay(
                    hoverFrame: nil,
                    preview: ImageResizeOverlayView.Preview(
                        frame: NSRect(x: image.frame.minX, y: image.frame.minY,
                                      width: width, height: height),
                        width: Int(width.rounded()), height: Int(height.rounded())
                    )
                )
            } else {
                updateResizeOverlay(hoverFrame: nil, preview: nil)
                onImageResize(image.index, width.rounded())
                return
            }
        }
    }

    private func linkValue(at point: NSPoint) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        // A click in the empty space past a line's text isn't a link (it falls
        // through to focusing the block); only a hit on actual glyphs counts.
        // Check the specific *line* fragment, not the whole layout fragment: a
        // wrapped link is one multi-line fragment whose width is the long first
        // line's, so the short trailing line's empty gap would otherwise map to
        // the link.
        let container = NSPoint(x: point.x - textContainerInset.width,
                                y: point.y - textContainerInset.height)
        if let lm = textLayoutManager, let frag = lm.textLayoutFragment(for: container) {
            let origin = frag.layoutFragmentFrame.origin
            var pastLineText = container.x > frag.layoutFragmentFrame.maxX
            for line in frag.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
                if container.y >= bounds.minY, container.y < bounds.maxY {
                    pastLineText = container.x > bounds.maxX
                    break
                }
            }
            if pastLineText { return nil }
        }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        guard index >= 0 else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// Bounding rect (in this view's coordinates) of all text carrying
    /// `.embedRegion`, so the row can grey-box only the transcluded lines.
    /// Returns nil when there is no embed.
    func embedRegionRect() -> NSRect? {
        guard let storage = textStorage, storage.length > 0,
              let lm = textLayoutManager,
              let cm = lm.textContentManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
        let origin = textContainerOrigin
        var union = NSRect.null
        storage.enumerateAttribute(.embedRegion,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? Bool) == true,
                  let start = cm.location(cm.documentRange.location, offsetBy: range.location),
                  let end = cm.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            lm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let r = frame.offsetBy(dx: origin.x, dy: origin.y)
                union = union.isNull ? r : union.union(r)
                return true
            }
        }
        return union.isNull ? nil : union
    }

    // MARK: Hover preview scheduling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let handle = imageHandle(at: point)
        let hoveredImage = handle ?? image(at: point)
        if hoverImageIndex != hoveredImage?.index {
            hoverImageIndex = hoveredImage?.index
            updateResizeOverlay(hoverFrame: hoveredImage?.frame, preview: nil)
        }
        if handle != nil {
            NSCursor.resizeLeftRight.set()
            cancelHover()
            onHoverEnded()
            return
        }
        if hoveredImage != nil {
            NSCursor.arrow.set()
            cancelHover()
            onHoverEnded()
            return
        }
        if linkValue(at: point) != nil { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
        guard let (name, range) = pageLink(at: point) else {
            cancelHover()
            onHoverEnded()
            return
        }
        guard range != hoverRange else { return }
        cancelHover()
        hoverRange = range
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            let screenRect = self.firstRect(forCharacterRange: range, actualRange: nil)
            let local = self.convert(window.convertFromScreen(screenRect), from: nil)
            self.onHoverPageLink(name, local)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverImageIndex = nil
        updateResizeOverlay(hoverFrame: nil, preview: nil)
        NSCursor.arrow.set()
        cancelHover()
        onHoverEnded()
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
        hoverRange = nil
    }

    private func pageLink(at point: NSPoint) -> (name: String, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard index >= 0, index < storage.length else { return nil }
        // No hover preview inside a generated region (query results / embeds):
        // those rows are themselves page links, and a transient popover over
        // them swallows the next click, making result rows feel unclickable.
        if storage.attribute(.embedRegion, at: index, effectiveRange: nil) != nil { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let url = storage.attribute(.link, at: index, effectiveRange: &range) as? URL,
              url.scheme == "knopo", url.host == "page" else { return nil }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard !name.isEmpty else { return nil }
        return (name, range)
    }
}

extension RenderedTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let direct = link as? URL {
            url = direct
        } else if let string = link as? String {
            url = URL(string: string)
        } else {
            url = nil
        }
        guard let url else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let inSidebar = flags.contains(.command) || flags.contains(.shift)
        onLinkClick(url, inSidebar)
        return true
    }
}

// MARK: - Quote bar

/// The continuous vertical bar beside a quote block. Drawn as one view per
/// row (the block IS the quote container), so there are no per-line gaps.
final class QuoteBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// MARK: - Code background

/// The filled box behind a fenced code block — one rounded rect spanning the
/// full content width, so there are no white gaps between code lines.
final class CodeBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

// MARK: - Block color background

/// The soft rounded box behind a block carrying `background-color::`. Color is
/// set by the cell from the block's property.
final class ColorBoxView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard color != .clear else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Embed background

/// The filled box behind a read-only embed (§7.6) — a subtle accent tint so the
/// transcluded region reads as embedded, full content width, no per-line gaps.
final class EmbedBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // A neutral grey fill — deliberately NOT accent/blue, so an embed never
        // reads like the (blue) selection/focus highlight.
        NSColor.secondaryLabelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

// MARK: - Bullet

/// The block bullet: click zooms into the block (SPEC §5.4), right-click opens
/// the block menu. Collapsed blocks draw a halo.
final class BulletView: NSView {

    var isCollapsed = false {
        didSet { needsDisplay = true }
    }
    var onClick: () -> Void = {}
    var onContextMenu: (NSEvent) -> Void = { _ in }
    /// Dragging the bullet moves the block (SPEC §5.4). Receives the original
    /// mouse-down event so the drag session anchors to the press point.
    var onBeginDrag: (NSEvent) -> Void = { _ in }
    private var pressEvent: NSEvent?

    /// Dot diameter, scaled with the text size (zoom) so the bullet doesn't look
    /// tiny next to large text. ~5px at the default size.
    static func dotDiameter() -> CGFloat {
        max(4, (BlockRenderer.baseFontSize * 0.36).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = Self.dotDiameter()
        if isCollapsed {
            let halo = d + 6
            NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: bounds.midX - halo / 2, y: bounds.midY - halo / 2,
                width: halo, height: halo)).fill()
        }
        // A small, light-gray dot: structure, not content, so it stays out of the
        // way (matching the lighter Logseq bullet). Collapsed blocks read darker.
        let dot = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        if isCollapsed {
            NSColor.secondaryLabelColor.withAlphaComponent(0.9).setFill()
        } else {
            NSColor.tertiaryLabelColor.setFill()
        }
        NSBezierPath(ovalIn: dot).fill()
    }

    // Click vs drag: the click (zoom) fires on mouse-up so a small movement
    // threshold can promote the press into a block drag instead.
    override func mouseDown(with event: NSEvent) {
        pressEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        let dx = event.locationInWindow.x - press.locationInWindow.x
        let dy = event.locationInWindow.y - press.locationInWindow.y
        if dx * dx + dy * dy >= 9 { // ~3pt travel
            pressEvent = nil
            onBeginDrag(press)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        pressEvent = nil
        onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Image-resize overlay

/// Transparent top layer for the image width-handle, drag outline, and size
/// badge. Lives above TextKit 2's fragment subviews (which render the text and
/// image attachments), so the affordances draw over the images — painting them
/// in the text view's own `draw(_:)` puts them underneath. Never intercepts
/// events.
final class ImageResizeOverlayView: NSView {

    struct Preview: Equatable {
        var frame: NSRect
        var width: Int
        var height: Int
    }

    /// Hovered image frame: draws the vertical width-handle bar on its right
    /// edge (width-only resize, matching the horizontal resize cursor).
    var hoverFrame: NSRect? {
        didSet { if hoverFrame != oldValue { needsDisplay = true } }
    }
    /// Live drag state: dashed target outline and a "W × H" badge.
    var preview: Preview? {
        didSet { if preview != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }  // match the host text view

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let frame = hoverFrame, preview == nil {
            drawHandleBar(on: frame)
        }
        guard let preview else { return }
        let outline = NSBezierPath(rect: preview.frame.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        drawBadge("\(preview.width) × \(preview.height)", for: preview.frame)
    }

    /// A rounded vertical bar just inside the image's right edge (the Notion
    /// convention for width handles) — dark fill with a light border so it
    /// reads on any image content.
    private func drawHandleBar(on frame: NSRect) {
        let height = min(36, max(12, frame.height * 0.4))
        let bar = NSRect(
            x: frame.maxX - 9, y: frame.midY - height / 2, width: 6, height: height
        )
        let path = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.5).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawBadge(_ label: String, for frame: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        let badgeSize = NSSize(width: ceil(labelSize.width) + 10,
                               height: ceil(labelSize.height) + 6)
        let badge = NSRect(
            x: max(bounds.minX + 2,
                   min(frame.maxX - badgeSize.width, bounds.maxX - badgeSize.width - 2)),
            y: frame.minY + 4,
            width: badgeSize.width, height: badgeSize.height
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(
            at: NSPoint(x: badge.minX + 5, y: badge.minY + 3), withAttributes: attributes
        )
    }
}

// MARK: - Empty-page placeholder

/// Shown when the (zoomed) outline has no rows; click creates the first block.
final class PlaceholderRowCell: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PlaceholderRowCell")

    var onClick: () -> Void = {}
    private let label = NSTextField(labelWithString: "Click to add a block")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: OutlineRowCell.gutterWidth, y: 4)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
