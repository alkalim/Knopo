import SwiftUI
import EverseqCore

struct MainWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator

    /// User-set width of the right-sidebar panel. Nil until the divider is
    /// dragged — until then the panel uses a proportional default that adapts
    /// to window width (so it doesn't open uselessly narrow on a wide window).
    @State private var rightWidthManual: CGFloat?
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
            ToolbarItemGroup(placement: .navigation) {
                // Click = one step; press-and-hold = history menu (Finder-style).
                Menu {
                    ForEach(Array(backTitles.prefix(15).enumerated()), id: \.offset) { i, title in
                        Button(title) { nav.goBack(steps: i + 1) }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                } primaryAction: {
                    nav.goBack()
                }
                .menuIndicator(.hidden)
                .disabled(backTitles.isEmpty)
                .help("Back (⌘[) — hold for history")

                Menu {
                    ForEach(Array(forwardTitles.prefix(15).enumerated()), id: \.offset) { i, title in
                        Button(title) { nav.goForward(steps: i + 1) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                } primaryAction: {
                    nav.goForward()
                }
                .menuIndicator(.hidden)
                .disabled(forwardTitles.isEmpty)
                .help("Forward (⌘]) — hold for history")
            }
        }
        .sheet(isPresented: $nav.searchPresented) {
            SearchPalette()
                .environmentObject(app)
                .environmentObject(nav)
        }
        .onAppear {
            // Restore the saved right-sidebar width for this graph (§12).
            if rightWidthManual == nil, let saved = app.store.config.rightPaneWidth {
                rightWidthManual = CGFloat(saved)
            }
        }
    }

    /// Panel width: the user's dragged width, or ~40% of the detail area
    /// (capped) until they resize — clamped so the main view keeps its minimum.
    private func rightWidth(available: CGFloat) -> CGFloat {
        let maxRight = max(rightMinWidth, available - mainMinWidth)
        let proportionalDefault = min(max(available * 0.4, rightMinWidth), 520)
        let desired = rightWidthManual ?? proportionalDefault
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
                                rightWidthManual = min(max(base - value.translation.width,
                                                          rightMinWidth), maxRight)
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                app.persistRightPaneWidth(rightWidthManual)
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
