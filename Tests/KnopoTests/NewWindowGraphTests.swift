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

    /// Without an active graph, use the environment or saved default.
    @Test func withNoWindowTheDefaultRootDecides() {
        #expect(GraphManager.rootForNewWindow(inheriting: nil) == GraphManager.defaultRoot())
    }

    @Test func defaultRootPrefersEnvironmentThenExistingSavedGraphThenDocuments() throws {
        let files = FileManager.default
        let suite = "knopo-new-window-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = files.temporaryDirectory
        defaults.set(saved.path, forKey: "lastGraphPath")

        let override = files.homeDirectoryForCurrentUser.appendingPathComponent("Override", isDirectory: true)
        #expect(GraphManager.defaultRoot(environmentPath: "~/Override", defaults: defaults) == override)
        #expect(GraphManager.defaultRoot(environmentPath: "", defaults: defaults) == saved)

        defaults.set(saved.appendingPathComponent(suite).path, forKey: "lastGraphPath")
        let fallback = try #require(files.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Knopo", isDirectory: true)
        #expect(GraphManager.defaultRoot(environmentPath: nil, defaults: defaults) == fallback)
    }
}
