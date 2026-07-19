import Testing
import Foundation
@testable import KnopoCore

@Suite struct InlineParserTests {

    @Test func pageRef() {
        expectEqual(
            InlineParser.parse("see [[Project X]] now"),
            [.text("see "), .pageRef("Project X"), .text(" now")]
        )
    }

    @Test func blockRef() {
        let id = UUID(uuidString: "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f")!
        expectEqual(
            InlineParser.parse("((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))"),
            [.blockRef(id)]
        )
        // Invalid uuid stays literal.
        expectEqual(InlineParser.parse("((nope))"), [.text("((nope))")])
    }

    @Test func backslashEscapesSpecials() {
        // An escaped special renders as literal text — never a tag/ref/query.
        expectEqual(InlineParser.parse("\\#foo"), [.text("#foo")])
        expectEqual(InlineParser.parse("\\[[Page]]"), [.text("[[Page]]")])
        expectEqual(
            InlineParser.parse("\\((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))"),
            [.text("((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f))")])
        expectEqual(InlineParser.parse("\\{{query (x)}}"), [.text("{{query (x)}}")])
        // Formatting markers too: code, emphasis, and math.
        expectEqual(InlineParser.parse("\\`code`"), [.text("`code`")])
        expectEqual(InlineParser.parse("\\*not italic*"), [.text("*not italic*")])
        expectEqual(InlineParser.parse("I have \\$5 and $10"), [.text("I have $5 and $10")])
        // Unescaped still works; a backslash before an ordinary char is literal.
        expectEqual(InlineParser.parse("#foo"), [.tag("foo")])
        expectEqual(InlineParser.parse("a\\b"), [.text("a\\b")])
        // The index side (RefExtractor) skips the escaped token, keeps the real one.
        expectEqual(RefExtractor.extract(from: "\\#foo and #bar").tags, ["bar"])
    }

    @Test func tags() {
        expectEqual(
            InlineParser.parse("a #Urgent b"),
            [.text("a "), .tag("urgent"), .text(" b")]
        )
        expectEqual(
            InlineParser.parse("#[[multi word tag]]"),
            [.tag("multi word tag")]
        )
        // Not a tag mid-word, after '#' alone, or before space.
        expectEqual(InlineParser.parse("foo#bar"), [.text("foo#bar")])
        expectEqual(InlineParser.parse("# heading-ish"), [.text("# heading-ish")])
    }

    @Test func tagIsNotPageRef() {
        // #[[x]] is a tag, never a page ref. (SPEC §8)
        let nodes = InlineParser.parse("#[[project x]]")
        expectEqual(nodes, [.tag("project x")])
    }

    @Test func emphasisNesting() {
        expectEqual(
            InlineParser.parse("**bold [[P]]**"),
            [.bold([.text("bold "), .pageRef("P")])]
        )
        expectEqual(
            InlineParser.parse("*it*"),
            [.italic([.text("it")])]
        )
        expectEqual(
            InlineParser.parse("~~gone~~ ==hot=="),
            [.strike([.text("gone")]), .text(" "), .highlight([.text("hot")])]
        )
    }

    @Test func boldItalic() {
        // `***x***` is CommonMark strong+emphasis: bold wrapping italic.
        expectEqual(
            InlineParser.parse("***bi***"),
            [.bold([.italic([.text("bi")])])]
        )
        expectEqual(
            InlineParser.parse("a ***b*** c"),
            [.text("a "), .bold([.italic([.text("b")])]), .text(" c")]
        )
        // Plain bold/italic are unaffected by the new triple-star branch.
        expectEqual(InlineParser.parse("**b**"), [.bold([.text("b")])])
        expectEqual(InlineParser.parse("*i*"), [.italic([.text("i")])])
    }

    @Test func codeSpanSuppressesRefs() {
        expectEqual(
            InlineParser.parse("`[[not a ref]] #notag`"),
            [.code("[[not a ref]] #notag")]
        )
    }

    @Test func linkAndImage() {
        expectEqual(
            InlineParser.parse("[label](https://x.y)"),
            [.link(label: "label", url: "https://x.y")]
        )
        expectEqual(
            InlineParser.parse("![alt](pic.png)"),
            [.image(alt: "alt", src: "pic.png")]
        )
    }

