import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Clicking rendered text has to land the caret where it was clicked (SPEC §5.4).
/// The rendered form hides markers and rewrites titles, so the rendered and
/// source index spaces differ — these check the recorded mapping, not the old
/// "reuse the rendered index and clamp" approximation.
@MainActor
@Suite struct CaretMappingTests {

    private func render(_ content: String) -> NSAttributedString {
        BlockRenderer.render(
            content: content,
            context: BlockRenderer.Context(journalDateFormat: .default))
    }

    /// Source offset for the rendered index of `needle`'s first character.
    private func mappedOffset(of needle: String, in content: String) throws -> Int {
        let rendered = render(content)
        let range = (rendered.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        return try #require(OutlineEditorController.sourceOffset(
            inRendered: rendered, at: range.location))
    }

    @Test func plainTextMapsOneToOne() throws {
        let content = "just some words"
        #expect(try mappedOffset(of: "some", in: content)
            == (content as NSString).range(of: "some").location)
    }

    /// The markers are not in the rendered text, so a naive rendered index would
    /// land four characters early here.
    @Test func textAfterBoldSkipsTheMarkers() throws {
        let content = "a **bold** tail"
        let offset = try mappedOffset(of: "tail", in: content)
        #expect(offset == (content as NSString).range(of: "tail").location)
    }

    /// Inside the emphasis, the caret lands inside the source's markers too.
    @Test func clickInsideBoldLandsInsideTheMarkers() throws {
        let content = "a **bold** tail"
        let offset = try mappedOffset(of: "bold", in: content)
        #expect(offset == (content as NSString).range(of: "bold").location)
    }

    /// A page ref renders as its title, so an offset inside it means nothing in
    /// the source — the whole run maps to where the `[[` starts.
    @Test func pageRefMapsToItsTokenStart() throws {
        let content = "see [[Marina]] later"
        let offset = try mappedOffset(of: "Marina", in: content)
        #expect(offset == (content as NSString).range(of: "[[Marina]]").location)
    }

    /// A date ref's rendered text ("Jun 10th, 2026") shares nothing with its
    /// source ("2026-06-10"), which is exactly where clamping went wrong.
    @Test func dateRefMapsToItsTokenStart() throws {
        let content = "met on [[2026-06-10]] in town"
        let offset = try mappedOffset(of: "Jun", in: content)
        #expect(offset == (content as NSString).range(of: "[[2026-06-10]]").location)
    }

    /// A TODO keyword and a heading's `## ` are stripped before inline parsing,
    /// so the base offset has to be added back.
    @Test func blockMarkersShiftTheBase() throws {
        #expect(try mappedOffset(of: "milk", in: "TODO buy milk")
            == ("TODO buy milk" as NSString).range(of: "milk").location)
        #expect(try mappedOffset(of: "Title", in: "### A Title here")
            == ("### A Title here" as NSString).range(of: "Title").location)
    }

    /// A tag renders with its `#`, and a click inside it maps to the token.
    @Test func tagMapsToItsTokenStart() throws {
        let content = "tagged #boat here"
        let offset = try mappedOffset(of: "#boat", in: content)
        #expect(offset == (content as NSString).range(of: "#boat").location)
    }

    /// Monospaced runs are the case that stayed wrong after the first pass: the
    /// code text of an inline span is its source one backtick in, so a click in
    /// the pill maps character for character instead of snapping to the token.
    @Test func inlineCodeMapsInsideThePill() throws {
        let content = "run `swift build` now"
        #expect(try mappedOffset(of: "build", in: content)
            == (content as NSString).range(of: "build").location)
        #expect(try mappedOffset(of: "swift", in: content)
            == (content as NSString).range(of: "swift build").location)
    }

    /// Text after a code span still maps past the closing backtick.
    @Test func textAfterInlineCodeSkipsTheBackticks() throws {
        let content = "run `swift build` now"
        #expect(try mappedOffset(of: "now", in: content)
            == (content as NSString).range(of: "now").location)
    }

    /// A fenced block renders without its fence lines, so the code has to carry
    /// the offset of the line after the opening fence.
    @Test func fencedCodeMapsPastTheFenceLine() throws {
        let content = "```swift\nlet x = 1\nlet y = 2\n```"
        #expect(try mappedOffset(of: "let y", in: content)
            == (content as NSString).range(of: "let y").location)
        // The language tag maps too — it sits three characters in.
        #expect(try mappedOffset(of: "swift", in: content) == 3)
    }

    @Test func mathMapsInsideItsDelimiters() throws {
        let content = "so $x + 1$ holds"
        #expect(try mappedOffset(of: "x + 1", in: content)
            == (content as NSString).range(of: "x + 1").location)
    }

    /// Where no mapping is recorded — a table's cells are lifted out of the
    /// content, so an offset would be wrong — the caller is told so and falls
    /// back rather than being handed a bogus offset.
    @Test func untrackedBlocksReportNoMapping() {
        let table = render("| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(OutlineEditorController.sourceOffset(inRendered: table, at: 2) == nil)
    }

    @Test func emptyRenderedTextHasNoMapping() {
        #expect(OutlineEditorController.sourceOffset(
            inRendered: NSAttributedString(string: ""), at: 0) == nil)
    }
}
