import Foundation
import Testing
@testable import KnopoCore

@Suite struct SemanticIndexTests {
    private let model = "test-model-v1"

    @Test func cosineAndNearestAreDeterministic() {
        expectEqual(SemanticRanker.cosineSimilarity([1, 0], [1, 0]), 1)
        expectEqual(SemanticRanker.cosineSimilarity([1, 0], [0, 1]), 0)
        expectTrue(SemanticRanker.cosineSimilarity([], []) == nil)
        expectTrue(SemanticRanker.cosineSimilarity([0, 0], [1, 0]) == nil)

        let nearest = SemanticRanker.nearest(
            to: [1, 0], among: [("far", [0 as Float, 1]), ("near", [0.9, 0.1])], limit: 1)
        expectEqual(nearest.map(\.id), ["near"])
    }

    @Test func reciprocalRankFusionCombinesListsWithoutDuplicates() {
        let fused = SemanticRanker.fuse(
            lexical: ["lexical", "both"], semantic: ["semantic", "both"], limit: 3)
        expectEqual(fused.first, "both")
        expectEqual(Set(fused), Set(["lexical", "semantic", "both"]))

        let multi = SemanticRanker.fuse(
            rankedLists: [
                (ids: ["phrase", "shared"], weight: 1.8),
                (ids: ["semantic", "shared"], weight: 1.25),
                (ids: ["shared"], weight: 0.7),
            ], limit: 3)
        expectEqual(multi.first, "shared")
    }

    @Test func askLexicalChannelsUsePhraseAndAnyTermSemantics() throws {
        let anomaly = Block(content: "anomaly detection for time series")
        let outlier = Block(content: "outlier screening in telemetry")
        let filler = Block(content: "show me some cool notes")
        let fence = Block(content: "```text\nanomaly detection\n```")
        let cache = try CacheDB()
        try cache.indexPage(
            PageDocument(name: "Research", blocks: [anomaly, outlier, filler, fence]), stamp: nil)

        expectEqual(
            try cache.searchBlocks(exactPhrase: "anomaly detection").map(\.blockID),
            [anomaly.id])
        expectEqual(
            Set(try cache.searchBlocks(anyOf: ["anomaly", "outlier"]).map(\.blockID)),
            Set([anomaly.id, outlier.id]))
        expectTrue(try cache.searchBlocks(anyOf: []).isEmpty)
    }

    @Test func focusedAskRetrievalNeverNeedsTheConversationalQuestion() throws {
        let anomaly = Block(content: "anomaly detection for time series")
        let outlier = Block(content: "outlier screening in telemetry")
        let filler = Block(content: "show me some cool notes about work")
        let cache = try CacheDB()
        try cache.indexPage(
            PageDocument(name: "Research", blocks: [anomaly, outlier, filler]), stamp: nil)
        for input in try cache.pendingEmbeddingInputs(modelID: model) {
            let vector: [Float] = input.blockID == anomaly.id ? [1, 0]
                : input.blockID == outlier.id ? [0.9, 0.1]
                : [0, 1]
            try cache.storeEmbedding(vector, for: input, modelID: model)
        }

        let hits = try cache.retrieveFocused(
            phrases: ["anomaly detection"],
            lexicalTerms: ["anomaly", "detection", "outlier"],
            semanticVector: [1, 0], modelID: model)

        expectEqual(hits.first?.blockID, anomaly.id)
        expectTrue(hits.contains { $0.blockID == outlier.id })
        expectTrue(!hits.contains { $0.blockID == filler.id })
    }

    @Test func evidenceContextReturnsSeparatelyCitableParentAndChildren() throws {
        let parent = Block(content: "Index decisions", children: [
            Block(content: "Use one file per page"),
            Block(content: "Keep the cache rebuildable"),
            Block(content: "A third child outside the default context limit"),
        ])
        let cache = try CacheDB()
        try cache.indexPage(PageDocument(name: "Design", blocks: [parent]), stamp: nil)
        let focus = parent.children[0]

        let aroundChild = try cache.contextBlocks(around: focus.id)
        expectEqual(aroundChild.map(\.blockID), [parent.id])
        let aroundParent = try cache.contextBlocks(around: parent.id)
        expectEqual(aroundParent.map(\.blockID), Array(parent.children.prefix(2).map(\.id)))
    }

