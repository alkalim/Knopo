import Foundation
import Testing
@testable import KnopoCore

@Suite struct NumberedListTests {
    private func numbered(_ text: String = "", children: [Block] = [], logseq: Bool = false) -> Block {
        Block(content: text, children: children, properties: [BlockProperty(
            key: logseq ? "logseq.order-list-type" : "knopo.list-type",
            value: logseq ? "number" : "ordered")])
    }

    @Test func referenceFixtureAndMixedRuns() {
        let blocks = [numbered("One"), numbered("Two", children: [
            numbered("Four", logseq: true), numbered("Five"),
            numbered("Six", children: [numbered("Seven", logseq: true)])
        ], logseq: true), numbered("Three")]
        let markers = OutlineNumbering.markers(in: blocks)
        expectEqual(blocks.flattened.compactMap { markers[$0.id]?.label },
                    ["1.", "2.", "a.", "b.", "c.", "i.", "3."])
        expectEqual(markers[blocks[0].id]?.runID, markers[blocks[2].id]?.runID)
    }

    @Test func interruptionsAndFourLevels() {
        let blocks = [numbered(), Block(children: [numbered(children: [
            numbered(children: [numbered(children: [numbered()])])
        ])]), numbered(), numbered()]
        let markers = OutlineNumbering.markers(in: blocks)
        expectEqual(blocks.flattened.compactMap { markers[$0.id]?.label },
                    ["1.", "1.", "a.", "i.", "1.", "1.", "2."])
        expectTrue(markers[blocks[0].id]?.runID != markers[blocks[2].id]?.runID)
    }

    @Test func labelBoundaries() {
        expectEqual(OutlineNumbering.label(26, style: .alphabetic), "z")
        expectEqual(OutlineNumbering.label(27, style: .alphabetic), "aa")
        expectEqual(OutlineNumbering.label(28, style: .alphabetic), "ab")
        expectEqual(OutlineNumbering.label(49, style: .roman), "xlix")
        expectEqual(OutlineNumbering.label(3999, style: .roman), "mmmcmxcix")
        expectEqual(OutlineNumbering.label(4000, style: .roman), "4000")
    }

    @Test func eitherKeyUnknownValuesAndAuthoring() {
        var block = numbered(logseq: true)
        block.properties.append(BlockProperty(key: "knopo.list-type", value: "future"))
        let original = block.properties
        expectTrue(block.isNumbered)
        block.setNumbered(true)
        expectEqual(block.properties, original)
        block.setNumbered(false)
        expectTrue(block.properties.isEmpty)
        block.properties = [BlockProperty(key: "logseq.order-list-type", value: "future")]
        block.setNumbered(true)
        expectTrue(block.isNumbered)
        expectEqual(block.properties, [BlockProperty(key: "logseq.order-list-type", value: "future"),
                                       BlockProperty(key: "knopo.list-type", value: "ordered")])
        block.properties.append(BlockProperty(key: "logseq.order-list-type", value: "number"))
        block.setNumbered(false)
        expectTrue(block.numberingProperties.isEmpty)
    }

    @Test(arguments: ["knopo.list-type:: ordered", "logseq.order-list-type:: number"])
    func listEditsPreserveUntouchedRawSlicesAndNumberingProperties(property: String) {
        let text = "title:: page\r\n-  one\r\n  \(property)\r\n- two\r\n  \(property)"
        var page = PageParser.parse(text)
        expectEqual(PageSerializer.serialize(page), text)
        let raw = page.blocks.map(\.raw)
        _ = OutlineOps.insertBlockAfter([0], in: &page.blocks)
        expectEqual(page.blocks[0].raw, raw[0])
        expectEqual(page.blocks[2].raw, raw[1])
        expectTrue(page.blocks[1].isNumbered)
        expectEqual(page.blocks[1].numberingProperties.first?.key, "knopo.list-type")
        page.blocks[2].setEditableSource("changed")
        expectEqual(page.blocks[2].numberingProperties.first?.key,
                    property.hasPrefix("knopo") ? "knopo.list-type" : "logseq.order-list-type")
        expectEqual(page.blocks[0].raw, raw[0])
    }

