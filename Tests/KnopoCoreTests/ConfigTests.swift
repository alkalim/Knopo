import Testing
import Foundation
@testable import KnopoCore

@Suite struct ConfigTests {

    /// New layout fields round-trip through JSON (SPEC §12).
    @Test func layoutFieldsRoundTrip() throws {
        var config = GraphConfig()
        config.rightPanes = ["page\tIdeas\t", "tag\tproject", "journalHome"]
        config.rightPaneFraction = 0.4
        config.allPagesCollapsedSections = ["journal", "namespace\tProjects"]

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-cfg-\(UUID().uuidString)/config.json")
        try config.save(to: url)
        let loaded = GraphConfig.load(from: url)

        expectEqual(loaded.rightPanes, config.rightPanes)
        expectEqual(loaded.rightPaneFraction, 0.4)
        expectEqual(
            loaded.allPagesCollapsedSections,
            config.allPagesCollapsedSections
        )
    }

    /// An older config file (no layout keys) still loads, with defaults — the
    /// field-by-field decode must not fail the whole document.
    @Test func olderConfigLoadsWithDefaults() throws {
        let json = """
        { "favourites": ["Home"], "favouriteTags": ["work"], "theme": "dark" }
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-cfg-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let loaded = GraphConfig.load(from: url)
        expectEqual(loaded.orderedFavourites, [.page("Home"), .tag("work")])
        expectEqual(loaded.legacyTheme, "dark")
        expectEqual(loaded.legacyDateFormat, .default)
        expectTrue(loaded.rightPanes.isEmpty)
        expectTrue(loaded.rightPaneFraction == nil)
        expectTrue(loaded.allPagesCollapsedSections.isEmpty)
    }

    @Test func mixedFavouritesKeepTheirPositionsThroughRenamesAndRemovals() {
        var config = GraphConfig()
        config.orderedFavourites = [.tag("home"), .page("Home"), .tag("work"), .page("Ideas")]
        config.renameFavourite(from: "HOME", to: "Start")
        config.renameFavouriteTag(from: "work", to: "projects")
        config.toggleFavouriteTag("HOME")
        config.toggleFavourite("Later")
        config.removeFavourite("Start")
        expectEqual(config.orderedFavourites, [.tag("projects"), .page("Ideas"), .page("Later")])
        config.toggleFavouriteTag("archive")
        config.renameFavouriteTag(from: "archive", to: "Projects")
        expectEqual(config.orderedFavourites, [.tag("projects"), .page("Ideas"), .page("Later")])
    }

    @Test func sidebarLimitKeepsTheFirstPagesAndTagsInOrder() {
        var config = GraphConfig()
        config.orderedFavourites = (1...17).map { .page("P\($0)") } + (1...17).map { .tag("t\($0)") }
        config.orderedFavourites.insert(.tag("first"), at: 1)
        config.orderedFavourites.append(.page("last"))
        let expected: [Favourite] = [.page("P1"), .tag("first")]
            + (2...15).map { .page("P\($0)") } + (1...14).map { .tag("t\($0)") }
        expectEqual(config.orderedFavourites(limitPerKind: 15), expected)
    }

    @Test func legacyThemeAndDateFormatAreDecodedButNotReencoded() throws {
        let json = """
        { "dateFormat": "MMM d'th', yyyy", "theme": "dark" }
        """
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-cfg-\(UUID().uuidString)")
        let input = root.appendingPathComponent("input.json")
        let output = root.appendingPathComponent("output.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(json.utf8).write(to: input)

        let loaded = GraphConfig.load(from: input)
        // `MMM d'th', yyyy` normalizes to the pattern it always meant; both
        // legacy keys survive the decode and neither is written back.
        expectEqual(loaded.legacyDateFormat.customPattern, "MMM d{ordinal}, yyyy")
        expectEqual(loaded.legacyTheme, "dark")
        try loaded.save(to: output)
        let saved = try String(contentsOf: output, encoding: .utf8)
        expectFalse(saved.contains("\"dateFormat\""))
        expectFalse(saved.contains("\"theme\""))
    }

    @Test func invalidPersistedDateFormatFallsBackToDefault() throws {
        let json = "{ \"dateFormat\": \"{unknown}\" }"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-cfg-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(json.utf8).write(to: url)
        expectEqual(GraphConfig.load(from: url).legacyDateFormat, .default)
    }

    @Test func encoderCoversEveryNonlegacyConfigKey() throws {
        var config = GraphConfig()
        config.rightPaneFraction = 0.4 // ensure the sole optional key is emitted
        let data = try JSONEncoder().encode(config)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = Set(GraphConfig.CodingKeys.allCases)
            .subtracting(GraphConfig.legacyOnlyCodingKeys)
            .map(\.rawValue)
        expectEqual(Set(object.keys), Set(expected))
    }
}
