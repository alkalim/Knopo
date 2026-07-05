import SwiftUI
import EverseqCore

/// Owns every open graph for the process. Each window points at one graph; a
/// graph's `AppState` (store, index, undo) is created once and shared by all
/// windows showing that same folder — so two windows on one graph never
/// double-open its store, while different windows can show different graphs.
@MainActor
final class GraphManager: ObservableObject {
    private var apps: [String: AppState] = [:]   // canonical root path → graph

    private static let lastGraphKey = "lastGraphPath"

    /// The shared `AppState` for a graph root, opening + seeding it on first use.
    /// Kept for the process lifetime (a handful of graphs); reopening one is
    /// instant and a still-open window keeps it alive regardless.
    func acquire(_ root: URL) throws -> AppState {
        let key = root.standardizedFileURL.path
        if let existing = apps[key] { return existing }
        let app = AppState(store: try Self.openStore(at: root))
        apps[key] = app
        return app
    }

    /// `acquire` for the initial window, which has no graph to fall back to.
    func acquireOrFatal(_ root: URL) -> AppState {
        do { return try acquire(root) }
        catch { fatalError("Cannot open graph at \(root.path): \(error)") }
    }

    func rememberLast(_ root: URL) {
        UserDefaults.standard.set(root.path, forKey: Self.lastGraphKey)
    }

    /// File → Open Graph…: pick (or create) a directory; any directory works —
    /// `GraphStore` lays out pages/, journals/ and .everseq/ on first open.
    /// Returns nil if cancelled.
    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a graph folder (or create a new one). It will hold your pages as Markdown files."
        panel.prompt = "Open Graph"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func openStore(at root: URL) throws -> GraphStore {
        let store = try GraphStore(root: root)
        seedIfEmpty(store)
        return store
    }

    /// EVERSEQ_GRAPH env var wins; then the last graph opened from the app;
    /// then ~/Documents/Everseq.
    static func defaultRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment["EVERSEQ_GRAPH"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: lastGraphKey),
           FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everseq", isDirectory: true)
    }

    private static func seedIfEmpty(_ store: GraphStore) {
        guard (try? store.cache.allPages())?.isEmpty ?? false else { return }
        var welcome = store.page(named: "Welcome to Everseq")
        welcome.blocks = PageParser.parse("""
        - **Everseq** is a local-first outliner: everything is a block, pages are trees of blocks.
        - Your notes live as plain Markdown files in `pages/` and `journals/` — nothing is held hostage.
        - Try the basics:
          - Type `[[` to link to a page — like [[Ideas]] (links to pages that don't exist yet create *stubs*).
          - Type `((` to search blocks and insert a durable `((block-id))` reference.
          - Use embeds to show read-only content in place: `{{embed [[Page]]}}` embeds a page, `{{embed ((block-id))}}` embeds a block subtree.
          - Type `/` at a word start for slash commands like `/today`, `/link`, `/code-block`, `/page-embed`, and `/block-embed`.
          - Type `#` to add a tag, like #getting-started.
          - `Enter` makes a new block, `Tab` indents, `Shift+Tab` outdents.
          - Click a bullet to zoom into a block; click the triangle to fold.
        - The journal is your home: one page per day, today on top.
        - Press `⌘K` to search everything.
        """).blocks
        store.updatePage(welcome)
        try? store.savePage(named: "Welcome to Everseq")
    }
}

/// One window's current graph: which root it shows and the shared `AppState`
/// for it. Switching (Open Graph…) repoints just this window; other windows
/// keep their own graph.
@MainActor
final class GraphHandle: ObservableObject {
    private let manager: GraphManager
    @Published private(set) var app: AppState
    @Published private(set) var root: URL

    init(manager: GraphManager) {
        self.manager = manager
        let root = GraphManager.defaultRoot()
        self.root = root
        self.app = manager.acquireOrFatal(root)
    }

