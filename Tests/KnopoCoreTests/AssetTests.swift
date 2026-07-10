import Testing
import Foundation
@testable import KnopoCore

@Suite struct AssetTests {

    private func makeGraph() throws -> GraphStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-asset-test-\(UUID().uuidString)")
        return try GraphStore(root: root)
    }

    private func makeSource(named name: String, data: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-asset-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func importCreatesAssetsAndCopiesFile() throws {
        let store = try makeGraph()
        let source = try makeSource(named: "shot.png", data: Data([1, 2, 3]))
        expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))

        let name = try store.importAsset(from: source)

        expectEqual(name, "shot.png")
        expectEqual(try Data(contentsOf: store.assetsDir.appendingPathComponent(name)), Data([1, 2, 3]))
    }

    @Test func collisionsUseNumericSuffixes() throws {
        let store = try makeGraph()
        let first = try makeSource(named: "shot.png", data: Data([1]))
        let second = try makeSource(named: "shot.png", data: Data([2]))
        let third = try makeSource(named: "shot.png", data: Data([3]))

        expectEqual(try store.importAsset(from: first), "shot.png")
        expectEqual(try store.importAsset(from: second), "shot-1.png")
        expectEqual(try store.importAsset(from: third), "shot-2.png")
    }

    @Test func identicalBytesReuseExistingAsset() throws {
        let store = try makeGraph()
        let first = try makeSource(named: "same.png", data: Data([4, 5]))
        let second = try makeSource(named: "same.png", data: Data([4, 5]))

        expectEqual(try store.importAsset(from: first), "same.png")
        expectEqual(try store.importAsset(from: second), "same.png")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsDir.path).count, 1)
    }

    @Test func sourceAlreadyInAssetsIsReturnedUnchanged() throws {
        let store = try makeGraph()
        let name = try store.saveAsset(Data([6]), preferredName: "inside.png")
        let source = store.assetsDir.appendingPathComponent(name)

        expectEqual(try store.importAsset(from: source), "inside.png")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsDir.path).count, 1)
    }

    @Test func saveAssetSanitizesAndRoundTripsBytes() throws {
        let store = try makeGraph()
        let data = Data([7, 8, 9])

        let name = try store.saveAsset(data, preferredName: "capture (one)[x].png")

        expectEqual(name, "capture_-one--x-.png")
        expectEqual(try Data(contentsOf: store.assetsDir.appendingPathComponent(name)), data)
    }

    @Test func sanitizesAssetNames() throws {
        let store = try makeGraph()
        expectEqual(try store.saveAsset(Data([1]), preferredName: "shot (v2).png"), "shot_-v2-.png")
        expectEqual(try store.saveAsset(Data([2]), preferredName: ".hidden.png"), "hidden.png")
        expectEqual(try store.saveAsset(Data([3]), preferredName: "a/b.png"), "b.png")
        expectEqual(try store.saveAsset(Data([4]), preferredName: ""), "image")
        // Spaces become underscores (CommonMark forbids spaces in a link
        // destination, and Logseq writes underscores too).
        expectEqual(try store.saveAsset(Data([5]), preferredName: "Dark blue theme ex. 1.jpg"),
                    "Dark_blue_theme_ex._1.jpg")
    }

    @Test func recognizesImageExtensionsCaseInsensitively() {
        for name in ["a.png", "a.JPG", "a.jpeg", "a.gif", "a.webp", "a.HEIC", "a.heif",
                     "a.tif", "a.tiff", "a.bmp", "a.svg", "a.avif", "a.jp2"] {
            expectTrue(GraphStore.isImageFile(URL(fileURLWithPath: name)), name)
        }
        for name in ["a.pdf", "a.txt", "a", "png"] {
            expectFalse(GraphStore.isImageFile(URL(fileURLWithPath: name)), name)
        }
    }

    @Test func emitsImageMarkdown() {
        // `../assets/` src — resolved relative to the page file, so the pages
        // stay portable to Logseq/GitHub/Obsidian (Knopo reads both forms).
        expectEqual(GraphStore.imageMarkdown(assetNamed: "shot.png"),
                    "![shot](../assets/shot.png)")
        expectEqual(GraphStore.imageMarkdown(assetNamed: "shot-1.png"),
                    "![shot-1](../assets/shot-1.png)")
        expectEqual(GraphStore.imageMarkdown(assetNamed: "pasted.png", alt: "image"),
                    "![image](../assets/pasted.png)")
    }

    @Test func emittedMarkdownParsesAsImageNode() {
        let markdown = GraphStore.imageMarkdown(assetNamed: "Dark_blue_theme_ex._1.jpg")
        let nodes = InlineParser.parse(markdown)
        expectEqual(nodes.count, 1)
        guard case .image(let alt, let src, nil) = nodes.first else {
            Issue.record("expected .image node, got \(nodes)")
            return
        }
        expectEqual(alt, "Dark_blue_theme_ex._1")
        expectEqual(src, "../assets/Dark_blue_theme_ex._1.jpg")
    }
}
