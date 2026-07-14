import Testing
import Foundation
@testable import KnopoCore

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

    @Test func indentRunTucksSiblingsUnderPrevious() {
        var blocks = forest("- a\n- b\n  - b1\n- c\n- d\n")
        // Indent [b, c, d] under a — subtrees intact, in order.
        expectTrue(OutlineOps.indentRun([[1], [2], [3]], in: &blocks))
        expectEqual(blocks.map(\.content), ["a"])
        expectEqual(blocks[0].children.map(\.content), ["b", "c", "d"])
        expectEqual(blocks[0].children[0].children.map(\.content), ["b1"])
    }

    @Test func indentRunRequiresPrecedingSibling() {
        var blocks = forest("- a\n- b\n")
        expectFalse(OutlineOps.indentRun([[0], [1]], in: &blocks)) // run starts at index 0
        expectEqual(blocks.map(\.content), ["a", "b"])
    }

    @Test func outdentRunLiftsContiguousChildrenWithoutAdopting() {
        var blocks = forest("- p\n  - x\n  - b\n  - c\n  - y\n")
        // Lift [b, c] to top level after p; x and y stay under p (no adoption).
        expectTrue(OutlineOps.outdentRun([[0, 1], [0, 2]], in: &blocks))
        expectEqual(blocks.map(\.content), ["p", "b", "c"])
        expectEqual(blocks[0].children.map(\.content), ["x", "y"])
        expectEqual(blocks[1].children.count, 0)
    }

    @Test func indentOutdentRunRejectInvalidRuns() {
        var blocks = forest("- a\n- b\n- c\n- d\n")
        expectFalse(OutlineOps.indentRun([[1], [3]], in: &blocks))   // non-contiguous
        expectFalse(OutlineOps.outdentRun([[0], [1]], in: &blocks))  // top level, no parent
        expectEqual(blocks.map(\.content), ["a", "b", "c", "d"])     // unchanged
    }

    @Test func moveRunMovesContiguousSiblingsAsUnit() {
        var blocks = forest("- a\n- b\n- c\n- d\n")
        expectTrue(OutlineOps.moveRun([[1], [2]], by: 1, in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "d", "b", "c"])
        expectTrue(OutlineOps.moveRun([[2], [3]], by: -1, in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "b", "c", "d"])
        // Boundary: a run touching the edge can't move past it (no mutation).
        expectFalse(OutlineOps.moveRun([[0], [1]], by: -1, in: &blocks))
        expectFalse(OutlineOps.moveRun([[2], [3]], by: 1, in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "b", "c", "d"])
    }

    @Test func moveToReparentsUnderNewParent() {
        var blocks = forest("- a\n  - a1\n- b\n")
        // Drop `a` (with subtree) as first child of `b`.
        expectTrue(OutlineOps.move([[0]], to: [1, 0], in: &blocks))
        expectEqual(blocks.map(\.content), ["b"])
        expectEqual(blocks[0].children.map(\.content), ["a"])
        expectEqual(blocks[0].children[0].children.map(\.content), ["a1"])
        // Depth changed → subtree re-serializes canonically.
        expectNil(blocks[0].children[0].raw)
    }

    @Test func moveToAdjustsIndexAndKeepsOrder() {
        var blocks = forest("- a\n- b\n- c\n- d\n")
        // Non-contiguous multi-drag (a, c) to the end keeps visual order.
        expectTrue(OutlineOps.move([[0], [2]], to: [4], in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "d", "a", "c"])
        // Moving down within one parent lands after the removal shift.
        expectTrue(OutlineOps.move([[0]], to: [3], in: &blocks))
        expectEqual(blocks.map(\.content), ["d", "a", "b", "c"])
    }

    @Test func moveToRejectsOwnSubtreeAndNormalizesDescendants() {
        var blocks = forest("- a\n  - a1\n- b\n")
        // Into its own subtree: rejected, nothing mutated.
        expectFalse(OutlineOps.move([[0]], to: [0, 1], in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "b"])
        // A selected descendant travels with its ancestor, not twice.
        expectTrue(OutlineOps.move([[0], [0, 0]], to: [2], in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "a"])
        expectEqual(blocks[1].children.map(\.content), ["a1"])
    }

    @Test func insertIntoCollapsedParentAndExpand() {
        // The drop-on-a-collapsed-block flow: insert as first child, then
        // expand the parent so the result is visible. Guards the invariant the
        // outline's acceptDrop relies on, through serialization.
        var blocks = forest("- p\n  collapsed:: true\n  - c\n- b\n")
        expectTrue(blocks[0].collapsed)
        blocks.insert(Block(content: "![img](../assets/img.png)"), at: [0, 0])
        blocks.update(at: [0]) { $0.collapsed = false }

        expectEqual(OutlineOps.visibleRows(in: blocks).map(\.block.content),
                    ["p", "![img](../assets/img.png)", "c", "b"])
        // Survives a save/load cycle: collapsed:: is gone, the child persists.
        let reparsed = PageParser.parse(
            PageSerializer.serialize(preamble: "", blocks: blocks))
        expectFalse(reparsed.blocks[0].collapsed)
        expectEqual(reparsed.blocks[0].children.map(\.content),
                    ["![img](../assets/img.png)", "c"])
    }

    @Test func moveToLiftsChildToTopLevel() {
        var blocks = forest("- a\n  - a1\n  - a2\n- b\n")
        expectTrue(OutlineOps.move([[0, 1]], to: [1], in: &blocks))
        expectEqual(blocks.map(\.content), ["a", "a2", "b"])
        expectEqual(blocks[0].children.map(\.content), ["a1"])
    }

    @Test func moveRunCarriesSubtreesAndRejectsNonSiblings() {
        var blocks = forest("- a\n- b\n  - b1\n- c\n  - c1\n")
        expectTrue(OutlineOps.moveRun([[1], [2]], by: -1, in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "c", "a"])
        expectEqual(blocks[0].children.map(\.content), ["b1"])
        expectEqual(blocks[1].children.map(\.content), ["c1"])
        // Non-siblings and non-contiguous runs are rejected without mutation.
        expectFalse(OutlineOps.moveRun([[0], [0, 0]], by: 1, in: &blocks))
        expectFalse(OutlineOps.moveRun([[0], [2]], by: 1, in: &blocks))
        expectEqual(blocks.map(\.content), ["b", "c", "a"])
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
