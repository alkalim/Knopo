import SwiftUI
import KnopoCore

/// Per-window/per-tab navigation state over the shared `AppState` graph model.
/// Each tab has its own current page, history, right-sidebar panes, and search
/// sheet, so tabs are independent views of one graph (SPEC §12).
@MainActor
final class Navigator: ObservableObject {
    /// The shared graph model (one per open graph, shared across all tabs).
    let app: AppState

    @Published var current: NavTarget = .journalHome
    @Published var rightPanes: [RightPane] = [] {
        didSet { if restored { app.persistRightPanes(rightPanes.map(\.encoded)) } }
    }
    @Published var searchPresented = false

    /// Page name whose first block the outline should focus once it loads — set
    /// right after creating a page so you can start typing immediately. The
    /// editor consumes (clears) it when it matches the page it just loaded.
    @Published var focusFirstBlock: String?

    /// The block an outline should scroll to and flash after it loads (set by
    /// clicking a query / backlink / tag result). The token bumps on each
    /// request so editors react and so each outline applies a given request once
    /// (it records the last token it handled) — no shared mutable clearing, so
    /// nothing is written to nav state during a SwiftUI view update.
    @Published private(set) var highlightToken = 0
    private(set) var highlightTarget: BlockHighlight?

    /// False during init (while restoring saved panes) so the restore itself
    /// doesn't re-persist; true thereafter so user changes are saved (§12).
    private var restored = false

    // In-page find (Cmd+F), scoped to the current page's outline.
    @Published var findActive = false
    @Published var findQuery = ""
    /// Reported back by the outline controller for the find bar's "n of m".
    @Published var findMatchCount = 0
    @Published var findOrdinal = 0           // 1-based current match, 0 = none
    /// Bumped to request a step; the controller reads `findStepForward`.
    @Published var findStepToken = 0
    private(set) var findStepForward = true

    /// Aggregates in-page find across every outline in this window (the
    /// journal home has several).
    let find = FindCoordinator()

    private var history = NavHistory()

    init(app: AppState) {
        self.app = app
        find.nav = self
        // Restore the right-sidebar panes saved for this graph (§12). Done after
        // stored-property init so `resolve` (which reads `app`) is available.
        rightPanes = app.store.config.rightPanes
            .compactMap(RightPane.init(encoded:))
            .compactMap { pane in resolve(pane.target).map { RightPane(target: $0, collapsed: pane.collapsed) } }
        restored = true
    }

    // MARK: - Navigation

    func navigate(to target: NavTarget, recordVisit: Bool = true) {
        guard let resolved = resolve(target) else { return }
        guard resolved != current else { return }
        app.flushPendingSaves()
        history.push(from: current)
        current = resolved
        closeFind() // find is per-page; navigating away dismisses it
        if recordVisit, let name = resolved.pageName {
            app.recordVisit(toPageNamed: name)
        }
    }

    /// Navigate to a just-created page and focus its (empty) first block so the
    /// user can type immediately.
    func navigateToNewPage(named name: String) {
        focusFirstBlock = name
        navigate(to: .page(name: name))
    }

    func openInRightSidebar(_ target: NavTarget) {
        guard let resolved = resolve(target) else { return }
        rightPanes.insert(RightPane(target: resolved), at: 0) // newest on top
    }

    /// Open the page holding a block (full page, in context — not zoomed) and
    /// request that the block be scrolled to and flashed. Used by every
    /// "result" surface (query, backlinks, tag view) so they behave alike.
    func navigateToBlock(pageName: String, blockID: UUID, content: String, inSidebar: Bool) {
        highlightTarget = BlockHighlight(
            pageKey: PageName.key(pageName), blockID: blockID, content: content)
        highlightToken += 1
        let target = NavTarget.page(name: pageName)
        inSidebar ? openInRightSidebar(target) : navigate(to: target)
    }

    func closeRightPane(at index: Int) {
        guard rightPanes.indices.contains(index) else { return }
        rightPanes.remove(at: index)
    }

    func closeAllRightPanes() { rightPanes.removeAll() }

    /// Closes every right-sidebar pane except the one at `index`.
    func closeOtherRightPanes(at index: Int) {
        guard rightPanes.indices.contains(index) else { return }
        rightPanes = [rightPanes[index]]
    }

