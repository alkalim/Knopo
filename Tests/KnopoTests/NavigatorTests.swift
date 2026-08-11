import Foundation
import Testing
@testable import Knopo
import KnopoCore

@Suite struct NavigatorTests {

    /// `⌘J` is "take me to today" — every press, not a toggle. It lands on the feed
    /// and asks for the caret in today from wherever you were, and each press is a
    /// fresh request: the token has to bump, or an outline whose SwiftUI view is
    /// otherwise unchanged is never asked to present again and the press does
    /// nothing at all.
    @MainActor
    @Test func journalShortcutAlwaysAsksForTodaysWritingBlock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-nav-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let today = JournalDate.today().pageName

        // Somewhere else → the feed, caret asked for in today.
        nav.navigate(to: .allPages)
        nav.goToJournal()
        #expect(nav.current == .journalHome)
        #expect(nav.focusWritingIn == today)
        let firstToken = nav.focusWritingToken

        // Already on the feed → stay, and ask again with a new token (the caret may
        // be in another day, as it is when this is pressed from the feed at all).
        nav.focusWritingIn = nil             // as the outline does on consuming it
        nav.goToJournal()
        #expect(nav.current == .journalHome)
        #expect(nav.focusWritingIn == today)
        #expect(nav.focusWritingToken > firstToken)

        // Pressing it repeatedly never navigates away, and every press is a request.
        let beforeRepeats = nav.focusWritingToken
        nav.goToJournal()
        nav.goToJournal()
        #expect(nav.current == .journalHome)
        #expect(nav.focusWritingIn == today)
        #expect(nav.focusWritingToken == beforeRepeats + 2)

