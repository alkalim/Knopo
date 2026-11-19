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

    @Test func separateWindowRestoresItsOwnSizeAndPosition() async throws {
        let screen = try #require(NSScreen.main).visibleFrame
        let defaults = UserDefaults.standard
        let mainKey = WindowGeometry.mainFrameKey
        let separateKey = WindowGeometry.separateFrameKey
        let previousMain = defaults.string(forKey: mainKey)
        let previousSeparate = defaults.string(forKey: separateKey)
        defer {
            defaults.set(previousMain, forKey: mainKey)
            defaults.set(previousSeparate, forKey: separateKey)
        }
        defaults.set(NSStringFromRect(screen), forKey: mainKey)
        defaults.removeObject(forKey: separateKey)

        func openWindow(separately: Bool = true) -> NSWindow {
            let window = NSWindow(contentRect: screen, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: WindowGeometry(openedSeparately: separately))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        let first = openWindow()
        defer { first.orderOut(nil) }
        try await waitUntil { first.contentRect(forFrameRect: first.frame).size == NSSize(width: 900, height: 600) }
        let resized = NSRect(x: screen.minX + 20, y: screen.minY + 40, width: 960, height: 580)
        first.setFrame(resized, display: true)
        try await waitUntil { WindowGeometry.savedFrame(forKey: separateKey) == resized }

        let second = openWindow()
        defer { second.orderOut(nil) }
        try await waitUntil { second.frame == resized }
        #expect(first.tabbedWindows?.contains(second) != true)
        #expect(WindowGeometry.savedFrame() == screen)

        let tab = openWindow(separately: false)
        defer { tab.orderOut(nil) }
        second.addTabbedWindow(tab, ordered: .above)
        tab.makeKeyAndOrderFront(nil)
        let moved = resized.offsetBy(dx: 12, dy: 10)
        tab.setFrame(moved, display: true)
        try await waitUntil { WindowGeometry.savedFrame(forKey: separateKey) == moved }
        #expect(WindowGeometry.savedFrame() == screen)
    }
}
