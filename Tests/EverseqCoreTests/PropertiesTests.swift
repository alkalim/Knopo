import Testing
import Foundation
@testable import EverseqCore

/// First-class properties: the editor edits `editableSource`; `setEditableSource`
/// re-splits content vs. user properties while preserving id/collapsed (§3.2).
@Suite struct PropertiesTests {

    @Test func editableSourceShowsUserPropsNotMachineProps() {
        let block = Block(
            content: "the block",
            collapsed: true,
            idPersisted: true,
            properties: [BlockProperty(key: "status", value: "blocked"),
                         BlockProperty(key: "owner", value: "alex")]
        )
        // Content + user property lines; id/collapsed hidden.
        expectEqual(block.editableSource, "the block\nstatus:: blocked\nowner:: alex")
    }

    @Test func setEditableSourceSplitsContentAndProps() {
        var block = Block(content: "old")
        block.setEditableSource("hello world\nstatus:: blocked\nmore text\nowner:: alex")
        // Property lines are lifted out wherever they appear; the rest is content.
        expectEqual(block.content, "hello world\nmore text")
        expectEqual(block.properties, [
            BlockProperty(key: "status", value: "blocked"),
            BlockProperty(key: "owner", value: "alex"),
        ])
    }

    @Test func setEditableSourcePreservesMachineProps() {
        var block = Block(content: "x", collapsed: true, idPersisted: true)
        let id = block.id
        block.setEditableSource("x\nstatus:: done")
        expectTrue(block.collapsed)      // not shown in editor → untouched
        expectTrue(block.idPersisted)
        expectEqual(block.id, id)
        expectEqual(block.properties, [BlockProperty(key: "status", value: "done")])
        // A typed id::/collapsed:: line is treated as content, not hijacked.
        block.setEditableSource("x\nid:: nope\ncollapsed:: maybe")
        expectEqual(block.content, "x\nid:: nope\ncollapsed:: maybe")
        expectEqual(block.properties, [])
        expectTrue(block.idPersisted) // still preserved
    }

    @Test func backgroundColorIsHiddenButPreserved() {
        // `background-color::` is a hidden display property (set via the bullet
        // menu): it stays out of the editor but survives an edit round-trip.
        var block = Block(
            content: "colored block",
            properties: [BlockProperty(key: "background-color", value: "blue"),
                         BlockProperty(key: "status", value: "open")]
        )
        // Editor shows the user prop but not the hidden color.
        expectEqual(block.editableSource, "colored block\nstatus:: open")
        // Editing the body (color not shown) keeps the color.
        block.setEditableSource("colored block edited\nstatus:: open")
        expectEqual(block.content, "colored block edited")
        expectTrue(block.properties.contains(BlockProperty(key: "background-color", value: "blue")))
        expectTrue(block.properties.contains(BlockProperty(key: "status", value: "open")))
    }

    @Test func backgroundColorRoundTripsInFile() {
        let page = "- colored block\n  background-color:: green\n"
        let parsed = PageParser.parse(page)
        expectEqual(parsed.blocks.first?.properties,
                    [BlockProperty(key: "background-color", value: "green")])
        expectEqual(PageSerializer.serialize(parsed), page)
    }

    @Test func editRoundTripThroughEditableSource() {
        // What the editor shows, edited and set back, is stable.
        var block = Block(content: "note",
                          properties: [BlockProperty(key: "tags", value: "a, b")])
        let shown = block.editableSource
        block.setEditableSource(shown)
        expectEqual(block.content, "note")
        expectEqual(block.properties, [BlockProperty(key: "tags", value: "a, b")])
    }

    @Test func addingPropertyByTyping() {
        var block = Block(content: "just text")
        expectEqual(block.editableSource, "just text")
        // User appends a property line in the editor.
        block.setEditableSource("just text\npriority:: high")
        expectEqual(block.content, "just text")
        expectEqual(block.properties, [BlockProperty(key: "priority", value: "high")])
    }

    @Test func propertiesRoundTripInFile() {
        // The whole pipeline: file → parse → editableSource → edit → serialize.
        let text = "- a task\n  status:: open\n  id:: 11111111-2222-3333-4444-555555555555\n"
        var page = PageParser.parse(text)
        // The editor would show content + status, not id.
        expectEqual(page.blocks[0].editableSource, "a task\nstatus:: open")
        // Edit the value; serialize keeps id:: and the updated property.
        page.blocks[0].setEditableSource("a task\nstatus:: done")
        let out = PageSerializer.serialize(page)
        expectEqual(out,
            "- a task\n  status:: done\n  id:: 11111111-2222-3333-4444-555555555555\n")
    }
}
