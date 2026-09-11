import AppKit
import SwiftUI
import Testing
@testable import Knopo

/// The graph name is a toolbar item. A second copy of it, or the app's name,
/// drawn beside it in the title bar is a bug.
@MainActor
@Suite struct WindowTitleTests {

    /// The configurator, hosted as the window hosts it, after its setup runs.
    private func configuredWindow(graphName: String) async throws -> NSWindow {
        let host = NSHostingView(rootView: WindowConfigurator(
            onActivate: {}, graphName: graphName, pageTitle: "Journal"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        return window
    }

    @Test func windowIsTitledAfterItsGraphAndHidesIt() async throws {
        let window = try await configuredWindow(graphName: "Summit 2026")
        #expect(window.title == "Summit 2026")
        #expect(window.titleVisibility == .hidden)
    }

    /// The stuck path: the title comes back with no SwiftUI update behind it,
    /// so nothing corrected it until a page switch caused one.
    @Test func titleGoesBackDownWithNoFurtherUpdate() async throws {
        let window = try await configuredWindow(graphName: "Summit 2026")
        window.title = "Knopo"
        window.titleVisibility = .visible
        // No SwiftUI update follows: nothing about the view has changed.
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.titleVisibility == .hidden)
    }
}
