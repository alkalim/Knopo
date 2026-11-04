import AppKit
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct RowMeasurementTests {
    @Test func measurementTracksWrappingAndAppearance() throws {
        let previous = (BlockRenderer.zoom, BlockRenderer.density, BlockRenderer.contentWeight)
        defer {
            BlockRenderer.zoom = previous.0
            BlockRenderer.density = previous.1
            BlockRenderer.contentWeight = previous.2
        }
        let styles: [(CGFloat, CGFloat, BlockRenderer.ContentWeight)] = [
            (1, 1, .medium), (1.25, 1, .heavy), (1.25, 0.8, .heavy), (1, 1, .medium)
        ]
        let body = String(repeating: "A **bold** sentence with `code` and 👩🏽‍💻. ", count: 8)
        let view = BlockEditorTextView.create()
        for source in ["", body, "# " + body] {
            for (zoom, density, weight) in styles {
                BlockRenderer.zoom = zoom
                BlockRenderer.density = density
                BlockRenderer.contentWeight = weight
                let expectedLineHeight = (NSLayoutManager().defaultLineHeight(
                    for: BlockRenderer.pinnedFont(forSource: source)) * BlockRenderer.lineHeightScale).rounded()
                #expect(BlockRenderer.lineHeight(forSource: source) == expectedLineHeight)
                for width: CGFloat in [120, 560, 120] {
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
                    view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
                    view.setContent(source.isEmpty ? " " : source)
                    let layout = try #require(view.textLayoutManager)
                    layout.ensureLayout(for: layout.documentRange)
                    let displayed = ceil(layout.usageBoundsForTextContainer.height) + view.textContainerInset.height * 2
                    #expect(BlockEditorTextView.measureHeight(for: source, width: width) == displayed)
                }
            }
        }
    }

    @Test func detachedPaneUsesAvailableWidthDuringSizing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-initial-width-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Sizing")
        let source = String(repeating: "Some **formatted text** that wraps. ", count: 20)
        page.blocks = [Block(content: source)]
        store.updatePage(page)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.inPane = true
        controller.applyPaneRole()
        controller.initialLayoutWidth = 360
        let table = controller.tableView
        table.frame.size.width = 100
        controller.present(pageName: page.name, zoom: nil)
        let width = OutlineRowCell.contentWidth(forDepth: 0, rowWidth: 360)
        let rendered = BlockRenderer.render(content: source, context: .init(contentWidth: width))
        let expected = OutlineRowCell.height(for: rendered, contentWidth: width)
        #expect(controller.tableView(table, heightOfRow: 0) == expected)
        table.frame.size.width = 360
        #expect(controller.tableView(table, heightOfRow: 0) == expected)
    }

    @Test(arguments: [CGFloat(80), 320, 760])
    func measuredHeightMatchesDisplayedText(width: CGFloat) throws {
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-height-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let imageURL = assets.appendingPathComponent("photo.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let image = try #require(ImageCache.image(at: imageURL))
        let samples = [
            "", "ordinary text", String(repeating: "A long **bold** sentence with `code` and #tag. ", count: 20),
            "# Heading", "> quoted text\nsecond line", "```swift\nlet a = 2\nprint(a)\n```",
            "TODO a task with [[Page]]", "中文换行测试。 العربية עברית 👩🏽‍💻🎉",
            "first paragraph\n\nlast paragraph\n", "| Name | Count |\n| --- | ---: |\n| Apples | 123 |",
            "![natural](photo.png)", "![explicit|120x90](photo.png)"
        ]
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        for source in samples {
            let rendered = BlockRenderer.render(content: source,
                context: .init(assetsDir: assets, contentWidth: width))
            if source.hasPrefix("![") {
                let attachment = try #require(rendered.attribute(.attachment, at: 0,
                    effectiveRange: nil) as? NSTextAttachment)
                #expect(attachment.image === image)
                #expect(attachment.bounds.size == (source.contains("explicit")
                    ? NSSize(width: 120, height: 90) : NSSize(width: 240, height: 180)))
            }
            let measured = OutlineRowCell.height(for: rendered, contentWidth: width)
            if rendered.length == 0 {
                let space = NSMutableAttributedString(string: " ", attributes: [
                    .font: NSFont.systemFont(ofSize: BlockRenderer.baseFontSize)])
                BlockRenderer.pinLineHeight(space, BlockRenderer.lineHeight(forSource: ""))
                view.textStorage?.setAttributedString(space)
            } else {
                view.textStorage?.setAttributedString(rendered)
            }
            view.updateContentInsets()
            let layout = try #require(view.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            let displayed = max(OutlineRowCell.minRowHeight,
                ceil(layout.usageBoundsForTextContainer.height)
                    + view.textContainerInset.height * 2 + OutlineRowCell.verticalPadding * 2)
            #expect(measured == displayed, "Width \(width), source: \(source)")
        }
    }
}
