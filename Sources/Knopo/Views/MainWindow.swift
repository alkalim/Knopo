import SwiftUI
import KnopoCore

struct MainWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator

    /// User-set right-sidebar width as a fraction (0–1) of the detail area. Nil
    /// until the divider is dragged (or a saved fraction is restored) — until
    /// then a proportional default is used. Storing a fraction (not points)
    /// makes it scale with the window and restore correctly at any window size.
    @State private var rightFraction: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @GestureState private var isDraggingDivider = false
    @StateObject private var sidebarTransition = SidebarTransition.State()

    private let mainMinWidth: CGFloat = 320
    private let rightMinWidth: CGFloat = 280

    var body: some View {
        // Read the history into body-level values so the toolbar's menus rebuild
        // when they change — reading `nav.backTitles` *inside* the toolbar
        // closure isn't enough; SwiftUI doesn't re-run it on every nav change.
        let backTitles = nav.backTitles
        let forwardTitles = nav.forwardTitles
        // Keep the native source-list material and resizable divider.
        return NavigationSplitView(columnVisibility: sidebarTransition.visibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if nav.findActive {
                            VStack(spacing: 0) { FindBar(); Divider() }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        mainContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // The document area needs its own opaque surface: the
                            // editor's table/scroll views are clear, so otherwise
                            // it shows the window's grey (notably heavier on macOS
                            // 15 than 26). White in light mode; window grey in dark
                            // mode keeps the existing dark look. It stops at the
                            // toolbar, so the toolbar and tab bar keep one color.
                            .background(
                                Color(nsColor: .dynamic(
                                    light: .textBackgroundColor, dark: .windowBackgroundColor)),
                                ignoresSafeAreaEdges: [.horizontal, .bottom])
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(app.preferences.animationsEnabled ? .easeOut(duration: 0.18) : nil,
                               value: nav.findActive)
                    if !nav.rightPanes.isEmpty {
                        resizeHandle(available: geo.size.width)
                        RightSidebar()
                            .frame(width: rightWidth(available: geo.size.width))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .background(SidebarTransition.WindowAttachment(state: sidebarTransition,
                                                       preferences: app.preferences))
        // The system background frosts the toolbar and draws its bottom line.
        // It also gives the tab bar a strip with a centered "+" button.
        .toolbarBackground(.visible, for: .windowToolbar)
        // Native-style Back/Forward in the toolbar's leading navigation area
        // (like Finder/Safari), mirroring the ⌘[ / ⌘] commands.
        .toolbar {
            NavigationHistoryItems(
                backTitles: backTitles, forwardTitles: forwardTitles,
                goBack: { nav.goBack(steps: $0) },
                goForward: { nav.goForward(steps: $0) })
        }
        // The window title shows the graph name. Hiding it would also turn off
        // the toolbar's scroll edge effect and bottom line on macOS 26 and later.
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
                            .updating($isDraggingDivider) { _, dragging, _ in dragging = true }
                            .onChanged { value in
                                let base = dragStartWidth ?? rightWidth(available: available)
                                if dragStartWidth == nil {
                                    OutlineScrollAnchor.beginDividerResize(in: sidebarTransition.window)
                                    dragStartWidth = base
                                }
                                let maxRight = max(rightMinWidth, available - mainMinWidth)
                                // Dragging left (negative translation) grows the panel.
                                let width = min(max(base - value.translation.width,
                                                    rightMinWidth), maxRight)
                                // Store as a fraction of the current width, so
                                // later window resizes scale the panel with it.
                                rightFraction = available > 0 ? width / available : nil
                            }
                    )
            )
            .onChange(of: isDraggingDivider) { _, dragging in
                guard !dragging, dragStartWidth != nil else { return }
                dragStartWidth = nil
                OutlineScrollAnchor.endDividerResize(in: sidebarTransition.window)
                app.persistRightPaneFraction(rightFraction)
            }
            .onDisappear {
                dragStartWidth = nil
                OutlineScrollAnchor.endDividerResize(in: sidebarTransition.window)
            }
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

/// Back/Forward with a history menu on press-and-hold. On macOS 26 and later
/// the toolbar styles a navigation control group natively. Older systems draw
/// that group with small, tightly spaced chevrons. There each button gets its
/// own toolbar item, like in Finder and Safari.
private struct NavigationHistoryItems: ToolbarContent {
    let backTitles: [String]
    let forwardTitles: [String]
    let goBack: (Int) -> Void
    let goForward: (Int) -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    backMenu(icon: Image(systemName: "chevron.backward"))
                    forwardMenu(icon: Image(systemName: "chevron.forward"))
                }
                .controlGroupStyle(.navigation)
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
            }
        } else {
            ToolbarItem(placement: .navigation) {
                backMenu(icon: Self.backSymbol)
                    .menuIndicator(.hidden)
            }
            ToolbarItem(placement: .navigation) {
                forwardMenu(icon: Self.forwardSymbol)
                    .menuIndicator(.hidden)
            }
        }
    }

    // Built once. A new NSImage on every pass would make SwiftUI redraw the icons.
    private static let backSymbol = toolbarSymbol("chevron.backward")
    private static let forwardSymbol = toolbarSymbol("chevron.forward")

    /// AppKit toolbars before macOS 26 draw symbols at the large scale. SwiftUI
    /// toolbar items there use the medium scale unless the image carries its own.
    private static func toolbarSymbol(_ name: String) -> Image {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .large))
        return symbol.map { Image(nsImage: $0) } ?? Image(systemName: name)
    }

    private func backMenu(icon: Image) -> some View {
        Menu {
            historyItems(backTitles, navigate: goBack)
        } label: {
            Label { Text("Back") } icon: { icon }
        } primaryAction: {
            goBack(1)
        }
        .disabled(backTitles.isEmpty)
    }

    private func forwardMenu(icon: Image) -> some View {
        Menu {
            historyItems(forwardTitles, navigate: goForward)
        } label: {
            Label { Text("Forward") } icon: { icon }
        } primaryAction: {
            goForward(1)
        }
        .disabled(forwardTitles.isEmpty)
    }

    private func historyItems(_ titles: [String], navigate: @escaping (Int) -> Void) -> some View {
        ForEach(Array(titles.prefix(15).enumerated()), id: \.offset) { index, title in
            Button { navigate(index + 1) } label: { Text(verbatim: title) }
        }
    }
}
