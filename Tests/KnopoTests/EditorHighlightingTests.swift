import AppKit
import Testing
@testable import Knopo

@MainActor
@Suite struct EditorHighlightingTests {
    @Test func linkColorsPreserveBoundariesAndIncompleteText() throws {
        let cases: [(String, [String])] = [
            ("before [label](url) after", ["[label](url)"]),
            ("[a](x) [b](y)", ["[a](x)", "[b](y)"]),
            ("[[label](url)", ["[[label](url)"]),
            ("![image](x.png)", ["[image](x.png)"]),
            ("[]()", ["[]()"]),
            ("[label] (url)", []),
            ("[unfinished", []),
            ("[unfinished]", []),
            ("[unfinished](url", []),
            ("[broken] [real](url)", ["[real](url)"]),
            ("[broken\n[real](url)", ["[real](url)"]),
            ("[broken](\n[real](url)", ["[real](url)"]),
            (#"\[escaped](url) [real](url)"#, ["[real](url)"]),
            (#"\[[inner](url)"#, ["[inner](url)"]),
            ("👩🏽‍💻 e\u{301} [label](url)", ["[label](url)"]),
            ("[outer](unfinished [inner](url)", ["[outer](unfinished [inner](url)"]),
            ("`[label](url)`", ["[label](url)"]),
            ("```\n[label](url)\n```", []),
            ("[[Page]] #[[tag]] [label](url)", ["[[Page]]", "[label](url)"]),
        ]
        let editor = BlockEditorTextView.create()
        for (source, links) in cases {
            editor.setContent(source)
            let storage = try #require(editor.textStorage)
            #expect(storage.string == source)
            let ranges = links.map { (source as NSString).range(of: $0) }
            #expect(ranges.allSatisfy { $0.location != NSNotFound })
            for index in 0..<storage.length {
                let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
                #expect((color == .linkColor) == ranges.contains { NSLocationInRange(index, $0) },
                        "Source: \(source), UTF-16 offset: \(index)")
            }
        }
    }
}
