import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarToggleTests {

    @Test(arguments: [false, true])
    func toggleRespectsPreferencesWithoutRepeatedPageReflow(usingMenu: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-toggle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        defaults.set(Preferences.Animations.on.rawValue, forKey: Preferences.animationsKey)
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Long page")
        page.blocks = (0..<200).map {
            Block(content: "Block \($0): " + String(repeating: "Words that wrap when the sidebar changes width. ", count: 4))
        }
        store.updatePage(page)
        let preferences = Preferences(defaults: defaults, syncsRenderer: false, reduceMotion: { true })
        let app = AppState(store: store, preferences: preferences)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.navigate(to: .page(name: page.name))
        let host = NSHostingView(rootView: MainWindow()
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Knopo Sidebar Toggle Test"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(window)
        let split = try #require(SidebarTransition.controller(in: host))
        let sidebar = try #require(split.splitViewItems.first)
        let detail = try #require(split.splitView.arrangedSubviews.last)
        let table = try #require(descendants(host).compactMap { $0 as? OutlineTableView }.first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        controller.focusBlock(page.blocks[0].id, selection: NSRange(location: 5, length: 3))
        defer { controller.endEditing() }
        try await settle(window)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        let attachment = try #require(descendants(host).compactMap {
            $0 as? SidebarTransition.WindowAttachment.AttachmentView
        }.first)
        let transition = try #require(attachment.state)
        var widths: [CGFloat] = []
        let widthDidChange = table.onWidthChange
        table.onWidthChange = { [weak table] in
            if let table { widths.append(table.frame.width) }
            widthDidChange?()
        }
        // The first toggle after loading the saved On preference must animate.
        for mode in [Preferences.Animations.on, .system, .off] {
            preferences.animations = mode
            for _ in 0..<2 {
                widths = []
                let wasCollapsed = sidebar.isCollapsed
                let windowFrame = window.frame
                let oldX = detail.frame.minX + detail.safeAreaInsets.left
                if usingMenu {
                    SidebarTransition.toggle(in: window, preferences: preferences)
                } else {
                    transition.visibility.wrappedValue = wasCollapsed ? .all : .detailOnly
                }
                #expect(sidebar.isCollapsed != wasCollapsed)
                let finalX = detail.frame.minX + detail.safeAreaInsets.left
                #expect(abs(finalX - oldX) > 100)
                #expect((detail.layer?.animation(forKey: SidebarTransition.animationKey) != nil) == (mode == .on))
                let snapshots = descendants(host).compactMap { $0 as? SidebarTransition.Snapshot }
                #expect(snapshots.count == (mode == .on && !wasCollapsed ? 1 : 0))
                if let snapshot = snapshots.first {
                    #expect(snapshot.fragments.count >= 2)
                    var textPixels = 0
                    for fragment in snapshot.fragments {
                        let bitmap = try #require(fragment.image.representations.first as? NSBitmapImageRep)
                        #expect(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 10)
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                   color.alphaComponent > 0.8,
                                   max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
                                    textPixels += 1
                                }
                            }
                        }
                    }
                    #expect(textPixels > 100, "The outgoing sidebar must contain its labels, not only a background")
                }
                try await settle(window)
                try await waitUntil {
                    detail.layer?.animation(forKey: SidebarTransition.animationKey) == nil
                        && descendants(host).allSatisfy { !($0 is SidebarTransition.Snapshot) }
                }
                #expect(detail.frame.minX + detail.safeAreaInsets.left == finalX)
                #expect(window.frame == windowFrame)
                #expect(widths.count <= 2, "A toggle should lay out the final width once: \(widths)")
                #expect(window.firstResponder === editor)
                #expect(editor.selectedRange() == NSRange(location: 5, length: 3))
                for index in 0..<table.numberOfRows {
                    #expect(abs(table.rect(ofRow: index).height
                        - controller.tableView(table, heightOfRow: index)) < 1)
                }
            }
        }

        preferences.animations = .on
        for _ in 0..<6 {
            let wasCollapsed = sidebar.isCollapsed
            SidebarTransition.toggle(in: window, preferences: preferences)
            #expect(sidebar.isCollapsed != wasCollapsed)
        }
        preferences.animations = .off
        let wasCollapsed = sidebar.isCollapsed
        SidebarTransition.toggle(in: window, preferences: preferences)
        #expect(sidebar.isCollapsed != wasCollapsed)
        #expect(detail.layer?.animation(forKey: SidebarTransition.animationKey) == nil)
        #expect(descendants(host).allSatisfy { !($0 is SidebarTransition.Snapshot) })
        try await settle(window)
        #expect(window.firstResponder === editor)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