    @Test func bareURLAutolinks() {
        expectEqual(
            InlineParser.parse("see https://example.com/x now"),
            [.text("see "), .autolink("https://example.com/x"), .text(" now")]
        )
        expectEqual(InlineParser.parse("http://a.b"), [.autolink("http://a.b")])
        // Trailing sentence punctuation is shed from the link.
        expectEqual(
            InlineParser.parse("go to https://example.com."),
            [.text("go to "), .autolink("https://example.com"), .text(".")]
        )
        // A `)` is kept when balanced, dropped when it closes surrounding text.
        expectEqual(
            InlineParser.parse("(https://en.wikipedia.org/wiki/A_(b))"),
            [.text("("), .autolink("https://en.wikipedia.org/wiki/A_(b)"), .text(")")]
        )
    }

    @Test func autolinkBoundariesAndExclusions() {
        // Not at a word boundary → plain text (no partial-word links).
        expectEqual(InlineParser.parse("xhttps://a.b"), [.text("xhttps://a.b")])
        // A scheme with no host isn't a link.
        expectEqual(InlineParser.parse("https://"), [.text("https://")])
        // A formal link still wins; the destination isn't separately autolinked.
        expectEqual(
            InlineParser.parse("[x](https://a.b)"),
            [.link(label: "x", url: "https://a.b")]
        )
        // Inside a code span the URL stays literal code.
        expectEqual(InlineParser.parse("`https://a.b`"), [.code("https://a.b")])
    }

