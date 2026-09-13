import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

/// `⌃⌘S` sends `toggleSidebar:` up the responder chain instead of reading a
/// focused value: the outline editor holds first responder most of the time.
/// This pins that the chain still answers from there.
@MainActor
@Suite struct SidebarToggleTests {

    @Test func theResponderChainAnswersToggleSidebar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-toggle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: MainWindow(graphName: "G", openGraphSettings: {})
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        // The journal opens ready to write, so this starts where the user does.
        #expect(window.firstResponder is BlockEditorTextView)

        let toggle = #selector(NSSplitViewController.toggleSidebar(_:))
        var responder: NSResponder? = window.firstResponder
        var answered = false
        while let current = responder, !answered {
            answered = current.responds(to: toggle)
            responder = current.nextResponder
        }
        #expect(answered)
    }
}
