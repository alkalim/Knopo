import AppKit
import SwiftUI

/// Lays out the new width once, then slides the panes without reflowing text
/// on every animation frame. Both the toolbar and menu use this path.
@MainActor
enum SidebarTransition {
    static let animationKey = "knopo.sidebar.slide"
    static let duration: CFTimeInterval = 0.16

    static func controller(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView,
           let controller = split.delegate as? NSSplitViewController,
           split.isVertical, controller.splitViewItems.count == 2 {
            return controller
        }
        for child in view.subviews {
            if let controller = controller(in: child) { return controller }
        }
        return nil
    }

    @MainActor final class State: ObservableObject {
        @Published private var columnVisibility: NavigationSplitViewVisibility
        weak var window: NSWindow?
        var preferences: Preferences?

        init(hideSidebar: Bool) {
            columnVisibility = hideSidebar ? .detailOnly : .automatic
        }

        var visibility: Binding<NavigationSplitViewVisibility> {
            Binding(get: { self.columnVisibility }, set: { value in
                // Keep the native toolbar control. Handle its visibility binding
                // before SwiftUI starts a split-view resize animation.
                if let preferences = self.preferences {
                    SidebarTransition.setCollapsed(value == .detailOnly,
                                                   in: self.window, preferences: preferences)
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.columnVisibility = value }
            })
        }
    }

    struct WindowAttachment: NSViewRepresentable {
        let state: State
        let preferences: Preferences

        func makeNSView(context: Context) -> AttachmentView {
            let view = AttachmentView()
            view.state = state
            state.preferences = preferences
            return view
        }

        func updateNSView(_ view: AttachmentView, context: Context) {
            state.preferences = preferences
            state.window = view.window
        }

