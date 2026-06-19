import SwiftUI
import EverseqCore

/// Owns the active graph and supports switching to another one at runtime
/// (File → Open Graph…). Replacing `app` republishes through SwiftUI and the
/// window rebuilds against the new store.
@MainActor
final class GraphSession: ObservableObject {
    @Published private(set) var app: AppState

    private static let lastGraphKey = "lastGraphPath"

    init() {
        let root = Self.initialRoot()
        do {
            self.app = AppState(store: try Self.openStore(at: root))
        } catch {
            fatalError("Cannot open graph at \(root.path): \(error)")
        }
    }

    /// Opens (or initializes) the graph at `root` and switches to it.
    func switchGraph(to root: URL) {
        do {
            let store = try Self.openStore(at: root)
            app.shutdown()
            app = AppState(store: store)
            UserDefaults.standard.set(root.path, forKey: Self.lastGraphKey)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// File → Open Graph…: pick (or create) a directory; any directory works —
    /// `GraphStore` lays out pages/, journals/ and .everseq/ on first open.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a graph folder (or create a new one). It will hold your pages as Markdown files."
        panel.prompt = "Open Graph"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchGraph(to: url)
    }

    private static func openStore(at root: URL) throws -> GraphStore {
        let store = try GraphStore(root: root)
        seedIfEmpty(store)
        return store
    }

    /// EVERSEQ_GRAPH env var wins; then the last graph opened from the app;
    /// then ~/Documents/Everseq.
    private static func initialRoot() -> URL {
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

@main
struct EverseqApp: App {
    @StateObject private var session = GraphSession()

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
        let app = session.app
        // Each window/tab gets its own RootView → its own Navigator, all
        // sharing this graph's `app`. `.id` rebuilds on graph switch.
        WindowGroup("Everseq") {
            RootView(app: app)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 900, minHeight: 560)
                .id(ObjectIdentifier(app))
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Graph…") { session.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.undo() }.keyboardShortcut("z")
                Button("Redo") { app.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Navigation commands target the focused window's Navigator.
            NavigationCommands()
            CommandGroup(after: .toolbar) {
                Toggle("Show Brackets Around Page Links", isOn: Binding(
                    get: { app.showPageRefBrackets },
                    set: { app.showPageRefBrackets = $0 }
                ))
                Divider()
                Button("Zoom In") { app.adjustZoom(by: 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { app.adjustZoom(by: -0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { app.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                // Text density: scales line spacing within and between blocks in
                // 10% steps (independent of font zoom).
                Button("Increase Line Spacing") { app.adjustDensity(by: 0.1) }
                    .keyboardShortcut("=", modifiers: [.command, .control])
                Button("Decrease Line Spacing") { app.adjustDensity(by: -0.1) }
                    .keyboardShortcut("-", modifiers: [.command, .control])
                Button("Reset Line Spacing") { app.resetDensity() }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                Divider()
                Button("Clear Recents") {
                    try? app.store.cache.clearRecents()
                    app.dataVersion += 1
                }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch session.app.store.config.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// One window/tab: owns a `Navigator` bound to the shared graph `app`, and
/// publishes it as the focused-scene value for menu commands.
private struct RootView: View {
    @ObservedObject var app: AppState
    @StateObject private var nav: Navigator

    init(app: AppState) {
        self.app = app
        _nav = StateObject(wrappedValue: Navigator(app: app))
    }

    var body: some View {
        MainWindow()
            .environmentObject(app)
            .environmentObject(nav)
            .focusedSceneValue(\.navigator, nav)
            // Title bar shows the graph; the per-tab label shows the page
            // (set on the window's tab independently — see WindowConfigurator).
            .navigationTitle(app.store.root.lastPathComponent)
            .background(WindowConfigurator(tabTitle: currentTitle))
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
private struct WindowConfigurator: NSViewRepresentable {
    let tabTitle: String
    private static let frameKey = "EverseqMainWindowFrame"

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var configured = false
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = tabTitle
        // Defer so it runs after SwiftUI applies navigationTitle (which would
        // otherwise reset the tab label to the window title).
        DispatchQueue.main.async {
            configure(nsView.window, context.coordinator)
            nsView.window?.tab.title = title
        }
    }

    /// One-time per window: restore the saved frame and start saving changes.
    /// Runs after SwiftUI has applied its (non-restoring) default size, so our
    /// `setFrame` wins and sticks.
    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, !coordinator.configured else { return }
        coordinator.configured = true
        window.minSize = NSSize(width: 900, height: 560)
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let rect = NSRectFromString(saved)
            // Ignore junk / off-screen frames (e.g. an unplugged display).
            if rect.width >= 200, rect.height >= 200,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(rect, display: true)
            }
        }
        let save: (Notification) -> Void = { _ in
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        }
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main, using: save))
        }
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
