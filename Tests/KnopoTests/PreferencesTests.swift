import Foundation
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite(.serialized)
struct PreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "knopo-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func writeConfig(at root: URL, dateFormat: String) throws {
        let url = root.appendingPathComponent(".knopo/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ \"dateFormat\": \"\(dateFormat)\" }".utf8).write(to: url)
    }

    @Test func defaultsAndStoredBounds() {
        let empty = Preferences(defaults: defaults(), syncsRenderer: false)
        #expect(empty.theme == .system)
        #expect(empty.contentWeight == .medium)
        #expect(!empty.showPageRefBrackets)
        #expect(empty.defaultDateFormat == .default)
        #expect(empty.zoom == 1)
        #expect(empty.density == 1)

        let stored = defaults()
        stored.set(99.0, forKey: BlockRenderer.zoomKey)
        stored.set(0.1, forKey: BlockRenderer.densityKey)
        let bounded = Preferences(defaults: stored, syncsRenderer: false)
        #expect(bounded.zoom == BlockRenderer.maxZoom)
        #expect(bounded.density == BlockRenderer.minDensity)

        let runtimeStore = defaults()
        let runtime = Preferences(defaults: runtimeStore, syncsRenderer: false)
        runtime.zoom = 99
        runtime.density = 0.1
        #expect(runtime.zoom == BlockRenderer.maxZoom)
        #expect(runtime.density == BlockRenderer.minDensity)
        #expect(runtime.renderRevision == 2)
        let restored = Preferences(defaults: runtimeStore, syncsRenderer: false)
        #expect(restored.zoom == BlockRenderer.maxZoom)
        #expect(restored.density == BlockRenderer.minDensity)
    }

    @Test func valuesPersistAndThemeMigratesOnlyOnce() {
        let store = defaults()
        let preferences = Preferences(defaults: store, syncsRenderer: false)
        preferences.migrateThemeIfNeeded(from: "dark")
        preferences.migrateThemeIfNeeded(from: "light")
        preferences.contentWeight = .heavy
        preferences.showPageRefBrackets = true
        preferences.defaultDateFormat = JournalDateFormat(rawValue: "yyyy-MM-dd")
        preferences.zoom = 1.4
        preferences.density = 1.3

        let restored = Preferences(defaults: store, syncsRenderer: false)
        #expect(restored.theme == .dark)
        #expect(restored.contentWeight == .heavy)
        #expect(restored.showPageRefBrackets)
        #expect(restored.defaultDateFormat.rawValue == "yyyy-MM-dd")
        #expect(restored.zoom == 1.4)
        #expect(restored.density == 1.3)
    }

    /// The old per-graph format is imported once - by the first graph opened that
    /// carries one - and never written back to any config.json.
    @Test func firstGraphOpenedMigratesItsDateFormatIntoPreferences() throws {
        let preferences = Preferences(defaults: defaults(), syncsRenderer: false)
        let manager = GraphManager(preferences: preferences)

        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-migrate-first-\(UUID().uuidString)")
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-migrate-second-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        // Written as raw JSON: `dateFormat` is decode-only now, so a GraphConfig
        // round-trip could not produce the file an older Knopo left behind.
        try writeConfig(at: firstRoot, dateFormat: "d MMM yyyy")
        _ = try manager.acquire(firstRoot)
        #expect(preferences.defaultDateFormat.rawValue == "d MMM yyyy")

        // Second graph, different legacy value: the first one already won.
        try writeConfig(at: secondRoot, dateFormat: "yyyy/MM/dd")
        let secondApp = try manager.acquire(secondRoot)
        #expect(preferences.defaultDateFormat.rawValue == "d MMM yyyy")

        // And the key stops being written: saving drops it from both graphs.
        try secondApp.store.updateConfig { $0.favourites = ["Home"] }
        let saved = try String(contentsOf: secondApp.store.configURL, encoding: .utf8)
        #expect(!saved.contains("dateFormat"))
    }

    @Test func theCustomDatePatternIsRemembered() {
        let store = defaults()
        let preferences = Preferences(defaults: store, syncsRenderer: false)
        #expect(preferences.customDateDraft.isEmpty)

        preferences.customDateDraft = "EEEE, d MMM yyyy"
        #expect(store.string(forKey: Preferences.customDateDraftKey) == "EEEE, d MMM yyyy")
        let restored = Preferences(defaults: store, syncsRenderer: false)
        #expect(restored.customDateDraft == "EEEE, d MMM yyyy")
    }

    @Test func dateFormatChangePersistsAndInvalidatesViews() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = defaults()
        let preferences = Preferences(defaults: store, syncsRenderer: false)
        let app = AppState(store: try GraphStore(root: root), preferences: preferences)
        let before = app.dataVersion

        preferences.defaultDateFormat = JournalDateFormat(rawValue: "yyyy-MM-dd")

        #expect(app.journalDateFormat.rawValue == "yyyy-MM-dd")
        #expect(app.dataVersion == before + 1)
        #expect(app.displayTitle(for: "2026-06-10") == "2026-06-10")
        #expect(store.string(forKey: Preferences.defaultDateFormatKey) == "yyyy-MM-dd")
    }

    @Test func rebuildPrunesFavouritesForDeletedPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-rebuild-favourites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences(defaults: defaults(), syncsRenderer: false)
        let store = try GraphStore(root: root)
        var present = try store.createPage(named: "Present")
        present.blocks[0].content = "content"
        store.updatePage(present)
        try store.savePage(named: present.name)
        try store.updateConfig {
            $0.favourites = ["Present", "Deleted"]
        }
        let app = AppState(store: store, preferences: preferences)

        try await app.rebuildIndex()

        #expect(app.store.config.favourites == ["Present"])
    }
}