        final class AttachmentView: NSView {
            weak var state: State?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                state?.window = window
            }
        }
    }

    static func toggle(in window: NSWindow?, preferences: Preferences) {
        guard let content = window?.contentView,
              let sidebar = controller(in: content)?.splitViewItems.first else { return }
        setCollapsed(!sidebar.isCollapsed, in: window, preferences: preferences)
    }

    static func setCollapsed(_ collapsing: Bool, in window: NSWindow?, preferences: Preferences) {
        guard let window, let content = window.contentView,
              let controller = controller(in: content),
              let sidebar = controller.splitViewItems.first,
              let detail = controller.splitViewItems.last, sidebar !== detail,
              sidebar.isCollapsed != collapsing else { return }
        let split = controller.splitView
        let sidebarView = split.arrangedSubviews.first {
            sidebar.viewController.view.isDescendant(of: $0)
        } ?? sidebar.viewController.view
        let detailView = split.arrangedSubviews.first {
            detail.viewController.view.isDescendant(of: $0)
        } ?? detail.viewController.view
        let host = split.superview
        let interrupted = detailView.layer?.animation(forKey: animationKey) != nil
        sidebarView.layer?.removeAnimation(forKey: animationKey)
        detailView.layer?.removeAnimation(forKey: animationKey)
        host?.subviews.compactMap { $0 as? Snapshot }.filter { $0.split === split }
            .forEach { $0.removeFromSuperview() }

        let animate = preferences.animationsEnabled && window.isVisible && !interrupted
        // macOS 26 reserves sidebar space with a safe-area inset. Older
        // versions move the detail pane's frame instead.
        let oldDetailX = detailView.frame.minX + detailView.safeAreaInsets.left
        let oldSidebarWidth = sidebarView.frame.width
        let snapshot = animate && collapsing
            ? host.flatMap { Snapshot.capture(sidebarView, in: $0, split: split) } : nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            let collapseBehavior = sidebar.collapseBehavior
            // Native sidebar defaults can grow the window when reopening.
            // Let the existing window constraints keep its size instead.
            sidebar.collapseBehavior = .useConstraints
            sidebar.isCollapsed = collapsing
            window.layoutIfNeeded()
            split.layoutSubtreeIfNeeded()
            sidebar.collapseBehavior = collapseBehavior
        }
        guard animate else { return }
        slide(detailView, from: oldDetailX - detailView.frame.minX - detailView.safeAreaInsets.left)
        if let snapshot, let host {
            host.addSubview(snapshot)
            snapshot.wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapshot.layer?.transform = CATransform3DMakeTranslation(-oldSidebarWidth, 0, 0)
            CATransaction.commit()
            slide(snapshot, from: oldSidebarWidth)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak snapshot] in
                snapshot?.removeFromSuperview()
            }
        } else if !collapsing {
            slide(sidebarView, from: -sidebarView.frame.width)
        }
    }

    private static func slide(_ view: NSView, from offset: CGFloat) {
        guard abs(offset) > 0.5 else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.isAdditive = true
        animation.fromValue = offset
        animation.toValue = 0
        animation.duration = duration
        let start = layer.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = start
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: animationKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak layer] in
            guard layer?.animation(forKey: animationKey)?.beginTime == start else { return }
            layer?.removeAnimation(forKey: animationKey)
        }
    }

    final class Snapshot: NSView {
        struct Fragment {
            let image: NSImage
            let frame: NSRect
        }

        let fragments: [Fragment]
        weak var split: NSSplitView?
        private let sourceIsFlipped: Bool
        override var isFlipped: Bool { sourceIsFlipped }

        static func capture(_ source: NSView, in host: NSView, split: NSSplitView) -> Snapshot? {
            var fragments: [Fragment] = []
            func captureTables(in view: NSView) {
                if let table = view as? NSTableView {
                    // Capturing the whole sidebar skips SwiftUI list content on
                    // macOS 26. Capture the visible rows directly instead.
                    table.enumerateAvailableRowViews { row, _ in
                        let visible = row.bounds.intersection(row.convert(table.visibleRect, from: table))
                        guard !visible.isEmpty,
                              let bitmap = row.bitmapImageRepForCachingDisplay(in: visible) else { return }
                        row.cacheDisplay(in: visible, to: bitmap)
                        let image = NSImage(size: visible.size)
                        image.addRepresentation(bitmap)
                        fragments.append(Fragment(image: image, frame: row.convert(visible, to: source)))
                    }
                    return
                }
                for child in view.subviews { captureTables(in: child) }
            }
            captureTables(in: source)
            guard !fragments.isEmpty else { return nil }
            return Snapshot(frame: source.convert(source.bounds, to: host), fragments: fragments,
                            source: source, split: split)
        }

        private init(frame: NSRect, fragments: [Fragment], source: NSView, split: NSSplitView) {
            self.fragments = fragments
            self.split = split
            sourceIsFlipped = source.isFlipped
            super.init(frame: frame)
            clipsToBounds = true
            let content = Content(frame: bounds, fragments: fragments, flipped: sourceIsFlipped)
            content.autoresizingMask = [.width, .height]
            // Glass and vibrancy need a live backdrop. Keep the native material
            // behind the captured rows while the sidebar slides away.
            if #available(macOS 26.0, *), let original = Self.find(NSGlassEffectView.self, in: source) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = original.style
                glass.cornerRadius = original.cornerRadius
                glass.tintColor = original.tintColor
                glass.contentView = content
                addSubview(glass)
            } else {
                let material = NSVisualEffectView(frame: bounds)
                material.material = .sidebar
                material.blendingMode = .behindWindow
                material.state = .followsWindowActiveState
                addSubview(material)
                addSubview(content)
            }
        }

        private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews {
                if let match = find(type, in: child) { return match }
            }
            return nil
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityChildren() -> [Any]? { [] }

        final class Content: NSView {
            let fragments: [Fragment]
            let sourceIsFlipped: Bool
            override var isFlipped: Bool { sourceIsFlipped }

            init(frame: NSRect, fragments: [Fragment], flipped: Bool) {
                self.fragments = fragments
                self.sourceIsFlipped = flipped
                super.init(frame: frame)
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
            override func draw(_ dirtyRect: NSRect) {
                for fragment in fragments {
                    fragment.image.draw(in: fragment.frame, from: .zero, operation: .sourceOver,
                                        fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
    }
}