    @Test func provisionalPropertiesAlwaysDeriveFromSnapshot() {
        for original in [Block(), numbered(logseq: true),
                         Block(properties: [BlockProperty(key: "knopo.list-type", value: "future")])] {
            var block = original
            let snapshot = block.numberingProperties
            for line in ["knopo.list-type:: ordered", "logseq.order-list-type:: number", "knopo.list-type:: none"] {
                block.setEditableSource("body\n" + line, numberingSnapshot: snapshot)
                expectEqual(block.properties.filter { $0.key == line.components(separatedBy: "::")[0] }.count, 1)
                block.setEditableSource("body", numberingSnapshot: snapshot)
                expectEqual(block.numberingProperties, snapshot)
                block.setEditableSource("body\n" + line, numberingSnapshot: snapshot)
                block.setEditableSource("body\n```\n" + line + "\n```", numberingSnapshot: snapshot)
                expectEqual(block.numberingProperties, snapshot)
                expectTrue(block.content.contains(line))
                block.setEditableSource("body\nnot a property", numberingSnapshot: snapshot)
                expectEqual(block.numberingProperties, snapshot)
            }
        }
        var imported = numbered(logseq: true)
        let snapshot = imported.numberingProperties
        imported.setEditableSource("knopo.list-type:: none", numberingSnapshot: snapshot)
        expectFalse(imported.isNumbered)
        expectFalse(imported.properties.contains { $0.key == "logseq.order-list-type" })
        imported.setEditableSource("", numberingSnapshot: snapshot)
        expectEqual(imported.numberingProperties, snapshot)
    }

    @Test(arguments: ["```", "~~~"])
    func allFencedPropertiesRemainContent(fence: String) {
        var block = numbered(logseq: true)
        let text = fence + "swift\nstatus:: x\nknopo.list-type:: none\nlogseq.order-list-type:: number\nbackground-color:: red\n" + fence
        block.setEditableSource(text)
        expectEqual(block.content, text)
        expectEqual(block.properties, numbered(logseq: true).properties)
        let reloaded = PageParser.parse(PageSerializer.serialize(ParsedPage(blocks: [block]))).blocks[0]
        expectEqual(reloaded.content, text)
        expectEqual(reloaded.properties, block.properties)
    }

    @Test func clipboardUsesDecimalAndRealContentColumns() {
        let blocks = (1...10).map { i in numbered("item \(i)\ncontinued", children: [numbered("child")]) }
        let text = OutlineOps.copyMarkdown(blocks)
        expectTrue(text.contains("9. item 9\n   continued\n   1. child"))
        expectTrue(text.contains("10. item 10\n    continued\n    1. child"))
        expectFalse(text.contains("list-type"))
        let pasted = OutlineOps.blocksFromPasted(text)
        expectEqual(pasted.count, 10)
        expectTrue(pasted.allSatisfy { $0.isNumbered && $0.children.first?.isNumbered == true })
        expectEqual(pasted.last?.content, "item 10\ncontinued")
        expectEqual(pasted.last?.children.first?.content, "child")
        let reopened = PageParser.parse(PageSerializer.serialize(ParsedPage(blocks: pasted)))
        expectEqual(reopened.blocks.flattened.map(\.content), pasted.flattened.map(\.content))
        expectEqual(reopened.blocks.flattened.map(\.isNumbered), pasted.flattened.map(\.isNumbered))
    }

    @Test func clipboardMarkerRecognitionIsLimitedAndFenceAware() {
        let pasted = OutlineOps.blocksFromPasted("12) first\n    - bullet\n    8. numbered\n13. \n- ```\n  99. literal\n  knopo.list-type:: ordered\n  ```\na. literal\ni. literal\nI. literal\n1234567890. literal")
        expectEqual(pasted[0].content, "first")
        expectTrue(pasted[0].isNumbered)
        expectEqual(pasted[0].children.map(\.isNumbered), [false, true])
        expectTrue(pasted[1].isNumbered)
        expectTrue(pasted[1].content.isEmpty)
        expectTrue(pasted[2].content.contains("99. literal"))
        expectTrue(pasted[2].properties.isEmpty)
        expectEqual(pasted.suffix(4).map(\.content), ["a. literal", "i. literal", "I. literal", "1234567890. literal"])
        expectFalse(PageParser.parse("- 1. literal\n").blocks[0].isNumbered)
        expectTrue(PageParser.parse("1. literal\n").blocks.isEmpty)
    }

