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
        preferences.defaultDateFormat = JournalDateFormat(pattern: "yyyy-MM-dd")
        preferences.zoom = 1.4
        preferences.density = 1.3

        let restored = Preferences(defaults: store, syncsRenderer: false)
        #expect(restored.theme == .dark)
        #expect(restored.contentWeight == .heavy)
        #expect(restored.showPageRefBrackets)
        #expect(restored.defaultDateFormat.pattern == "yyyy-MM-dd")
        #expect(restored.zoom == 1.4)
        #expect(restored.density == 1.3)
    }

    @Test func firstOpenCopiesDefaultDateFormatWithoutChangingExistingGraphs() throws {
        let store = defaults()
        let preferences = Preferences(defaults: store, syncsRenderer: false)
        preferences.defaultDateFormat = JournalDateFormat(pattern: "yyyy/MM/dd")
        let manager = GraphManager(preferences: preferences)

        let newRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-new-settings-\(UUID().uuidString)")
        let existingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-existing-settings-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: newRoot)
            try? FileManager.default.removeItem(at: existingRoot)
        }

        let newApp = try manager.acquire(newRoot)
        #expect(newApp.store.config.dateFormat.pattern == "yyyy/MM/dd")
        #expect(FileManager.default.fileExists(
            atPath: newRoot.appendingPathComponent(".knopo/config.json").path))

        var existing = GraphConfig()
        existing.dateFormat = JournalDateFormat(pattern: "d MMM yyyy")
        try existing.save(to: existingRoot.appendingPathComponent(".knopo/config.json"))
        let existingApp = try manager.acquire(existingRoot)
        #expect(existingApp.store.config.dateFormat.pattern == "d MMM yyyy")
    }

    @Test func graphDateUpdatePersistsAndInvalidatesViews() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-graph-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences(defaults: defaults(), syncsRenderer: false)
        let app = AppState(store: try GraphStore(root: root), preferences: preferences)
        let before = app.dataVersion

        try app.updateJournalDateFormat(JournalDateFormat(pattern: "yyyy-MM-dd"))

        #expect(app.store.config.dateFormat.pattern == "yyyy-MM-dd")
        #expect(app.dataVersion == before + 1)
        #expect(app.displayTitle(for: "2026-06-10") == "2026-06-10")
        #expect(GraphConfig.load(from: app.store.configURL).dateFormat.pattern == "yyyy-MM-dd")
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
