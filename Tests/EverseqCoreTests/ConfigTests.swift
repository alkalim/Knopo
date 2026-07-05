import Testing
import Foundation
@testable import EverseqCore

@Suite struct ConfigTests {

    /// New layout fields round-trip through JSON (SPEC §12).
    @Test func layoutFieldsRoundTrip() throws {
        var config = GraphConfig()
        config.rightPanes = ["page\tIdeas\t", "tag\tproject", "journalHome"]
        config.rightPaneFraction = 0.4

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("everseq-cfg-\(UUID().uuidString)/config.json")
        try config.save(to: url)
        let loaded = GraphConfig.load(from: url)

        expectEqual(loaded.rightPanes, config.rightPanes)
        expectEqual(loaded.rightPaneFraction, 0.4)
    }

    /// An older config file (no layout keys) still loads, with defaults — the
    /// field-by-field decode must not fail the whole document.
    @Test func olderConfigLoadsWithDefaults() throws {
        let json = """
        { "favourites": ["Home"], "theme": "dark" }
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("everseq-cfg-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let loaded = GraphConfig.load(from: url)
        expectEqual(loaded.favourites, ["Home"])
        expectEqual(loaded.theme, "dark")
        expectTrue(loaded.rightPanes.isEmpty)
        expectTrue(loaded.rightPaneFraction == nil)
    }
}
