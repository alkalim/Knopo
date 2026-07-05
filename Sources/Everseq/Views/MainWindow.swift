import SwiftUI
import EverseqCore

struct MainWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator

    /// User-set right-sidebar width as a fraction (0–1) of the detail area. Nil
    /// until the divider is dragged (or a saved fraction is restored) — until
    /// then a proportional default is used. Storing a fraction (not points)
    /// makes it scale with the window and restore correctly at any window size.
    @State private var rightFraction: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private let mainMinWidth: CGFloat = 320
    private let rightMinWidth: CGFloat = 280

    var body: some View {
        // Read the history into body-level values so the toolbar's menus rebuild
        // when they change — reading `nav.backTitles` *inside* the toolbar
        // closure isn't enough; SwiftUI doesn't re-run it on every nav change.
        let backTitles = nav.backTitles
        let forwardTitles = nav.forwardTitles
        // NavigationSplitView gives the left sidebar the native source-list
        // material and the standard collapse toolbar button.
        return NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if nav.findActive {
                            FindBar()
                            Divider()
                        }
                        mainContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // The document area needs its own opaque surface: the
                            // editor's table/scroll views are clear, so otherwise
                            // it shows the window's grey (notably heavier on macOS
                            // 15 than 26). White in light mode; window grey in dark
                            // mode keeps the existing dark look.
                            .background(Color(nsColor: .dynamic(
                                light: .textBackgroundColor, dark: .windowBackgroundColor)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !nav.rightPanes.isEmpty {
                        resizeHandle(available: geo.size.width)
                        RightSidebar()
                            .frame(width: rightWidth(available: geo.size.width))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        // A visible window-toolbar background gives the tab bar a proper opaque
        // strip, so the system "+" button is centered in it rather than
        // floating (asymmetrically clipped) over the content.
        .toolbarBackground(.visible, for: .windowToolbar)
        // Native-style Back/Forward in the toolbar's leading navigation area
        // (like Finder/Safari), mirroring the ⌘[ / ⌘] commands.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // The native control Finder uses: a two-segment NSSegmentedControl.
                // Click steps once; press-and-hold shows history via a per-segment
                // menu (AppKit's built-in behavior). Matches the system look exactly.
                NavSegmentedControl(
                    backTitles: backTitles, forwardTitles: forwardTitles,
                    goBack: { nav.goBack(steps: $0) },
                    goForward: { nav.goForward(steps: $0) })
            }
        }
        .sheet(isPresented: $nav.searchPresented) {
            SearchPalette()
                .environmentObject(app)
                .environmentObject(nav)
        }
        .onAppear {
            // Restore the saved right-sidebar width fraction for this graph (§12).
            if rightFraction == nil, let saved = app.store.config.rightPaneFraction {
                rightFraction = CGFloat(saved)
            }
        }
    }

    /// Panel width: the saved fraction of the detail area (so it scales with the
    /// window — both panels shrink/grow proportionally), or ~40% capped until the
    /// user drags. Once the main view is down to its useable minimum, only the
    /// panel keeps shrinking (below its own preferred minimum; a small hard floor
    /// keeps it renderable).
    private func rightWidth(available: CGFloat) -> CGFloat {
        let desired = rightFraction.map { $0 * available }
            ?? min(max(available * 0.4, rightMinWidth), 520)
        let maxRight = max(120, available - mainMinWidth)
        return min(max(desired, rightMinWidth), maxRight)
    }

    /// A 1pt separator with an 8pt draggable hit area. Lives in the content
    /// area, so it never extends into the title/tab bar.
    private func resizeHandle(available: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        // Global coordinate space: translation is measured
                        // against the screen, not the handle — which itself
                        // moves as the panel resizes (local space oscillates).
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStartWidth ?? rightWidth(available: available)
                                if dragStartWidth == nil { dragStartWidth = base }
                                let maxRight = max(rightMinWidth, available - mainMinWidth)
                                // Dragging left (negative translation) grows the panel.
                                let width = min(max(base - value.translation.width,
                                                    rightMinWidth), maxRight)
                                // Store as a fraction of the current width, so
                                // later window resizes scale the panel with it.
                                rightFraction = available > 0 ? width / available : nil
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                app.persistRightPaneFraction(rightFraction)
                            }
                    )
            )
    }

    @ViewBuilder
    private var mainContent: some View {
        switch nav.current {
        case .journalHome:
            JournalView()
        case .page(let name, let zoom):
            PageScreen(pageName: name, zoom: zoom)
                .id("\(name)#\(zoom?.uuidString ?? "")")
        case .tag(let tag):
            TagViewScreen(tag: tag)
        case .allPages:
            AllPagesView()
        }
    }
}

/// The native Back/Forward control (as in Finder): a two-segment
/// `NSSegmentedControl`. A click steps once in that direction; press-and-hold
/// opens the history as a per-segment menu (AppKit shows it automatically). Each
/// segment is disabled when there's no history that way. `goBack`/`goForward`
/// take a step count (1 for a click, N for the Nth history entry).
private struct NavSegmentedControl: NSViewRepresentable {
    let backTitles: [String]
    let forwardTitles: [String]
    let goBack: (Int) -> Void
    let goForward: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.setImage(NSImage(systemSymbolName: "chevron.backward",
                                 accessibilityDescription: "Back"), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.forward",
                                 accessibilityDescription: "Forward"), forSegment: 1)
        control.setShowsMenuIndicator(false, forSegment: 0)
        control.setShowsMenuIndicator(false, forSegment: 1)
        control.target = context.coordinator
        control.action = #selector(Coordinator.clicked(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.setEnabled(!backTitles.isEmpty, forSegment: 0)
        control.setEnabled(!forwardTitles.isEmpty, forSegment: 1)
        // Per-segment menu → press-and-hold shows history (Finder behavior).
        control.setMenu(context.coordinator.historyMenu(backTitles, back: true), forSegment: 0)
        control.setMenu(context.coordinator.historyMenu(forwardTitles, back: false), forSegment: 1)
    }

    final class Coordinator: NSObject {
        var parent: NavSegmentedControl
        init(_ parent: NavSegmentedControl) { self.parent = parent }

        @objc func clicked(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0: parent.goBack(1)
            case 1: parent.goForward(1)
            default: break
            }
        }

        func historyMenu(_ titles: [String], back: Bool) -> NSMenu? {
            guard !titles.isEmpty else { return nil }
            let menu = NSMenu()
            for (i, title) in titles.prefix(15).enumerated() {
                let item = NSMenuItem(title: title,
                                      action: #selector(pickHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i + 1                 // steps
                item.representedObject = back
                menu.addItem(item)
            }
            return menu
        }

        @objc func pickHistory(_ sender: NSMenuItem) {
            let back = (sender.representedObject as? Bool) ?? true
            if back { parent.goBack(sender.tag) } else { parent.goForward(sender.tag) }
        }
    }
}
