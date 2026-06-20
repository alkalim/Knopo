import Testing
import Foundation
@testable import EverseqCore

@Suite struct OutlineOpsTests {

    private func forest(_ text: String) -> [Block] {
        PageParser.parse(text).blocks
    }

    @Test func visibleRowsRespectCollapse() {
        var blocks = forest("- a\n  - a1\n  - a2\n- b\n")
        expectEqual(OutlineOps.visibleRows(in: blocks).map(\.block.content),
                    ["a", "a1", "a2", "b"])
        blocks[0].collapsed = true
        expectEqual(OutlineOps.visibleRows(in: blocks).map(\.block.content), ["a", "b"])
    }

    @Test func visibleRowsZoom() {
        let blocks = forest("- a\n  - a1\n    - deep\n  - a2\n- b\n")
        let zoomID = blocks[0].id
        let rows = OutlineOps.visibleRows(in: blocks, zoomRoot: zoomID)
        expectEqual(rows.map(\.block.content), ["a1", "deep", "a2"])
        // Paths remain absolute so edits write to the right place.
        expectEqual(rows[0].path, [0, 0])
        expectEqual(rows[1].path, [0, 0, 0])
    }

    @Test func splitMidContent() {
        var blocks = forest("- hello world\n")
        let newID = OutlineOps.split([0], at: 5, in: &blocks)
        expectNotNil(newID)
        expectEqual(blocks.map(\.content), ["hello", " world"])
        expectEqual(blocks[1].id, newID)
    }

    @Test func splitParentWithVisibleChildrenInsertsFirstChild() {
        var blocks = forest("- parent\n  - child\n")
        _ = OutlineOps.split([0], at: 6, in: &blocks)
        expectEqual(blocks.count, 1)
        expectEqual(blocks[0].content, "parent")
        expectEqual(blocks[0].children.map(\.content), ["", "child"])
    }

    @Test func splitAtStartOfBlockWithChildrenInsertsBlankAbove() {
        var blocks = forest("- One\n- Two\n  - Three\n")
        // Enter at the start of "Two": a blank sibling appears above, and "Two"
        // keeps its content *and* its child — it is not reparented.
        let id = OutlineOps.split([1], at: 0, in: &blocks)
        expectEqual(blocks.map(\.content), ["One", "", "Two"])
        expectTrue(blocks[1].children.isEmpty)
        expectEqual(blocks[2].children.map(\.content), ["Three"])
        expectEqual(id, blocks[2].id) // focus stays on "Two"
    }

    @Test func splitAtStartOfLeafKeepsBlankAbove() {
        var blocks = forest("- One\n- Two\n")
        let id = OutlineOps.split([0], at: 0, in: &blocks)
        expectEqual(blocks.map(\.content), ["", "One", "Two"])
        expectEqual(id, blocks[1].id)
    }

    @Test func splitEmptyBlockAddsSiblingBelow() {
        // Enter on a blank block still makes a new block below (cursor moves).
        var blocks = forest("- a\n- \n")
        let id = OutlineOps.split([1], at: 0, in: &blocks)
        expectEqual(blocks.count, 3)
        expectEqual(blocks[2].id, id)
    }

    @Test func indentOutdentRoundTrip() {
        var blocks = forest("- a\n- b\n")
        expectTrue(OutlineOps.indent([1], in: &blocks))
        expectEqual(blocks.count, 1)
        expectEqual(blocks[0].children.map(\.content), ["b"])
        expectTrue(OutlineOps.outdent([0, 0], in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "b"])
        // First sibling can't indent; top-level can't outdent.
        expectFalse(OutlineOps.indent([0], in: &blocks))
        expectFalse(OutlineOps.outdent([0], in: &blocks))
    }

    @Test func outdentAdoptsFollowingSiblings() {
        // a > (b, c, d, e); outdent c → c becomes a's next sibling and adopts
        // the siblings that followed it (d, e), instead of jumping below them.
        var blocks = forest("- a\n  - b\n  - c\n  - d\n  - e\n")
        expectTrue(OutlineOps.outdent([0, 1], in: &blocks)) // c is child index 1
        expectEqual(blocks.map(\.content), ["a", "c"])
        expectEqual(blocks[0].children.map(\.content), ["b"])
        expectEqual(blocks[1].children.map(\.content), ["d", "e"])
    }

