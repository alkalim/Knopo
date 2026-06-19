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
}
