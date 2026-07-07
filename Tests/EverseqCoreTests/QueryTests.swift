import Testing
import Foundation
@testable import EverseqCore

@Suite struct QueryParserTests {

    @Test func shorthandSingleTag() {
        expectEqual(QueryParser.parse("#urgent"), .tag("urgent"))
    }

    @Test func shorthandImplicitAnd() {
        expectEqual(QueryParser.parse("#urgent TODO [[Project X]]"),
                    .and([.tag("urgent"), .task([.todo]), .pageRef("Project X")]))
    }

    @Test func shorthandProperty() {
        expectEqual(QueryParser.parse("status:: open"),
                    .property(key: "status", value: "open"))
        expectEqual(QueryParser.parse("status::"),
                    .property(key: "status", value: nil))
        expectEqual(QueryParser.parse("status::open"),
                    .property(key: "status", value: "open"))
    }

    @Test func multiWordTag() {
        expectEqual(QueryParser.parse("#[[in progress]]"), .tag("in progress"))
    }

    @Test func structuredBooleans() {
        expectEqual(QueryParser.parse("(and #urgent (not DONE))"),
                    .and([.tag("urgent"), .not(.task([.done]))]))
        expectEqual(QueryParser.parse("(or #a #b)"),
                    .or([.tag("a"), .tag("b")]))
    }