    @Test func outdentWithNoFollowingSiblingsJustMovesUp() {
        var blocks = forest("- a\n  - b\n  - c\n")
        expectTrue(OutlineOps.outdent([0, 1], in: &blocks)) // c is last child
        expectEqual(blocks.map(\.content), ["a", "c"])
        expectEqual(blocks[0].children.map(\.content), ["b"])
        expectTrue(blocks[1].children.isEmpty)
    }

    @Test func indentIntoCollapsedParentExpandsIt() {
        var blocks = forest("- a\n  - a1\n  collapsed:: true\n- b\n")
        // (collapsed:: on "a" via canonical file would sit under a; build manually)
        blocks[0].collapsed = true
        expectTrue(OutlineOps.indent([1], in: &blocks))
        expectFalse(blocks[0].collapsed)
        expectEqual(blocks[0].children.map(\.content).last, "b")
    }

    @Test func moveAmongSiblings() {
        var blocks = forest("- a\n- b\n- c\n")
        expectTrue(OutlineOps.move([0], by: 1, in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "a", "c"])
        expectTrue(OutlineOps.move([1], by: -1, in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "b", "c"])
        expectFalse(OutlineOps.move([0], by: -1, in: &blocks))
        expectFalse(OutlineOps.move([2], by: 1, in: &blocks))
    }

    @Test func moveCarriesSubtree() {
        var blocks = forest("- a\n  - a1\n- b\n")
        expectTrue(OutlineOps.move([0], by: 1, in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "a"])
        expectEqual(blocks[1].children.map(\.content), ["a1"])
    }

    @Test func mergeWithPrevious() {
        var blocks = forest("- first\n- second\n")
        let result = OutlineOps.mergeWithPrevious([1], in: &blocks)
        expectNotNil(result)
        expectEqual(blocks.count, 1)
        expectEqual(blocks[0].content, "firstsecond")
        expectEqual(result?.0, blocks[0].id)
        expectEqual(result?.1, 5) // cursor lands where "first" ended
    }

    @Test func mergeRefusesWhenBlockHasChildren() {
        var blocks = forest("- first\n- second\n  - kid\n")
        expectNil(OutlineOps.mergeWithPrevious([1], in: &blocks))
        expectEqual(blocks.count, 2)
    }

    @Test func copyMarkdownIndents() {
        let blocks = forest("- parent\n  - child\n    - grandchild\n")
        expectEqual(OutlineOps.copyMarkdown(blocks[0]),
                    "- parent\n  - child\n    - grandchild\n")
    }

    @Test func pasteSplitsByListStructure() {
        let pasted = OutlineOps.blocksFromPasted("- one\n  - one-a\n- two\n")
        expectEqual(pasted.map(\.content), ["one", "two"])
        expectEqual(pasted[0].children.map(\.content), ["one-a"])
        // Raw is invalidated so re-serialization indents at the paste site.
        expectNil(pasted[0].raw)
        expectNil(pasted[0].children[0].raw)
    }

    @Test func pasteSplitsByLinesWithoutMarkers() {
        let pasted = OutlineOps.blocksFromPasted("alpha\nbeta\n\ngamma")
        expectEqual(pasted.map(\.content), ["alpha", "beta", "gamma"])
    }

    @Test func insertAfterLeafIsSibling() {
        var blocks = forest("- a\n- b\n")
        let id = OutlineOps.insertBlockAfter([0], in: &blocks, content: "x")
        expectEqual(blocks.map(\.content), ["a", "x", "b"])
        expectEqual(blocks[1].id, id)
    }

    @Test func structuralEditsKeepRoundTrippablePages() {
        // After arbitrary ops the serializer must still emit a parseable,
        // equivalent file (canonical for touched blocks, raw for others).
        var page = PageParser.parse("- a\n   - oddly indented child\n- b\n")
        _ = OutlineOps.indent([1], in: &page.blocks)
        let out = PageSerializer.serialize(page)
        let reparsed = PageParser.parse(out)
        expectEqual(reparsed.blocks.count, 1)
        expectEqual(reparsed.blocks[0].content, "a")
        expectEqual(reparsed.blocks[0].children.map(\.content),
                    ["oddly indented child", "b"])
    }
}
