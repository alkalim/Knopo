import AppKit
import EverseqCore

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
}

/// One outline row (SPEC §5.4): indentation by depth, fold triangle, bullet
/// (click = zoom), and content — either the shared raw-source editor (focused)
/// or rendered Markdown (unfocused).
final class OutlineRowCell: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("OutlineRowCell")
    static let indentPerDepth: CGFloat = 22
    static let gutterWidth: CGFloat = 34
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
        // Backgrounds sit behind the text so a code/embed block reads as one
        // filled box (full content width, no per-line gaps).
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
                   lineHeight: CGFloat,
                   callbacks: OutlineRowCallbacks) {
        self.depth = depth
        self.isQuote = isQuote
        self.isCode = isCode
        self.isEmbed = isEmbed
        self.firstLineHeight = lineHeight
        self.callbacks = callbacks
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
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
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
            && view !== codeBackground && view !== embedBackground {
            view.removeFromSuperview()
        }
        renderedView.isHidden = false
        quoteBar.isHidden = !isQuote
        codeBackground.isHidden = !isCode
        // Sized + shown by layout() once the text is laid out (it hugs only the
        // transcluded line fragments, not the whole cell).
        embedBackground.isHidden = true
        renderedView.textStorage?.setAttributedString(attributed)
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
        foldButton.frame = NSRect(
            x: indent, y: firstLineCenter - 7, width: 14, height: 14)
        bullet.frame = NSRect(
            x: indent + 16, y: firstLineCenter - 6, width: 12, height: 12)
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
    static let embedRegion = NSAttributedString.Key("everseqEmbedRegion")
}

final class RenderedTextView: NSTextView {

    var onLinkClick: (URL, Bool) -> Void = { _, _ in }
    var onFocusRequest: (Int) -> Void = { _ in }
    /// Shift/Cmd+click → node selection (extend / toggle), not editing.
    var onSelectRequest: (_ extend: Bool, _ toggle: Bool) -> Void = { _, _ in }
    var onHoverPageLink: (String, NSRect) -> Void = { _, _ in }
    var onHoverEnded: () -> Void = {}

    private var hoverWork: DispatchWorkItem?
    private var hoverRange: NSRange?
    private var hoverArea: NSTrackingArea?

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
        return view
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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

    private func linkValue(at point: NSPoint) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        // A click in the empty space past a line's text isn't a link (it falls
        // through to focusing the block); only a hit on actual glyphs counts.
        let container = NSPoint(x: point.x - textContainerInset.width,
                                y: point.y - textContainerInset.height)
        if let lm = textLayoutManager, let frag = lm.textLayoutFragment(for: container),
           container.x > frag.layoutFragmentFrame.maxX {
            return nil
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
              url.scheme == "everseq", url.host == "page" else { return nil }
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

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
        let dot = NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)
        NSColor.secondaryLabelColor.withAlphaComponent(isCollapsed ? 0.9 : 0.6).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