        // From today's own page it still takes you to the journal.
        nav.navigate(to: .page(name: today))
        nav.goToJournal()
        #expect(nav.current == .journalHome)
        #expect(nav.focusWritingIn == today)
    }
    @MainActor
    @Test func allPagesCollapseStatePersistsPerGraph() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-all-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        try store.updateConfig {
            $0.allPagesCollapsedSections = ["journal"]
        }
        let app = AppState(store: store)
        defer { app.shutdown() }

        #expect(app.allPagesCollapsedSections == ["journal"])
        app.toggleAllPagesSection("pages")
        app.toggleAllPagesSection("journal")

        #expect(app.allPagesCollapsedSections == ["pages"])
        #expect(store.config.allPagesCollapsedSections == ["pages"])
        #expect(
            GraphConfig.load(from: store.configURL).allPagesCollapsedSections
                == ["pages"]
        )
    }

    /// A query/backlink result row links as `knopo://page/<name>?block=<id>`, and
    /// a namespaced name percent-encodes its `/`. Decoding that name back with
    /// `lastPathComponent` kept only the trailing part, so clicking the row opened
    /// a stub ("Knopo") instead of the real page ("Projects/Knopo").
    @MainActor
    @Test func openingAResultRowKeepsTheNamespaceInThePageName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-nav-namespace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Projects/Knopo")
        page.blocks[0].content = "a namespaced hit"
        store.updatePage(page)
        try store.savePage(named: page.name)

        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let blockID = page.blocks[0].id

        // Take the URL back out of an `.link` attribute, as a click does: after
        // that NSURL round-trip `url.lastPathComponent` answers "Knopo", so a
        // URL built inline would not reproduce the bug.
        func asClicked(_ url: URL) -> URL {
            let s = NSAttributedString(string: "row", attributes: [.link: url])
            return s.attribute(.link, at: 0, effectiveRange: nil) as! URL
        }

        nav.openURL(asClicked(KnopoURL.block(blockID, onPage: "Projects/Knopo")))

        #expect(nav.current == .page(name: "Projects/Knopo"))
        #expect(nav.highlightTarget?.pageKey == PageName.key("Projects/Knopo"))

        // The page header above the rows (a plain page link) must agree.
        nav.openURL(asClicked(KnopoURL.page("Projects/Knopo")))
        #expect(nav.current == .page(name: "Projects/Knopo"))

        // And in the right sidebar, which takes the same path.
        nav.openURL(asClicked(KnopoURL.block(blockID, onPage: "Projects/Knopo")), inSidebar: true)
        #expect(nav.rightPanes.map(\.target) == [.page(name: "Projects/Knopo")])

        // The hover-preview lookup reads the same link attribute.
        #expect(KnopoURL.pageName(from: asClicked(KnopoURL.page("Projects/Knopo")))
            == "Projects/Knopo")
    }

    /// Shift/Cmd+Clicking the same reference twice used to stack a second
    /// identical card (two editors over one document). Re-opening now promotes
    /// the pane that's already there.
    @MainActor
    @Test func reopeningATargetPromotesItsPaneInsteadOfDuplicating() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-panes-dedup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        let page = try store.createPage(named: "Alpha")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)

        nav.openInRightSidebar(.page(name: "Alpha"))
        nav.openInRightSidebar(.page(name: "Beta"))
        #expect(nav.rightPanes.map(\.target) == [.page(name: "Beta"), .page(name: "Alpha")])

        // Same page again — differently cased, as a `[[alpha]]` ref would be.
        nav.rightPanes[1].collapsed = true
        nav.openInRightSidebar(.page(name: "alpha"))
        #expect(nav.rightPanes.count == 2)
        #expect(nav.rightPanes[0].target == .page(name: "Alpha"))  // stored casing kept
        #expect(!nav.rightPanes[0].collapsed)                      // and revealed
        #expect(nav.rightPanes[1].target == .page(name: "Beta"))

        // A zoom is a different view of the page, so it gets its own pane.
        nav.openInRightSidebar(.page(name: "Alpha", zoom: page.blocks[0].id))
        #expect(nav.rightPanes.count == 3)

        // Tags dedup case-insensitively too (§8).
        nav.openInRightSidebar(.tag("todo"))
        nav.openInRightSidebar(.tag("TODO"))
        #expect(nav.rightPanes.count == 4)
        #expect(nav.rightPanes[0].target == .tag("todo"))
    }

    /// Duplicates persisted by earlier builds collapse to one pane on restore.
    @MainActor
    @Test func restoringPanesDropsDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-panes-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        try store.updateConfig {
            $0.rightPanes = [
                RightPane(target: .page(name: "Alpha"), collapsed: true).encoded,
                RightPane(target: .page(name: "alpha")).encoded,
                RightPane(target: .tag("todo")).encoded,
                RightPane(target: .page(name: "Beta")).encoded,
                RightPane(target: .tag("Todo")).encoded,
            ]
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)

        // First occurrence wins, order and collapse state preserved.
        #expect(nav.rightPanes.map(\.target)
            == [.page(name: "Alpha"), .tag("todo"), .page(name: "Beta")])
        #expect(nav.rightPanes[0].collapsed)
    }

    /// `GraphStore.renamePage` rejects a target name only when a file sits behind
    /// it, so renaming onto a *stub* (referenced but never written) succeeds — and
    /// a pane already open on that stub then names the same page as the renamed
    /// one. The two must fold into a single pane.
    @MainActor
    @Test func renamingOntoAnOpenStubDoesNotDuplicateItsPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-rename-stub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        var foo = try store.createPage(named: "Foo")
        foo.blocks[0].content = "points at [[Bar]]"   // Bar becomes a stub
        store.updatePage(foo)
        try store.savePage(named: foo.name)

        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = [
            RightPane(target: .page(name: "Foo")),
            RightPane(target: .page(name: "Bar"), collapsed: true),
            RightPane(target: .page(name: "Other")),
        ]

        try nav.renamePage(from: "Foo", to: "Bar")

        #expect(nav.rightPanes.map(\.target) == [.page(name: "Bar"), .page(name: "Other")])
        #expect(!nav.rightPanes[0].collapsed)   // the renamed pane came first, expanded
    }

    /// The same rename onto a page that *does* have a file is refused outright,
    /// so no pane is touched.
    @MainActor
    @Test func renamingOntoARealPageIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-rename-clash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        for (name, text) in [("Foo", "FOO"), ("Bar", "BAR")] {
            var p = try store.createPage(named: name)
            p.blocks[0].content = text
            store.updatePage(p)
            try store.savePage(named: p.name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = [RightPane(target: .page(name: "Foo")), RightPane(target: .page(name: "Bar"))]

        #expect(throws: (any Error).self) { try nav.renamePage(from: "Foo", to: "Bar") }
        #expect(nav.rightPanes.map(\.target) == [.page(name: "Foo"), .page(name: "Bar")])
        #expect(store.page(named: "Bar").blocks.map(\.content) == ["BAR"])   // not clobbered
    }

    @MainActor
    @Test func renamePageUpdatesRightSidebarTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-navigator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Old Name")
        page.blocks[0].content = "Kept content"
        store.updatePage(page)
        try store.savePage(named: page.name)

        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let zoom = page.blocks[0].id
        nav.rightPanes = [
            RightPane(target: .page(name: "Old Name", zoom: zoom), collapsed: true),
            RightPane(target: .page(name: "old name")),
            RightPane(target: .page(name: "Other Page")),
        ]

        try nav.renamePage(from: "Old Name", to: "New Name")

        #expect(nav.rightPanes.count == 3)
        #expect(nav.rightPanes[0].target == .page(name: "New Name", zoom: zoom))
        #expect(nav.rightPanes[0].collapsed)
        #expect(nav.rightPanes[1].target == .page(name: "New Name"))
        #expect(nav.rightPanes[2].target == .page(name: "Other Page"))
        #expect(app.document(for: "New Name").blocks.map(\.content) == ["Kept content"])
    }
}
