import AppKit
import SwiftUI
import Testing
@testable import Knopo

/// The window title shows the graph name. The app's name in its place is a bug.
@MainActor
@Suite struct WindowTitleTests {

    @Test func windowIsTitledAfterItsGraph() async throws {
        let host = NSHostingView(rootView: WindowConfigurator(
            onActivate: {}, graphName: "Summit 2026", pageTitle: "Journal"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        try await waitUntil {
            window.layoutIfNeeded()
            return window.title == "Summit 2026"
        }
        #expect(window.title == "Summit 2026")
    }
}