    @Test func pipeImageSizes() {
        expectEqual(
            InlineParser.parse("![a|363](x.png)"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 363))]
        )
        expectEqual(
            InlineParser.parse("![a|640x480](x.png)"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 640, height: 480))]
        )
        expectEqual(
            InlineParser.parse("![cat|photo](x.png)"),
            [.image(alt: "cat|photo", src: "x.png")]
        )
        expectEqual(
            InlineParser.parse("![|363](x.png)"),
            [.image(alt: "", src: "x.png", size: ImageSize(width: 363))]
        )
        expectEqual(InlineParser.plainText(InlineParser.parse("![a|363](x.png)")), "a")
    }

    @Test func logseqImageSizes() {
        expectEqual(
            InlineParser.parse("![a](x.png){:height 239, :width 363}"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 363, height: 239))]
        )
        expectEqual(
            InlineParser.parse("![a](x.png){:width 363, :height 239}"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 363, height: 239))]
        )
        expectEqual(
            InlineParser.parse("![a](x.png){:width 363}"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 363))]
        )
        expectEqual(
            InlineParser.parse("![a](x.png){:height 239}"),
            [.image(alt: "a", src: "x.png", size: ImageSize(height: 239))]
        )
        expectEqual(
            InlineParser.parse("![a](x.png){:foo 1}"),
            [.image(alt: "a", src: "x.png"), .text("{:foo 1}")]
        )
        expectEqual(
            InlineParser.parse("![a](x.png)\n{:width 363}"),
            [.image(alt: "a", src: "x.png"), .lineBreak, .text("{:width 363}")]
        )
        // Pipe form controls the size, but a valid Logseq suffix is still consumed.
        expectEqual(
            InlineParser.parse("![a|100](x.png){:width 363}"),
            [.image(alt: "a", src: "x.png", size: ImageSize(width: 100))]
        )
    }

    @Test func settingImageWidth() {
        let three = "![one](1.png) x ![two](2.png) y ![three](3.png)"
        expectEqual(
            InlineParser.settingImageWidth(three, imageIndex: 1, width: 275),
            "![one](1.png) x ![two|275](2.png) y ![three](3.png)"
        )
        expectEqual(
            InlineParser.settingImageWidth("![a|100](x.png)", imageIndex: 0, width: 220),
            "![a|220](x.png)"
        )
        expectEqual(
            InlineParser.settingImageWidth(
                "![a](x.png){:height 239, :width 363}", imageIndex: 0, width: 300),
            "![a|300](x.png)"
        )
        expectEqual(
            InlineParser.settingImageWidth("![a](x.png)", imageIndex: 0, width: 180),
            "![a|180](x.png)"
        )
        expectEqual(
            InlineParser.settingImageWidth("![a|180](x.png)", imageIndex: 0, width: nil),
            "![a](x.png)"
        )
        expectEqual(
            InlineParser.settingImageWidth(
                "![a](x.png){:width 180, :height 90}", imageIndex: 0, width: nil),
            "![a](x.png)"
        )
        expectNil(InlineParser.settingImageWidth(three, imageIndex: 3, width: 200))
        // Opaque code content does not affect the renderer/source image ordinal.
        expectEqual(
            InlineParser.settingImageWidth("`![skip](x.png)` ![use](y.png)", imageIndex: 0,
                                           width: 200),
            "`![skip](x.png)` ![use|200](y.png)"
        )
    }

    /// Balanced parens inside a destination must not truncate the URL — Logseq
    /// asset names like `image_(3)_….png` were breaking the image (the first
    /// inner `)` ended the src early).
    @Test func parensInImageAndLinkURL() {
        expectEqual(
            InlineParser.parse("![image (3).png](../assets/image_(3)_1761142069766_0.png)"),
            [.image(alt: "image (3).png", src: "../assets/image_(3)_1761142069766_0.png")]
        )
        expectEqual(
            InlineParser.parse("[wiki](https://e.org/Foo_(bar))"),
            [.link(label: "wiki", url: "https://e.org/Foo_(bar)")]
        )
        // An unbalanced/early `)` still closes where it should (no over-reach).
        expectEqual(
            InlineParser.parse("![a](x.png) y"),
            [.image(alt: "a", src: "x.png"), .text(" y")]
        )
    }

    @Test func math() {
        expectEqual(
            InlineParser.parse("$e=mc^2$"),
            [.math("e=mc^2")]
        )
    }

    @Test func unmatchedDelimitersLiteral() {
        expectEqual(InlineParser.parse("a ** b"), [.text("a ** b")])
        expectEqual(InlineParser.parse("[[unclosed"), [.text("[[unclosed")])
    }

    @Test func blockKinds() {
        expectEqual(BlockKind.classify("## Title"), .heading(level: 2, text: "Title"))
        expectEqual(BlockKind.classify("> quoted"), .quote(text: "quoted"))
        expectEqual(BlockKind.classify("---"), .horizontalRule)
        expectEqual(BlockKind.classify("TODO buy milk"),
                       .paragraph(text: "buy milk", todo: .todo))
        expectEqual(BlockKind.classify("DONE buy milk"),
                       .paragraph(text: "buy milk", todo: .done))
        expectEqual(BlockKind.classify("```swift\nlet x = 1\n```"),
                       .fence(language: "swift", code: "let x = 1"))
        // No space after # → plain paragraph (and #tag rules apply elsewhere).
        expectEqual(BlockKind.classify("#tag only"),
                       .paragraph(text: "#tag only", todo: nil))
        // Ordered-list text is just text. (SPEC §5.3)
        expectEqual(BlockKind.classify("1. not a list"),
                       .paragraph(text: "1. not a list", todo: nil))
    }

    @Test func logseqQuoteContainer() {
        // #+BEGIN_QUOTE / #+END_QUOTE (Logseq/org-mode) classify as a quote.
        expectEqual(
            BlockKind.classify("#+BEGIN_QUOTE\nline one\nline two\n#+END_QUOTE"),
            .quote(text: "line one\nline two")
        )
        // Lowercase org form, and a missing END marker, still work.
        expectEqual(
            BlockKind.classify("#+begin_quote\njust this"),
            .quote(text: "just this")
        )
        // Markers round-trip byte-stably like any other content.
        let text = "- #+BEGIN_QUOTE\n  quoted\n  #+END_QUOTE\n"
        let page = PageParser.parse(text)
        expectEqual(PageSerializer.serialize(page), text)
    }

    @Test func caretInsideFence() {
        // Non-fenced content: Enter always splits.
        expectFalse(BlockKind.caretInsideFence("plain text", utf16Caret: 3))
        // Skeleton "```\n\n```" (len 8): every caret position is inside.
        let skeleton = "```\n\n```"
        for caret in 0...(skeleton as NSString).length {
            expectTrue(BlockKind.caretInsideFence(skeleton, utf16Caret: caret))
        }
        // Open fence with no closing marker: whole block is inside.
        expectTrue(BlockKind.caretInsideFence("```swift\nlet x = 1", utf16Caret: 12))
        // Closed fence with a trailing line: caret past the closing fence splits.
        let closed = "```\ncode\n```\nafter"
        // "```"(3) \n(4) "code"(8) \n(9) "```"(12)=closing line end, \n(13) "after"
        expectTrue(BlockKind.caretInsideFence(closed, utf16Caret: 12))  // end of closing fence
        expectFalse(BlockKind.caretInsideFence(closed, utf16Caret: 13)) // on the line after
        expectFalse(BlockKind.caretInsideFence(closed, utf16Caret: 18)) // within "after"
    }

    @Test func embeds() {
        let id = "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f"
        expectEqual(
            InlineParser.parse("{{embed ((\(id)))}}"),
            [.embed(.block(UUID(uuidString: id)!))]
        )
        expectEqual(
            InlineParser.parse("{{embed [[Project X]]}}"),
            [.embed(.page("Project X"))]
        )
        // Lenient spacing.
        expectEqual(InlineParser.parse("{{embed  [[A]] }}"), [.embed(.page("A"))])
        // A valid `{{query …}}` is now interpreted (§17).
        expectEqual(InlineParser.parse("{{query (and [[a]])}}"),
                    [.query(.and([.pageRef("a")]))])
        // Other / malformed `{{…}}` still render literally (round-trip).
        expectEqual(InlineParser.parse("{{foo bar}}"), [.text("{{foo bar}}")])
        expectEqual(InlineParser.parse("{{query }}"), [.text("{{query }}")])
        // Embeds register as references (§7.5): block embed → block ref.
        let refs = RefExtractor.extract(from: "{{embed ((\(id)))}} and {{embed [[Page]]}}")
        expectEqual(refs.blockRefs, [UUID(uuidString: id)!])
        expectEqual(refs.pageRefs, ["Page"])
    }

    @Test func extraction() {
        let refs = RefExtractor.extract(
            from: "**[[Page One]]** and ((6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f)) #Tag-1 `[[skip]]`"
        )
        expectEqual(refs.pageRefs, ["Page One"])
        expectEqual(refs.blockRefs, [UUID(uuidString: "6f1c9e2a-3b4d-4c5e-8f90-1a2b3c4d5e6f")!])
        expectEqual(refs.tags, ["tag-1"])
    }

    @Test func extractionSkipsFences() {
        expectEqual(RefExtractor.extract(from: "```\n[[x]] #y\n```"), ExtractedRefs())
        let refs = RefExtractor.extract(from: "before [[A]]\n```\n[[x]]\n```\nafter [[B]]")
        expectEqual(refs.pageRefs, ["A", "B"])
    }

    @Test func pageNameRules() {
        expectTrue(PageName.isValid("Project X"))
        expectTrue(PageName.isValid("Projects/Outliner"))
        expectFalse(PageName.isValid("bad[name]"))
        expectFalse(PageName.isValid("bad#name"))
        expectFalse(PageName.isValid(" leading"))
        expectFalse(PageName.isValid(""))
        expectEqual(PageName.key("Project X"), PageName.key("project x"))
        expectEqual(PageName.fileName(for: "Projects/Outliner"), "Projects%2FOutliner.md")
        expectEqual(PageName.name(fromFileName: "Projects%2FOutliner.md"), "Projects/Outliner")
        expectEqual(PageName.name(fromFileName: "Plain.md"), "Plain")
        expectNil(PageName.name(fromFileName: "not-a-page.txt"))
    }

    @Test func journalDates() {
        let d = JournalDate(pageName: "2026-06-10")
        expectNotNil(d)
        expectEqual(d?.pageName, "2026-06-10")
        expectEqual(d?.displayName, "Jun 10th, 2026")
        expectNil(JournalDate(pageName: "2026-13-01"))
        expectNil(JournalDate(pageName: "not-a-date"))
        expectNil(JournalDate(pageName: "2026-6-1"))
        expectEqual(JournalDate(pageName: "2026-06-01")!.displayName, "Jun 1st, 2026")
        expectEqual(JournalDate(pageName: "2026-06-02")!.displayName, "Jun 2nd, 2026")
        expectEqual(JournalDate(pageName: "2026-06-03")!.displayName, "Jun 3rd, 2026")
        expectEqual(JournalDate(pageName: "2026-06-11")!.displayName, "Jun 11th, 2026")
        expectEqual(JournalDate(pageName: "2026-06-10")!.adding(days: 1).pageName, "2026-06-11")
        expectEqual(JournalDate(pageName: "2026-01-01")!.adding(days: -1).pageName, "2025-12-31")
        // Logseq's underscore filename form parses to the same date.
        expectEqual(JournalDate(pageName: "2024_04_30")?.pageName, "2024-04-30")
        expectEqual(JournalDate(pageName: "2024_04_30")?.displayName, "Apr 30th, 2024")
        expectNil(JournalDate(pageName: "2024_13_01"))
        expectNil(JournalDate(pageName: "not_a_date"))
    }
}