    /// Collapse/expand a pane to its header (SPEC §12). Persisted.
    func toggleRightPaneCollapsed(at index: Int) {
        guard rightPanes.indices.contains(index) else { return }
        rightPanes[index].collapsed.toggle()
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Back/forward history entries, nearest first — for the toolbar buttons'
    /// click-and-hold menus (jump N steps).
    var backTitles: [String] { history.back.reversed().map(historyTitle) }
    var forwardTitles: [String] { history.forward.reversed().map(historyTitle) }

    func goBack(steps: Int = 1) {
        var target = current
        var moved = false
        for _ in 0..<max(1, steps) {
            guard let t = history.goBack(from: target) else { break }
            target = t; moved = true
        }
        if moved { current = target }
    }

    func goForward(steps: Int = 1) {
        var target = current
        var moved = false
        for _ in 0..<max(1, steps) {
            guard let t = history.goForward(from: target) else { break }
            target = t; moved = true
        }
        if moved { current = target }
    }

    private func historyTitle(_ target: NavTarget) -> String {
        switch target {
        case .page(let name, _): return pageDisplayTitle(name)
        case .tag(let tag): return "#\(tag)"
        case .journalHome: return "Journal"
        case .allPages: return "All Pages"
        }
    }

    /// Handles a click on any rendered link: internal targets navigate,
    /// external URLs open in the system browser (SPEC §5.1).
    func openURL(_ url: URL, inSidebar: Bool = false) {
        // A `…/page/<name>?block=<id>` link (query / backlink result): open the
        // page and flash the block, rather than zooming into it.
        if url.scheme == "knopo", url.host == "page",
           let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "block" }),
           let raw = item.value, let id = UUID(uuidString: raw) {
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let content = ((try? app.store.cache.locateBlock(id)) ?? nil)?.content ?? ""
            navigateToBlock(pageName: name, blockID: id, content: content, inSidebar: inSidebar)
            return
        }
        if let target = KnopoURL.decode(url) {
            inSidebar ? openInRightSidebar(target) : navigate(to: target)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - In-page find

    func openFind() {
        // Release a live block editor (an NSTextView first responder) so the
        // find field can take focus — otherwise the field appears but the caret
        // stays in the block. Committing that block's edit is expected: Cmd+F
        // moves you to the search field (Esc returns).
        NSApp.keyWindow?.makeFirstResponder(nil)
        findActive = true
    }

    func closeFind() {
        findActive = false
        findQuery = ""
        findMatchCount = 0
        findOrdinal = 0
    }

    func findNext() { findStepForward = true; findStepToken += 1 }
    func findPrevious() { findStepForward = false; findStepToken += 1 }

    /// Block targets arrive with an empty page name; resolve via the graph.
    private func resolve(_ target: NavTarget) -> NavTarget? {
        if case .page(let name, let zoom) = target, name.isEmpty, let zoom {
            guard let pageName = app.resolvePageName(forZoom: zoom) else { return nil }
            return .page(name: pageName, zoom: zoom)
        }
        return target
    }

    // MARK: - Page operations that affect this window's current target

    func renamePage(from old: String, to new: String) throws {
        try app.renamePage(from: old, to: new)
        if case .page(let name, let zoom) = current, PageName.key(name) == PageName.key(old) {
            current = .page(name: new, zoom: zoom)
        }
    }

    func deletePage(named name: String) throws {
        try app.deletePage(named: name)
        if current.pageName.map({ PageName.key($0) == PageName.key(name) }) == true {
            current = .journalHome
        }
        // Any pane showing the deleted page falls back to nothing.
        rightPanes.removeAll { $0.target.pageName.map { PageName.key($0) == PageName.key(name) } == true }
    }
}

/// Focused-window Navigator, so menu commands target the active tab (SPEC §12).
struct NavigatorFocusedKey: FocusedValueKey {
    typealias Value = Navigator
}

extension FocusedValues {
    var navigator: Navigator? {
        get { self[NavigatorFocusedKey.self] }
        set { self[NavigatorFocusedKey.self] = newValue }
    }
}
