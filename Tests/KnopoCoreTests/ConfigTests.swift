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
        { "favourites": ["Home"], "theme": "dark" }
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-cfg-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let loaded = GraphConfig.load(from: url)
        expectEqual(loaded.favourites, ["Home"])
        expectEqual(loaded.legacyTheme, "dark")
        expectEqual(loaded.legacyDateFormat, .default)
        expectTrue(loaded.rightPanes.isEmpty)
        expectTrue(loaded.rightPaneFraction == nil)
        expectTrue(loaded.allPagesCollapsedSections.isEmpty)
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
        // `MMM d'th', yyyy` is not a format Knopo writes, so it normalizes away;
        // both legacy keys survive the decode and neither is written back.
        expectEqual(loaded.legacyDateFormat, .default)
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
