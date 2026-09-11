import Foundation
import Testing
@testable import Knopo

/// Which graph a new window or tab opens (SPEC §12).
@MainActor
@Suite struct NewWindowGraphTests {

    @Test func aNewWindowInheritsTheActiveGraph() {
        let active = URL(fileURLWithPath: "/tmp/knopo-active", isDirectory: true)
        #expect(GraphManager.rootForNewWindow(inheriting: active) == active)
    }

    /// At launch there is nothing to inherit from, so the stored default wins.
    @Test func withNoWindowTheStoredDefaultDecides() {
        #expect(GraphManager.rootForNewWindow(inheriting: nil) == GraphManager.defaultRoot())
    }
}