    @Test func indexingQueuesOnlyProseAndRetainsUnchangedVectors() throws {
        let prose = Block(content: "A decision about the local index")
        let fence = Block(content: "```swift\nprint(1)\n```")
        let propertyOnly = Block(content: "", properties: [BlockProperty(key: "type", value: "note")])
        let cache = try CacheDB()
        try cache.indexPage(
            PageDocument(name: "Design", blocks: [prose, fence, propertyOnly]), stamp: nil)

        let pending = try cache.pendingEmbeddingInputs(modelID: model)
        expectEqual(pending.map(\.blockID), [prose.id])
        guard let input = pending.first else { return }
        try cache.storeEmbedding([1, 0, 0], for: input, modelID: model)
        expectTrue(try cache.pendingEmbeddingInputs(modelID: model).isEmpty)
        expectEqual(try cache.embeddingIndexStatus(modelID: model),
                    EmbeddingIndexStatus(completed: 1, total: 1))

        // Replacing all page index rows is the normal save path. The same id and
        // content must keep its vector instead of queuing expensive work again.
        try cache.indexPage(
            PageDocument(name: "Design", blocks: [prose, fence, propertyOnly]), stamp: nil)
        expectTrue(try cache.pendingEmbeddingInputs(modelID: model).isEmpty)

        // A later parse gives an unpersisted block a new transient UUID. Equal
        // text still carries the derived vector across the page replacement.
        let reparsed = Block(content: prose.content)
        try cache.indexPage(PageDocument(name: "Design", blocks: [reparsed]), stamp: nil)
        expectTrue(try cache.pendingEmbeddingInputs(modelID: model).isEmpty)
        expectEqual(
            try cache.semanticSearch(vector: [1, 0, 0], modelID: model).map(\.hit.blockID),
            [reparsed.id])

        var changed = reparsed
        changed.content = "A changed decision about the local index"
        try cache.indexPage(PageDocument(name: "Design", blocks: [changed]), stamp: nil)
        expectEqual(try cache.pendingEmbeddingInputs(modelID: model).map(\.blockID), [reparsed.id])
    }

    @Test func semanticSearchDecodesVectorsAndExcludesCurrentPage() throws {
        let near = Block(content: "Vector storage decision")
        let far = Block(content: "Grocery list")
        let cache = try CacheDB()
        try cache.indexPage(PageDocument(name: "Architecture", blocks: [near]), stamp: nil)
        try cache.indexPage(PageDocument(name: "Personal", blocks: [far]), stamp: nil)
        for input in try cache.pendingEmbeddingInputs(modelID: model) {
            let vector: [Float] = input.blockID == near.id ? [1, 0] : [0, 1]
            try cache.storeEmbedding(vector, for: input, modelID: model)
        }

        let all = try cache.semanticSearch(vector: [1, 0], modelID: model, limit: 2)
        expectEqual(all.map(\.hit.blockID), [near.id, far.id])
        let excluded = try cache.semanticSearch(
            vector: [1, 0], modelID: model, limit: 2,
            excludingPageKey: PageName.key("Architecture"))
        expectEqual(excluded.map(\.hit.blockID), [far.id])
    }

    @Test func fusedRetrievalIncludesMeaningMatchWithoutSharedWords() throws {
        let lexical = Block(content: "database format details")
        let semantic = Block(content: "We chose one file per page")
        let cache = try CacheDB()
        try cache.indexPage(PageDocument(name: "Index", blocks: [lexical, semantic]), stamp: nil)
        for input in try cache.pendingEmbeddingInputs(modelID: model) {
            let vector: [Float] = input.blockID == semantic.id ? [1, 0] : [0, 1]
            try cache.storeEmbedding(vector, for: input, modelID: model)
        }

        let hits = try cache.retrieve(
            "database", semanticVector: [1, 0], modelID: model, limit: 2)
        expectEqual(Set(hits.map(\.blockID)), Set([lexical.id, semantic.id]))
    }
}