    @Test func structuredForms() {
        expectEqual(QueryParser.parse("(task TODO DONE)"), .task([.todo, .done]))
        expectEqual(QueryParser.parse(#"(page "Project X")"#), .pageRef("Project X"))
        expectEqual(QueryParser.parse(#"(property "status" "open")"#),
                    .property(key: "status", value: "open"))
        expectEqual(QueryParser.parse(#"(property "status")"#),
                    .property(key: "status", value: nil))
    }

    @Test func nestedComposition() {
        expectEqual(
            QueryParser.parse("(and [[Roadmap]] (or (task TODO) (task DONE)))"),
            .and([.pageRef("Roadmap"), .or([.task([.todo]), .task([.done])])]))
    }

    @Test func malformedReturnsNil() {
        expectTrue(QueryParser.parse("") == nil)
        expectTrue(QueryParser.parse("   ") == nil)
        expectTrue(QueryParser.parse("(and #a") == nil)      // unclosed
        expectTrue(QueryParser.parse("bogusword") == nil)    // unknown bare word
        expectTrue(QueryParser.parse("(unknown #a)") == nil) // unknown head
    }

    @Test func inlineParserRecognizesQuery() {
        let nodes = InlineParser.parse("see {{query #work TODO}} here")
        expectTrue(nodes.contains { if case .query = $0 { return true }; return false })
    }

    @Test func inlineMalformedQueryStaysLiteral() {
        // `{{query}}` with nothing parseable round-trips as literal text.
        let nodes = InlineParser.parse("{{query }}")
        expectTrue(nodes.allSatisfy { if case .query = $0 { return false }; return true })
        expectEqual(InlineParser.plainText(nodes), "{{query }}")
    }
}

@Suite struct QueryRunTests {

    private func makeGraph(_ files: [String: String]) throws -> GraphStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("everseq-query-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("journals"), withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(
                to: root.appendingPathComponent("pages/\(PageName.fileName(for: name))"))
        }
        return try GraphStore(root: root)
    }

    private func graph() throws -> GraphStore {
        try makeGraph([
            "Tasks": """
            - TODO buy milk #errands
            - DONE call mom #family
            - TODO email boss #work
            """,
            "Notes": """
            - idea about [[Tasks]] #work
            - review the budget
              status:: open
            """,
        ])
    }

    private func run(_ store: GraphStore, _ source: String, limit: Int = 50) throws
        -> (hits: [BacklinkHit], total: Int) {
        guard let expr = QueryParser.parse(source) else {
            Issue.record("failed to parse query: \(source)")
            return ([], 0)
        }
        return try store.cache.runQuery(expr, limit: limit)
    }

    @Test func tagFilter() throws {
        let store = try graph()
        let r = try run(store, "#work")
        expectEqual(r.total, 2) // "idea about [[Tasks]] #work" + "TODO email boss #work"
    }

    @Test func andOfTagAndTask() throws {
        let store = try graph()
        let r = try run(store, "(and #work TODO)")
        expectEqual(r.total, 1)
        expectTrue(r.hits.first?.content.contains("email boss") == true)
    }

    @Test func taskState() throws {
        let store = try graph()
        expectEqual(try run(store, "TODO").total, 2)
        expectEqual(try run(store, "DONE").total, 1)
    }

    @Test func pageRefFilter() throws {
        let store = try graph()
        let r = try run(store, "[[Tasks]]")
        expectEqual(r.total, 1)
        expectTrue(r.hits.first?.content.contains("idea about") == true)
    }

    @Test func propertyFilter() throws {
        let store = try graph()
        expectEqual(try run(store, "status:: open").total, 1)
        expectEqual(try run(store, "status:: closed").total, 0)
        expectEqual(try run(store, "status::").total, 1) // exists
    }

    @Test func preamblePagePropertyIsQueryable() throws {
        // A page property in the preamble (Logseq style) surfaces the page as a
        // page-level result (empty content → rendered as the page name).
        let store = try makeGraph([
            "Alpha": "type:: project\n- the actual content\n",
            "Beta": "- unrelated\n",
        ])
        let r = try run(store, "type:: project")
        expectEqual(r.total, 1)
        expectEqual(r.hits.first?.pageDisplayName, "Alpha")
        expectTrue(r.hits.first?.content.isEmpty == true)
    }

    @Test func pageWithNoBlocksMatchesByPageProperty() throws {
        // A properties-only page (the Logseq page-properties layout: no bullets
        // at all) is surfaced by a page-property query even with zero blocks.
        let store = try makeGraph([
            "Ann":  "type:: person\nname:: Ann\n",         // no blocks
            "Bob":  "type:: person\n- met at the conf\n",  // preamble prop + a block
            "Note": "- just a note\n",                     // unrelated
        ])
        let r = try run(store, "type:: person")
        expectEqual(r.total, 2)
        expectEqual(Set(r.hits.map(\.pageDisplayName)), Set(["Ann", "Bob"]))
        expectTrue(r.hits.allSatisfy { $0.content.isEmpty }) // page results, not blocks
    }

    @Test func pageAndBlockPropertiesStaySeparate() throws {
        // A preamble page property (`open`) and a same-key block property with a
        // different value (`closed`) aren't conflated: the page property surfaces
        // the page, the block property matches the block that owns it.
        let store = try makeGraph([
            "Alpha": "status:: open\n- first\n  status:: closed\n- second\n",
        ])
        let open = try run(store, "status:: open")
        expectEqual(open.hits.map(\.pageDisplayName), ["Alpha"]) // page prop → the page
        expectTrue(open.hits.first?.content.isEmpty == true)
        expectEqual(try run(store, "status:: closed").hits.map(\.content), ["first"]) // block prop → its owner
        expectEqual(try run(store, "status:: pending").total, 0)                      // neither
    }

    @Test func notAndOr() throws {
        let store = try graph()
        // #work but not done → both work blocks are TODO/none, so 2.
        expectEqual(try run(store, "(and #work (not DONE))").total, 2)
        expectEqual(try run(store, "(or #family #errands)").total, 2)
    }

    @Test func excludesHostBlock() throws {
        let store = try graph()
        let all = try run(store, "TODO")
        guard let host = all.hits.first?.blockID, let expr = QueryParser.parse("TODO") else {
            Issue.record("expected a TODO hit to exclude")
            return
        }
        let filtered = try store.cache.runQuery(expr, excluding: host, limit: 50)
        expectEqual(filtered.total, all.total - 1)
        expectTrue(filtered.hits.allSatisfy { $0.blockID != host })
    }

    @Test func capReportsTotal() throws {
        let store = try graph()
        let r = try run(store, "TODO", limit: 1)
        expectEqual(r.hits.count, 1)
        expectEqual(r.total, 2) // total is the full count, not the capped page
    }

    @Test func journalResultsAreNewestFirst() throws {
        // Journal days sort newest→oldest; non-journal pages (no date) come after.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("everseq-query-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        let journals = root.appendingPathComponent("journals")
        try fm.createDirectory(at: journals, withIntermediateDirectories: true)
        for day in ["2026-04-05", "2026-04-07", "2026-04-06"] {   // written out of order
            try Data("- a note #urgent\n".utf8)
                .write(to: journals.appendingPathComponent(PageName.fileName(for: day)))
        }
        try Data("- plain page task #urgent\n".utf8)
            .write(to: root.appendingPathComponent("pages/\(PageName.fileName(for: "Zeta"))"))
        let store = try GraphStore(root: root)

        let r = try run(store, "#urgent")
        expectEqual(r.hits.map(\.pageDisplayName),
                    ["2026-04-07", "2026-04-06", "2026-04-05", "Zeta"])
    }
}