    func openGraph() {
        guard let url = GraphManager.runOpenPanel() else { return }
        do {
            app = try manager.acquire(url)
            root = url
            manager.rememberLast(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The focused window's graph, surfaced to menu commands so File/Edit/View
/// actions target the active window rather than a single global graph.
struct GraphActions {
    let app: AppState
    let openGraph: () -> Void
}

struct GraphActionsFocusedKey: FocusedValueKey {
    typealias Value = GraphActions
}

extension FocusedValues {
    var graphActions: GraphActions? {
        get { self[GraphActionsFocusedKey.self] }
        set { self[GraphActionsFocusedKey.self] = newValue }
    }
}

@main
struct EverseqApp: App {
    @StateObject private var manager = GraphManager()

    init() {
        // SPM executables aren't app bundles; make us a regular GUI app.
        // The app icon comes from the bundle (see scripts/build-app.sh) so the
        // OS can theme it ("Icon & widget style" on macOS 26); we deliberately
        // do NOT override `applicationIconImage` at runtime, which would defeat
        // that theming.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // Each window owns its own graph (a `GraphHandle`); a new window opens
        // the last-used graph, and Open Graph… switches only that window.
        WindowGroup("Everseq") {
            WindowRoot(manager: manager)
                .frame(minWidth: 900, minHeight: 560)
        }
        // Open at the remembered size so the window doesn't flash a default
        // size and then resize to the restored frame. (Position is still
        // restored by WindowConfigurator.)
        .defaultSize(WindowConfigurator.savedFrame()?.size ?? CGSize(width: 1100, height: 720))
        .commands {
            // All graph-scoped actions target whichever window is focused.
            GraphCommands()
            NavigationCommands()
        }
    }
}

/// File/Edit/View actions that act on a graph, routed to the focused window's
/// graph via `\.graphActions` (so two windows on different graphs each get
/// their own undo, zoom, etc.).
private struct GraphCommands: Commands {
    @FocusedValue(\.graphActions) private var graph: GraphActions?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // SwiftUI's WindowGroup has no New Tab command. Create a new scene
            // via the window controller, then explicitly tab it into the current
            // window (the explicit `addTabbedWindow` is what makes it a tab
            // rather than a detached window).
            Button("New Tab") {
                guard let current = NSApp.keyWindow,
                      let controller = current.windowController else { return }
                controller.newWindowForTab(nil)
                if let added = NSApp.keyWindow, added != current {
                    current.addTabbedWindow(added, ordered: .above)
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Open Graph…") { graph?.openGraph() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(graph == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { graph?.app.undo() }
                .keyboardShortcut("z").disabled(graph == nil)
            Button("Redo") { graph?.app.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(graph == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Brackets Around Page Links", isOn: Binding(
                get: { graph?.app.showPageRefBrackets ?? false },
                set: { graph?.app.showPageRefBrackets = $0 }
            ))
            .disabled(graph == nil)
            Divider()
            Button("Zoom In") { graph?.app.adjustZoom(by: 0.1) }
                .keyboardShortcut("+", modifiers: .command).disabled(graph == nil)
            Button("Zoom Out") { graph?.app.adjustZoom(by: -0.1) }
                .keyboardShortcut("-", modifiers: .command).disabled(graph == nil)
            Button("Actual Size") { graph?.app.resetZoom() }
                .keyboardShortcut("0", modifiers: .command).disabled(graph == nil)
            Divider()
            // Text density: scales line spacing within and between blocks in
            // 10% steps (independent of font zoom).
            Button("Increase Line Spacing") { graph?.app.adjustDensity(by: 0.1) }
                .keyboardShortcut("=", modifiers: [.command, .control]).disabled(graph == nil)
            Button("Decrease Line Spacing") { graph?.app.adjustDensity(by: -0.1) }
                .keyboardShortcut("-", modifiers: [.command, .control]).disabled(graph == nil)
            Button("Reset Line Spacing") { graph?.app.resetDensity() }
                .keyboardShortcut("0", modifiers: [.command, .control]).disabled(graph == nil)
            Divider()
            Button("Clear Recents") {
                guard let app = graph?.app else { return }
                try? app.store.cache.clearRecents()
                app.dataVersion += 1
            }
            .disabled(graph == nil)
        }
    }
}

/// One window. Owns the window's `GraphHandle` (its current graph); rebuilds the
/// inner view when the window switches graphs, so the Navigator re-binds.
private struct WindowRoot: View {
    @StateObject private var handle: GraphHandle

    init(manager: GraphManager) {
        _handle = StateObject(wrappedValue: GraphHandle(manager: manager))
    }

    var body: some View {
        GraphView(app: handle.app, openGraph: handle.openGraph)
            .id(ObjectIdentifier(handle.app))
    }
}

/// The view of a single graph in a window: its own `Navigator`, published as the
/// focused-scene value (along with `graphActions`) for menu commands.
private struct GraphView: View {
    @ObservedObject var app: AppState
    let openGraph: () -> Void
    @StateObject private var nav: Navigator

    init(app: AppState, openGraph: @escaping () -> Void) {
        self.app = app
        self.openGraph = openGraph
        _nav = StateObject(wrappedValue: Navigator(app: app))
    }

    var body: some View {
        MainWindow()
            .environmentObject(app)
            .environmentObject(nav)
            .preferredColorScheme(colorScheme)
            .focusedSceneValue(\.navigator, nav)
            .focusedSceneValue(\.graphActions, GraphActions(app: app, openGraph: openGraph))
            // Title bar shows the graph; the per-tab label shows the page
            // (set on the window's tab independently — see WindowConfigurator).
            .navigationTitle(app.store.root.lastPathComponent)
            .background(WindowConfigurator(
                graphName: app.store.root.lastPathComponent, pageTitle: currentTitle))
    }

    private var colorScheme: ColorScheme? {
        switch app.store.config.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// The current page/section — used as the window tab's label.
    private var currentTitle: String {
        switch nav.current {
        case .journalHome: return "Journal"
        case .allPages: return "All Pages"
        case .tag(let tag): return "#\(tag)"
        case .page(let name, _): return app.document(for: name).displayTitle
        }
    }
}

/// Reaches the hosting NSWindow to (a) persist its frame across launches and
/// (b) label the window's *tab* with the current page, while the title bar
/// keeps the graph name (`navigationTitle`).
///
/// We persist the frame ourselves under a stable key rather than relying on
/// SwiftUI's automatic autosave: that key is derived from the (private, nested)
/// `RootView`'s mangled type name, which embeds a per-launch pointer — so it
/// changes every launch and never restores.
/// An `NSView` that reports when it's added to a window — the earliest hook to
/// position the window before its first display (avoiding a reposition flash).
private final class WindowHookView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let graphName: String   // == window.title (set by navigationTitle)
    let pageTitle: String
    private static let frameKey = "EverseqMainWindowFrame"
    /// Posted when a window's graph/page changes or a window closes, so every
    /// tab re-decides whether to graph-qualify its title.
    private static let windowsChanged = Notification.Name("everseqWindowsChanged")

    /// The last saved window frame, if present, valid, and on an attached
    /// screen. Used both to restore the frame and to seed the WindowGroup's
    /// default size so the window opens at the remembered size (no resize flash).
    static func savedFrame() -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(saved)
        guard rect.width >= 200, rect.height >= 200,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) })
        else { return nil }
        return rect
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var configured = false
        var observers: [NSObjectProtocol] = []
        weak var window: NSWindow?
        var graphName = ""
        var pageTitle = ""
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// The tab label is just the page — unless this window's tab group mixes
        /// graphs, in which case prepend the graph name so tabs from different
        /// graphs ("Journal | Journal") are distinguishable. Sibling graphs are
        /// read from each window's title (set by `navigationTitle`).
        func refreshTabTitle() {
            guard let window else { return }
            let siblings = window.tabGroup?.windows ?? [window]
            // Read the graph name live from the window title (set by
            // navigationTitle) rather than the captured `graphName`: on a graph
            // switch this coordinator may be a lingering stale one, but the
            // window itself is stable and already carries the current graph.
            let graph = window.title
            let mixed = Set(siblings.map(\.title)).count > 1
            window.tab.title = mixed ? "\(graph) — \(pageTitle)" : pageTitle
        }
    }

