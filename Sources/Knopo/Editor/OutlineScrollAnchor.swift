import AppKit
import ObjectiveC

/// Keeps one reading position for all outlines in a shared scroll view.
@MainActor
final class OutlineScrollAnchor {
    private static var associationKey: UInt8 = 0
    private static let dividerWindows = NSHashTable<NSWindow>.weakObjects()
    private weak var scrollView: NSScrollView?
    private weak var tableView: OutlineTableView?
    private var blockID: UUID?
    private var offset: CGFloat = 0
    private var generation = 0
    private var width: CGFloat
    private var active = false
    private var fallbackY: CGFloat = 0
    private var anchorsBottom = false
    private var capturedRowHeight: CGFloat = 0
    private var geometryObservers: [NSObjectProtocol] = []
    private var resizeObservers: [NSObjectProtocol] = []
    private var restoring = false
    private weak var drawingView: DrawingView?
    private var notificationSettings: [(NSView, Bool, Bool)] = []
    private var visibleRefreshScheduled = false

    static func isLiveResizing(_ view: NSView) -> Bool {
        view.inLiveResize || view.enclosingScrollView?.inLiveResize == true
            || view.window?.inLiveResize == true
            || view.window.map { dividerWindows.contains($0) } == true
    }

    static func beginDividerResize(in window: NSWindow?) {
        guard let window else { return }
        dividerWindows.add(window)
        if let content = window.contentView {
            for table in outlines(in: content) {
                guard let scroll = table.enclosingScrollView else { continue }
                let anchor = state(for: scroll)
                if !anchor.active { anchor.capture() }
            }
        }
    }

    static func endDividerResize(in window: NSWindow?) {
        guard let window else { return }
        dividerWindows.remove(window)
        if let content = window.contentView {
            for table in outlines(in: content) {
                table.onLiveResizeEnd?()
                if let scroll = table.enclosingScrollView {
                    state(for: scroll).scheduleRestore()
                }
            }
        }
    }

    static func cancel(in view: NSView) {
        guard let scroll = view.enclosingScrollView,
              let anchor = objc_getAssociatedObject(scroll, &associationKey) as? OutlineScrollAnchor else { return }
        anchor.generation += 1
        anchor.finish()
    }

