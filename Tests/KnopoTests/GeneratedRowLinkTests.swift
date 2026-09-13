import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Query results and embeds are one link to their source, laid over rendered
/// content. Links already in that content must survive, or a ref inside a
/// result leads somewhere it doesn't name.
@MainActor
@Suite struct GeneratedRowLinkTests {

    @Test func refsInsideAResultKeepTheirOwnTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-rowlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = store.page(named: "Source")
        source.blocks = [Block(content: "see [[Elsewhere]] about it #later")]
        store.updatePage(source)
        try store.savePage(named: "Source")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        let rendered = controller.renderGeneratedRow(
            content: "see [[Elsewhere]] about it #later",
            navigatingTo: KnopoURL.block(UUID(), onPage: "Source"))

        var targets: [String] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in
            if let url = value as? URL { targets.append(url.absoluteString) }
        }
        #expect(targets.contains { $0 == KnopoURL.page("Elsewhere").absoluteString })
        #expect(targets.contains { $0 == KnopoURL.tag("later").absoluteString })
        // The plain words still carry the row's own link to the source block.
        #expect(targets.contains { $0.contains("block=") })
    }
}