    func makeNSView(context: Context) -> NSView {
        // Restore the frame the moment the view enters its window — before the
        // window is first displayed — so the saved position is set without a
        // visible reposition. `updateNSView`'s deferred configure is a fallback.
        let view = WindowHookView()
        let coordinator = context.coordinator
        view.onWindow = { [self] window in configure(window, coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        let changed = c.graphName != graphName || c.pageTitle != pageTitle
        c.graphName = graphName
        c.pageTitle = pageTitle
        // Defer so it runs after SwiftUI applies navigationTitle (which sets the
        // window title we read to detect mixed-graph tab groups, and would
        // otherwise reset the tab label).
        DispatchQueue.main.async {
            configure(nsView.window, c)
            c.refreshTabTitle()
            // Our change may flip a sibling tab's mixed state too.
            if changed { NotificationCenter.default.post(name: Self.windowsChanged, object: nil) }
        }
    }

    /// One-time per window: restore the saved frame and start saving changes.
    /// Runs after SwiftUI has applied its (non-restoring) default size, so our
    /// `setFrame` wins and sticks.
    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, !coordinator.configured else { return }
        coordinator.configured = true
        coordinator.window = window
        window.minSize = NSSize(width: 900, height: 560)
        // Native tabs: new scenes merge into one tab group, so `Cmd+T` ("New
        // Tab") works and tabs are available regardless of the system "prefer
        // tabs" setting. Each tab is its own scene/graph; detach a window via
        // Window → Move Tab to New Window.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "everseq"
        if let rect = Self.savedFrame() {
            window.setFrame(rect, display: true)
        }
        let save: (Notification) -> Void = { _ in
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        }
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main, using: save))
        }
        // Re-qualify our title when any window changes graph/page…
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: Self.windowsChanged, object: nil, queue: .main) { [weak coordinator] _ in
                coordinator?.refreshTabTitle()
            })
        // …and when a tab closes (the group may no longer be mixed).
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                NotificationCenter.default.post(name: Self.windowsChanged, object: nil)
            })
        // Moving a tab out to its own window (drag or "Move Tab to New Window")
        // has no tab-group-changed notification, but it does make a window key —
        // so re-evaluate on any key change to drop a now-stale prefix.
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak coordinator] _ in
                coordinator?.refreshTabTitle()
            })
    }
}

/// Back/Forward/Search/Today, routed to whichever window is focused.
private struct NavigationCommands: Commands {
    @FocusedValue(\.navigator) private var nav: Navigator?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Back") { nav?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(nav == nil)
            Button("Forward") { nav?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(nav == nil)
            Divider()
            Button("Today's Journal") { nav?.navigate(to: .journalHome) }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(nav == nil)
            Button("Search") { nav?.searchPresented = true }
                .keyboardShortcut("k")
                .disabled(nav == nil)
            Divider()
            Button("Find in Page") { nav?.openFind() }
                .keyboardShortcut("f")
                .disabled(nav == nil)
            Button("Find Next") { nav?.findNext() }
                .keyboardShortcut("g")
                .disabled(nav?.findActive != true)
            Button("Find Previous") { nav?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(nav?.findActive != true)
            Divider()
            Button("Close All Right Panes") { nav?.closeAllRightPanes() }
                .disabled(nav?.rightPanes.isEmpty ?? true)
        }
    }
}