    private static func state(for scroll: NSScrollView) -> OutlineScrollAnchor {
        if let existing = objc_getAssociatedObject(scroll, &associationKey) as? OutlineScrollAnchor {
            return existing
        }
        let anchor = OutlineScrollAnchor(scroll: scroll)
        objc_setAssociatedObject(scroll, &associationKey, anchor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return anchor
    }

    static func register(_ view: NSView) {
        if let scroll = view.enclosingScrollView {
            _ = state(for: scroll)
        }
    }

    static func preserve(beforeResizing view: NSView, widthChanged: Bool = false) {
        guard let scroll = view.enclosingScrollView else { return }
        let anchor = state(for: scroll)
        let width = scroll.contentSize.width
        if widthChanged || abs(width - anchor.width) > 0.5 {
            if !anchor.active { anchor.capture() }
            anchor.width = width
        }
        if anchor.active {
            anchor.drawingView?.needsDisplay = true
            anchor.scheduleRestore()
        }
    }

    private init(scroll: NSScrollView) {
        scrollView = scroll
        width = scroll.contentSize.width
        let drawing = DrawingView(frame: scroll.bounds)
        drawing.anchor = self
        drawing.wantsLayer = true
        drawing.autoresizingMask = [.width, .height]
        scroll.addSubview(drawing)
        drawingView = drawing
        scroll.contentView.postsBoundsChangedNotifications = true
        resizeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleVisibleRefresh() }
        })
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            resizeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: scroll, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.generation += 1
                    self?.finish()
                }
            })
        }
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification] {
            resizeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow,
                          self.scrollView?.window === window else { return }
                    if notification.name == NSWindow.willStartLiveResizeNotification {
                        if !self.active { self.capture() }
                    } else {
                        self.scheduleRestore()
                    }
                }
            })
        }
    }

    // Correct only after SwiftUI has placed all days. Scrolling from geometry
    // notifications interrupts lazy layout and can evict the anchored day.
    private final class DrawingView: NSView {
        weak var anchor: OutlineScrollAnchor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            anchor?.scheduleRestore()
        }

        override func viewWillDraw() {
            anchor?.restore()
            super.viewWillDraw()
        }
    }

    deinit {
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func capture() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        active = true
        tableView = nil
        blockID = nil
        fallbackY = scroll.contentView.bounds.minY
        let top = fallbackY + scroll.contentInsets.top
        // At the start of the document, keep its padding above the first row.
        guard top > 0.5 else { return }
        let tables = Self.outlines(in: document).filter { $0.enclosingScrollView === scroll }
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for table in tables where table.numberOfRows > 0 {
            let point = table.convert(NSPoint(x: 0, y: top), from: document)
            let lastRow = table.numberOfRows - 1
            let below = point.y >= table.rect(ofRow: lastRow).maxY
            let row = below ? lastRow : (point.y < 0 ? 0 : table.row(at: NSPoint(x: 0, y: point.y)))
            guard row >= 0,
                  let controller = table.delegate as? OutlineEditorController,
                  let id = controller.scrollAnchorBlock(at: row) else { continue }
            let rect = table.convert(table.rect(ofRow: row), to: document)
            let distance = max(0, rect.minY - top, top - rect.maxY)
            guard distance < nearestDistance else { continue }
            nearestDistance = distance
            tableView = table
            blockID = id
            anchorsBottom = below
            capturedRowHeight = rect.height
            offset = (below ? rect.maxY : rect.minY) - top
        }
        observeGeometry()
    }

    private func observeGeometry() {
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        geometryObservers.removeAll()
        var view: NSView? = tableView
        while let current = view, current !== scrollView?.contentView {
            notificationSettings.append((current, current.postsFrameChangedNotifications,
                                         current.postsBoundsChangedNotifications))
            current.postsFrameChangedNotifications = true
            current.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                geometryObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: current, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.drawingView?.needsDisplay = true }
                })
            }
            view = current.superview
        }
        if let clip = scrollView?.contentView {
            notificationSettings.append((clip, clip.postsFrameChangedNotifications,
                                         clip.postsBoundsChangedNotifications))
            clip.postsBoundsChangedNotifications = true
            geometryObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawingView?.needsDisplay = true }
            })
        }
    }

    private static func outlines(in view: NSView) -> [OutlineTableView] {
        if let table = view as? OutlineTableView { return [table] }
        return view.subviews.flatMap { outlines(in: $0) }
    }

    private func scheduleVisibleRefresh() {
        guard !visibleRefreshScheduled else { return }
        visibleRefreshScheduled = true
        // Scrolling can expose retained layers without asking their tables to
        // draw again. Measure deferred rows after the scroll layout settles.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleRefreshScheduled = false
            guard let scroll = self.scrollView, let document = scroll.documentView,
                  !Self.isLiveResizing(scroll) else { return }
            for table in Self.outlines(in: document) where table.enclosingScrollView === scroll {
                (table.delegate as? OutlineEditorController)?.refreshVisibleWidth()
            }
        }
    }

    private func scheduleRestore() {
        guard active else { return }
        generation += 1
        let scheduledGeneration = generation
        // Row measurement and SwiftUI's document layout finish in separate passes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            guard let scroll = self.scrollView, !Self.isLiveResizing(scroll) else { return }
            self.restore()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == scheduledGeneration else { return }
                self.restore()
                guard let scroll = self.scrollView, !Self.isLiveResizing(scroll),
                      self.tableView.map({ Self.isLiveResizing($0) }) != true else { return }
                self.finish()
            }
        }
    }

    private func finish() {
        active = false
        tableView = nil
        blockID = nil
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        geometryObservers.removeAll()
        for (view, frame, bounds) in notificationSettings {
            view.postsFrameChangedNotifications = frame
            view.postsBoundsChangedNotifications = bounds
        }
        notificationSettings.removeAll()
    }

    private func restore() {
        guard active, !restoring,
              let scroll = scrollView, let document = scroll.documentView else { return }
        restoring = true
        defer { restoring = false }
        let y: CGFloat
        if let table = tableView, table.enclosingScrollView === scroll,
           let blockID, let controller = table.delegate as? OutlineEditorController,
           let row = controller.scrollAnchorRow(for: blockID) {
            let rect = table.convert(table.rect(ofRow: row), to: document)
            let edge = anchorsBottom ? rect.maxY : rect.minY
            // A shortened paragraph must not move entirely above the viewport.
            let retainedOffset = anchorsBottom || rect.height >= capturedRowHeight - 0.5 ? offset
                : max(offset, -max(0, rect.height - OutlineRowCell.minRowHeight / 2))
            y = edge - retainedOffset - scroll.contentInsets.top
        } else if blockID == nil {
            y = fallbackY
        } else {
            return
        }
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = y
        let origin = clip.constrainBoundsRect(bounds).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }
}
