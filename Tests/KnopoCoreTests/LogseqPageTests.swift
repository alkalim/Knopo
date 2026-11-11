import Testing
import Foundation
@testable import KnopoCore

@Suite struct LogseqPageTests {
    @Test(arguments: ["\n", "\r\n", "\r"], [false, true])
    func pageTitlePrecedesFirstBlockTitleWithoutChangingSource(newline: String, journal: Bool) {
        let name = journal ? "2026-06-10" : "Original"
        let fallback = journal ? "Jun 10th, 2026" : name
        let cases: [(String, String)] = [
            ("title:: Page title\n", "Page title"),
            ("title::  Page title \n", " Page title "),
            ("title:: Page title\n- Body\n  title:: Block title\n", "Page title"),
            ("- title:: Block title\n", "Block title"),
            ("- Body\n  title:: Block title\n", "Block title"),
            ("title::\n- Body\n  title:: Block title\n", "Block title"),
            ("title::   \n- Body\n  title:: Block title\n", "Block title"),
            ("```\ntitle:: Example\n```\n- Body\n  title:: Block title\n", "Block title"),
            ("title::\n- Body\n", fallback),
            ("title::   \n", fallback),
            ("- First\n- Second\n  title:: Later block\n", fallback),
        ]
        for (source, expected) in cases {
            let source = source.replacingOccurrences(of: "\n", with: newline)
            let parsed = PageParser.parse(source)
            let document = PageDocument(name: name, blocks: parsed.blocks,
                                        preamble: parsed.preamble, isJournal: journal)
            expectEqual(document.displayTitle(using: JournalDateFormat(rawValue: "MMM d{ordinal}, yyyy"),
                                              locale: Locale(identifier: "en_US")), expected)
            expectEqual(document.name, name)
            expectEqual(document.nameKey, PageName.key(name))
            expectEqual(PageSerializer.serialize(preamble: document.preamble, blocks: document.blocks), source)
        }
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func headingsKeepSourceAndOutlineStructure(newline: String) throws {
        let text = ["tags:: project", "", "# First [[Target]]", "paragraph", "  - child",
                    "- sibling", "## Second", "last line"].joined(separator: newline)
        let page = PageParser.parse(text)
        expectEqual(PageSerializer.serialize(page), text)
        expectEqual(page.preamble, "tags:: project" + newline + newline)
        expectEqual(page.blocks.map(\.content), ["# First [[Target]]\nparagraph", "sibling", "## Second\nlast line"])
        let first = try #require(page.blocks.first)
        expectEqual(first.children.map(\.content), ["child"])
        expectEqual(first.raw?.depth, 0)
    }

    @Test func editingHeadingOnlyNormalizesThatBlock() throws {
        let text = "tags:: project\r\n# Heading\r\n  - child\r\n- sibling\r\n## Other"
        var page = PageParser.parse(text)
        try #require(page.blocks.count == 3)
        page.blocks[0].setEditableSource("# Changed")
        let saved = PageSerializer.serialize(page)
        expectEqual(saved, "tags:: project\r\n- # Changed\n  - child\r\n- sibling\r\n## Other")
        let reopened = PageParser.parse(saved)
        expectEqual(reopened.blocks.map(\.content), ["# Changed", "sibling", "## Other"])
        expectEqual(reopened.blocks[0].children.map(\.content), ["child"])
    }

    @Test func movingHeadingUnderAnotherBlockKeepsItsChildren() throws {
        var page = PageParser.parse("# Heading\n  - child\n- Parent\n")
        try #require(page.blocks.count == 2)
        let heading = page.blocks.removeFirst()
        page.blocks[0].children.append(heading)
        let text = PageSerializer.serialize(page)
        expectEqual(text, "- Parent\n  - # Heading\n    - child\n")
        let reopened = PageParser.parse(text)
        expectEqual(reopened.blocks[0].children.first?.content, "# Heading")
    }

    @Test func headingIDsAndBlockPropertiesStayOnTheHeading() throws {
        let id = UUID()
        let text = "status:: open\n# Heading\nid:: \(id)\nstatus:: closed\ncollapsed:: true\n  - child\n"
        let parsed = PageParser.parse(text)
        let block = try #require(parsed.blocks.first)
        expectEqual(block.id, id)
        expectTrue(block.idPersisted)
        expectTrue(block.collapsed)
        expectEqual(block.properties, [BlockProperty(key: "status", value: "closed")])
        expectEqual(parsed.preamble, "status:: open\n")
        expectEqual(PageSerializer.serialize(parsed), text)
    }

    @Test func fencedAndIndentedHeadingsDoNotBecomeBlocks() {
        let text = "```markdown\n# Example\nstatus:: example\n```\n# Real\n~~~\n## Code\n~~~\n- Body\n  # Continuation\n#tag\n####### Too many\n"
        let parsed = PageParser.parse(text)
        expectEqual(parsed.blocks.map(\.content), ["# Real\n~~~\n## Code\n~~~", "Body\n# Continuation\n#tag\n####### Too many"])
        expectEqual(PageSerializer.serialize(parsed), text)
        expectTrue(PageDocument(name: "Test", preamble: parsed.preamble).preambleProperties.isEmpty)
    }

    @Test func pagePropertyEditsPreserveOtherLinesAndDuplicateKeys() {
        var doc = PageDocument(name: "Test", preamble: "status:: open\r\n\r\nstatus::  duplicate\r\nuntouched text\r\nempty::")
        let original = doc.preamble
        expectTrue(doc.setPreambleProperty(at: 0, to: BlockProperty(key: "status", value: "open")))
        expectEqual(doc.preamble, original)
        expectTrue(doc.setPreambleProperty(at: 2, to: BlockProperty(key: "empty", value: "filled")))
        expectTrue(doc.setPreambleProperty(at: 0, to: nil))
        expectEqual(doc.preamble, "\r\nstatus::  duplicate\r\nuntouched text\r\nempty:: filled")
        expectTrue(doc.setPreambleProperty(at: 2, to: BlockProperty(key: "new", value: "value")))
        expectEqual(doc.preamble, "\r\nstatus::  duplicate\r\nuntouched text\r\nempty:: filled\r\nnew:: value\r\n")
        expectEqual(doc.preambleProperties.map(\.value), [" duplicate", "filled", "value"])
    }

    @Test func newPagePropertiesPrecedeUnclosedPreambleFences() {
        var doc = PageDocument(name: "Test", preamble: "```\nexample")
        expectTrue(doc.setPreambleProperty(at: 0, to: BlockProperty(key: "type", value: "project")))
        expectEqual(doc.preamble, "type:: project\n```\nexample")
        expectEqual(doc.preambleProperties, [BlockProperty(key: "type", value: "project")])
    }

    @Test func unclosedPreambleFenceDoesNotHideExistingOrNewBlocks() {
        for opener in ["```", "```example```", "~~~~"] {
            var page = PageParser.parse(opener + "\n- existing\n# Heading\n")
            expectEqual(page.blocks.map(\.content), ["existing", "# Heading"])
            page.blocks.append(Block(content: "new"))
            let saved = PageSerializer.serialize(page)
            expectEqual(PageParser.parse(saved).blocks.map(\.content), ["existing", "# Heading", "new"])
            page.blocks.append(Block(content: "```swift\nlet x = 1\n```"))
            let withCode = PageParser.parse(PageSerializer.serialize(page))
            expectEqual(withCode.blocks.map(\.content), ["existing", "# Heading", "new", "```swift\nlet x = 1\n```"])
        }
    }

    @Test func closedPreambleFenceKeepsOutlineExamplesAsCode() {
        let example = "```\n- existing\n# Setup\n```bash\necho example\n```\n"
        let source = example + "# Real heading\n- editable\n"
        let parsed = PageParser.parse(source)
        expectEqual(parsed.preamble, example)
        expectEqual(parsed.blocks.map(\.content), ["# Real heading", "editable"])
        expectEqual(PageSerializer.serialize(parsed), source)
    }

    @Test func invalidPagePropertyEditsDoNotChangeSource() {
        var doc = PageDocument(name: "Test", preamble: "status:: open\n")
        let original = doc.preamble
        for property in [BlockProperty(key: "not a key", value: "x"),
                         BlockProperty(key: "valid", value: "x\n# injected block"),
                         BlockProperty(key: "valid", value: "x\r\n- injected block")] {
            expectFalse(doc.setPreambleProperty(at: 0, to: property))
            expectEqual(doc.preamble, original)
        }
        expectFalse(doc.setPreambleProperty(at: -1, to: nil))
        expectFalse(doc.setPreambleProperty(at: 1, to: nil))
        expectFalse(doc.setPreambleProperty(at: 2, to: BlockProperty(key: "valid", value: "x")))
        expectEqual(doc.preamble, original)
    }

    @Test func insertedPropertyPreservesFollowingRowsAndPreamble() {
        var document = PageDocument(name: "Test", preamble: "tags:: original\r\n\r\nstatus::  keep\r\nOther text\r\n")
        expectTrue(document.insertPreambleProperty(BlockProperty(key: "owner", value: "Alex"), at: 1))
        expectEqual(document.preamble, "tags:: original\r\n\r\nowner:: Alex\r\nstatus::  keep\r\nOther text\r\n")
        let original = document.preamble
        expectFalse(document.insertPreambleProperty(BlockProperty(key: "invalid key", value: "x"), at: 1))
        expectFalse(document.insertPreambleProperty(BlockProperty(key: "valid", value: "x"), at: 9))
        expectEqual(document.preamble, original)
    }
}
