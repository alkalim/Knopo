import Testing
import Foundation
@testable import KnopoCore

@Suite struct RoundTripTests {

    private func assertRoundTrip(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let parsed = PageParser.parse(text)
        let out = PageSerializer.serialize(parsed)
        expectEqual(out, text, "round trip must be byte-stable", sourceLocation: sourceLocation)
    }

    @Test func specExample() {
        assertRoundTrip("""
        - First top-level block
          - A child block
            id:: 6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f
          - Another child, **bold** and a link to [[Project X]] #urgent
        - Second top-level block ((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))

        """)
    }

    @Test func emptyFile() {
        assertRoundTrip("")
    }

    @Test func noTrailingNewline() {
        assertRoundTrip("- one\n- two")
    }

    @Test func cRLFPreserved() {
        assertRoundTrip("- one\r\n  - child\r\n")
    }

    @Test func weirdIndentationPreserved() {
        assertRoundTrip("""
        - a
           - three-space child
                 - deep
           - sibling
        - b

        """)
    }

    @Test func multiLineBlockWithCodeFence() {
        assertRoundTrip("""
        - Some code:
          ```swift
          let x = [[not a ref]]
          - not a bullet
          ```
        - after

        """)
    }

    @Test func blankLinesBetweenBlocksPreserved() {
        assertRoundTrip("- a\n\n- b\n\n\n- c\n")
    }

    @Test func pagePropertiesBlock() {
        assertRoundTrip("""
        - title:: My Page
          tags:: a, b
        - first real block

        """)
    }

    @Test func collapsedAndIdProperties() {
        let text = """
        - parent
          id:: 11111111-2222-3333-4444-555555555555
          collapsed:: true
          - hidden child

        """
        assertRoundTrip(text)
        let page = PageParser.parse(text)
        expectEqual(page.blocks.count, 1)
        expectTrue(page.blocks[0].collapsed)
        expectTrue(page.blocks[0].idPersisted)
        expectEqual(page.blocks[0].id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        expectEqual(page.blocks[0].children.count, 1)
        expectEqual(page.blocks[0].children[0].content, "hidden child")
    }

    @Test func preamblePreserved() {
        assertRoundTrip("some stray preamble\nanother line\n- block\n")
    }

    @Test func structureParsing() {
        let page = PageParser.parse("""
        - a
          - a1
            - a1a
          - a2
        - b
        """)
        expectEqual(page.blocks.count, 2)
        expectEqual(page.blocks[0].content, "a")
        expectEqual(page.blocks[0].children.count, 2)
        expectEqual(page.blocks[0].children[0].children[0].content, "a1a")
        expectEqual(page.blocks[1].content, "b")
    }

    @Test func editedBlockSerializesCanonically() {
        var page = PageParser.parse("- a\n- b\n")
        page.blocks[0].content = "a edited"
        let out = PageSerializer.serialize(page)
        expectEqual(out, "- a edited\n- b\n")
    }

    @Test func newBlockGetsCanonicalForm() {
        var page = PageParser.parse("- a\n")
        page.blocks.append(Block(content: "new"))
        page.blocks[0].children.append(Block(content: "child", collapsed: true))
        let out = PageSerializer.serialize(page)
        expectEqual(out, "- a\n  - child\n    collapsed:: true\n- new\n")
    }

    @Test func idPersistedOnDemand() {
        var page = PageParser.parse("- target\n")
        let id = page.blocks[0].id
        page.blocks[0].idPersisted = true
        let out = PageSerializer.serialize(page)
        expectEqual(out, "- target\n  id:: \(id.uuidString.lowercased())\n")
        // And it round-trips with the same id.
        let again = PageParser.parse(out)
        expectEqual(again.blocks[0].id, id)
    }

    @Test func multiLineContent() {
        let text = "- first line\n  second line\n  third line\n"
        let page = PageParser.parse(text)
        expectEqual(page.blocks[0].content, "first line\nsecond line\nthird line")
        assertRoundTrip(text)
    }

    @Test func querySyntaxRoundTripsLiterally() {
        assertRoundTrip("- {{query (and [[a]] [[b]])}}\n")
    }

    @Test func imageSizeSyntaxRoundTripsLiterally() {
        assertRoundTrip("""
        - ![pipe|363](../assets/pipe.png)
        - ![dimensions|640x480](../assets/dimensions.png)
        - ![logseq](../assets/logseq.png){:height 239, :width 363}

        """)
    }

    @Test func unknownPropertiesRoundTrip() {
        let text = "- block\n  custom:: some value\n  another:: x\n"
        assertRoundTrip(text)
        let page = PageParser.parse(text)
        expectEqual(page.blocks[0].properties, [
            BlockProperty(key: "custom", value: "some value"),
            BlockProperty(key: "another", value: "x"),
        ])
        expectEqual(page.blocks[0].content, "block")
    }

    @Test func emptyBlocks() {
        assertRoundTrip("-\n- a\n-\n")
        let page = PageParser.parse("-\n")
        expectEqual(page.blocks.count, 1)
        expectEqual(page.blocks[0].content, "")
    }

    @Test func depthChangeInvalidatesRaw() {
        var page = PageParser.parse("- a\n- b\n")
        // Indent "b" under "a": depth changes, canonical re-emit at new depth.
        var b = page.blocks.removeLast()
        b.invalidateRaw(deep: true)
        page.blocks[0].children.append(b)
        let out = PageSerializer.serialize(page)
        expectEqual(out, "- a\n  - b\n")
    }

    @Test func serializerReindentsWhenDepthMismatch() {
        // Even without explicit invalidation, a raw at the wrong depth is
        // re-emitted canonically rather than verbatim.
        var page = PageParser.parse("- a\n- b\n")
        let b = page.blocks.removeLast()
        page.blocks[0].children.append(b)
        let out = PageSerializer.serialize(page)
        expectEqual(out, "- a\n  - b\n")
    }
}
