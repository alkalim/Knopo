import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// What a `[[page]]` hover preview shows (SPEC §6.1).
@MainActor
@Suite struct HoverPreviewTests {

    private func controller(_ store: GraphStore) -> (OutlineEditorController, AppState) {
        let app = AppState(store: store)
        return (OutlineEditorController(app: app, nav: Navigator(app: app)), app)
    }

    private func store() throws -> GraphStore {
        try GraphStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-preview-\(UUID().uuidString)"))
    }

    /// The pointer is on the link that names the page, so the preview doesn't
    /// repeat it.
    @Test func previewLeavesOutThePageTitle() throws {
        let store = try store()
        var doc = store.page(named: "Roadmap")
        doc.blocks = [Block(content: "first block"), Block(content: "second block")]
        store.updatePage(doc)
        try store.savePage(named: "Roadmap")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Roadmap"))
        #expect(!preview.string.contains("Roadmap"))
        #expect(preview.string.contains("first block"))
        #expect(preview.string.contains("second block"))
    }

    /// A page with nothing in it would show a blank popover, so it shows a chip.
    @Test func aPageWithNothingInItShowsAChip() throws {
        let store = try store()
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Nowhere"))
        var attachments = 0
        preview.enumerateAttribute(.attachment, in: NSRange(location: 0, length: preview.length)) {
            value, _, _ in if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
        #expect(preview.string.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1)
    }

    /// A tag's blocks come from anywhere, so each line names its page.
    @Test func tagPreviewNamesThePageOfEachBlock() throws {
        let store = try store()
        var doc = store.page(named: "Roadmap")
        doc.blocks = [Block(content: "ship it #followup")]
        store.updatePage(doc)
        try store.savePage(named: "Roadmap")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forTag: "followup"))
        #expect(preview.string.contains("Roadmap"))
        #expect(preview.string.contains("ship it"))
    }

    /// Blank blocks are not lines worth showing.
    @Test func emptyBlocksDoNotBecomeBulletedBlanks() throws {
        let store = try store()
        var doc = store.page(named: "Sparse")
        doc.blocks = [Block(content: ""), Block(content: "kept"), Block(content: "")]
        store.updatePage(doc)
        try store.savePage(named: "Sparse")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Sparse"))
        #expect(preview.string.split(separator: "\n").count == 1)
        #expect(preview.string.contains("kept"))
    }
}