    @Test func numericClipboardTabsUseTheirContentColumns() {
        let pasted = OutlineOps.blocksFromPasted("1.\tparent\n\tcontinued\n\t2. child\n10. next\n\tcontinued")
        expectEqual(pasted.map(\.content), ["parent\ncontinued", "next\ncontinued"])
        expectEqual(pasted[0].children.map(\.content), ["child"])
        expectTrue(pasted[0].children[0].isNumbered)
    }

    @Test func tabbedBulletClipboardKeepsNestedProperties() {
        let pasted = OutlineOps.blocksFromPasted("- a\n\t- b\n\t\tlogseq.order-list-type:: number\n\t\t- c")
        expectEqual(pasted.count, 1)
        expectEqual(pasted[0].children.map(\.content), ["b"])
        expectTrue(pasted[0].children[0].isNumbered)
        expectEqual(pasted[0].children[0].children.map(\.content), ["c"])
    }

    @Test func copiedLiteralNumberedLinesStayInTheBody() {
        let original = Block(content: "Steps\n1. literal\n2) literal\n3.\n4)\n5\\. escaped")
        let text = OutlineOps.copyMarkdown(original)
        let pasted = OutlineOps.blocksFromPasted(text)
        expectEqual(pasted.count, 1)
        expectTrue(pasted[0].children.isEmpty)
        expectFalse(pasted[0].isNumbered)
        expectEqual(pasted[0].content, original.content)
        let fenced = Block(content: "```\n1. code\n2) code\n```")
        expectEqual(OutlineOps.blocksFromPasted(OutlineOps.copyMarkdown(fenced))[0].content, fenced.content)
    }

    @Test(arguments: ["3.", "3)", "3.\r\n", "3)\r\n"])
    func emptyClipboardMarkerNeedsNoTrailingSpace(_ text: String) {
        let pasted = OutlineOps.blocksFromPasted(text)
        expectEqual(pasted.count, 1)
        expectTrue(pasted[0].isNumbered)
        expectTrue(pasted[0].content.isEmpty)
    }

    @Test(arguments: [false, true])
    func placeholderPastePreservesIdentityAndProperties(logseq: Bool) {
        let placeholder = numbered(logseq: logseq)
        var blocks = [placeholder]
        _ = OutlineOps.paste("one\ntwo", at: [0], focusedSourceIsEmpty: true, in: &blocks)
        expectEqual(blocks[0].id, placeholder.id)
        expectEqual(blocks[0].numberingProperties, placeholder.numberingProperties)
        expectEqual(blocks[1].numberingProperties.first?.key, "knopo.list-type")
        expectEqual(blocks.map(\.content), ["one", "two"])
        blocks = [placeholder]
        _ = OutlineOps.paste("- one\n2. two", at: [0], focusedSourceIsEmpty: true, in: &blocks)
        expectFalse(blocks[0].isNumbered)
        expectTrue(blocks[1].isNumbered)
        blocks = [placeholder]
        _ = OutlineOps.paste("3. one", at: [0], focusedSourceIsEmpty: true, in: &blocks)
        expectEqual(blocks[0].numberingProperties, placeholder.numberingProperties)
        var withUser = placeholder
        withUser.properties.append(BlockProperty(key: "status", value: "active"))
        blocks = [withUser]
        _ = OutlineOps.paste("one\ntwo", at: [0], focusedSourceIsEmpty: false, in: &blocks)
        expectEqual(blocks[0].properties, withUser.properties)
        expectEqual(blocks.map(\.content), ["", "one", "two"])
        expectFalse(blocks[1].isNumbered)
    }

    @Test func zoomPasteKeepsExistingChildrenAndVisibleProperties() {
        var root = numbered(children: [numbered("old")], logseq: true)
        var blocks = [root]
        _ = OutlineOps.paste("first\nsecond", at: [0], focusedSourceIsEmpty: true,
                             zoomRoot: root.id, in: &blocks)
        expectEqual(blocks[0].id, root.id)
        expectEqual(blocks[0].content, "first")
        expectEqual(blocks[0].children.map(\.content), ["second", "old"])
        expectEqual(blocks[0].numberingProperties, root.numberingProperties)
        root.properties.append(BlockProperty(key: "status", value: "active"))
        blocks = [root]
        _ = OutlineOps.paste("first\nsecond", at: [0], focusedSourceIsEmpty: false,
                             zoomRoot: root.id, in: &blocks)
        expectEqual(blocks[0].content, "")
        expectEqual(blocks[0].children.map(\.content), ["first", "second", "old"])
    }

    @Test func splitContinuationUsesNativeProperties() {
        var blocks = [numbered("body", logseq: true)]
        _ = OutlineOps.split([0], at: 0, in: &blocks)
        expectTrue(blocks[0].isNumbered)
        expectEqual(blocks[0].numberingProperties.first?.key, "knopo.list-type")
        expectEqual(blocks[1].numberingProperties.first?.key, "logseq.order-list-type")
        _ = OutlineOps.split([1], at: 2, in: &blocks)
        expectEqual(blocks[2].content, "dy")
        expectEqual(blocks[2].numberingProperties.first?.key, "knopo.list-type")
        blocks = [numbered("parent", children: [Block(content: "child")], logseq: true)]
        _ = OutlineOps.split([0], at: 6, in: &blocks)
        expectFalse(blocks[0].children[0].isNumbered)
        blocks[0].children[0].setNumbered(true)
        _ = OutlineOps.splitZoomRoot([0], at: 6, in: &blocks)
        expectEqual(blocks[0].children[0].numberingProperties.first?.key, "knopo.list-type")
    }
    @Test func contentOnlyIndexUpdatesReuseNumberingWithoutSQLReads() throws {
        let cache = try CacheDB()
        var page = PageDocument(name: "Numbers", blocks: [numbered("one"), numbered("two")])
        try cache.indexPage(page, stamp: nil)
        let original = try cache.numberingSnapshot(onPageNamed: page.name)
        let reads = cache.numberingReadCount
        for i in 0..<10 {
            page.blocks[0].content = "edited \(i)"
            try cache.indexPage(page, stamp: nil)
            expectTrue(try cache.numberingSnapshot(onPageNamed: page.name) === original)
        }
        expectEqual(cache.numberingReadCount, reads)
        page.blocks[0].setNumbered(false)
        try cache.indexPage(page, stamp: nil)
        let changed = try cache.numberingSnapshot(onPageNamed: page.name)
        expectFalse(changed === original)
        expectEqual(changed.markers[page.blocks[1].id]?.label, "1.")
        try cache.clearAll()
        expectTrue(try cache.numberingSnapshot(onPageNamed: page.name).markers.isEmpty)
    }

    @Test func rebuildKeepsIndexedIdentityDuringUnsavedStructuralEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("numbering-rebuild-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try GraphStore(root: dir)
        var page = try writer.createPage(named: "Numbers")
        page.blocks = [numbered("one #match"), numbered("two #match"), numbered("three #match")]
        writer.updatePage(page)
        try writer.savePage(named: page.name)
        let store = try GraphStore(root: dir)
        let originalHits = try store.cache.blocks(taggedWith: "match")
        var live = store.page(named: page.name)
        expectEqual(live.blocks.map(\.id), originalHits.map(\.blockID))
        live.blocks.insert(numbered("inserted"), at: 0)
        live.blocks.remove(at: 2)
        store.updatePage(live)
        try store.indexMaintenance.rebuild()
        let rebuiltHits = try store.cache.blocks(taggedWith: "match")
        expectEqual(rebuiltHits.map(\.blockID), originalHits.map(\.blockID))
        let source = try store.numbering(onPageNamed: page.name)
        expectEqual(rebuiltHits.map { source.markers[$0.blockID]?.label }, ["2.", nil, "3."])
        try store.savePage(named: page.name)
        expectEqual(try store.cache.blocks(taggedWith: "match").map(\.blockID),
                    [originalHits[0].blockID, originalHits[2].blockID])
    }

    @Test func supersededSaveNeverAliasesADeletedBlockToItsNeighbor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("numbering-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GraphStore(root: dir)
        var page = try store.createPage(named: "Numbers")
        page.blocks = [numbered("one #match"), numbered("two #match")]
        store.updatePage(page)
        let snapshot = try #require(store.pageSaveSnapshot(named: page.name))
        let deleted = page.blocks.removeFirst().id
        store.updatePage(page)
        _ = try store.persistPageSnapshot(snapshot)
        expectFalse(store.finishPageSave(snapshot))
        let labels = try store.numbering(onPageNamed: page.name).markers
        expectTrue(labels[deleted] == nil)
        expectEqual(labels[page.blocks[0].id]?.label, "1.")
    }

}
