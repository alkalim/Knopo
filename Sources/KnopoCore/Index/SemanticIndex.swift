import Foundation

/// One block whose derived embedding is missing or stale.
public struct EmbeddingInput: Equatable, Sendable {
    public var blockID: UUID
    public var content: String
    public var contentHash: String

    public init(blockID: UUID, content: String, contentHash: String) {
        self.blockID = blockID
        self.content = content
        self.contentHash = contentHash
    }
}

/// Progress through the rebuildable on-device embedding index.
public struct EmbeddingIndexStatus: Equatable, Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var isComplete: Bool { completed >= total }
}

/// A semantic block match and its cosine similarity.
public struct SemanticHit: Equatable, Sendable {
    public var hit: SearchHit
    public var score: Float

    public init(hit: SearchHit, score: Float) {
        self.hit = hit
        self.score = score
    }
}

/// Pure vector math and rank fusion, kept independent of NaturalLanguage so it
/// is deterministic and unit-testable in KnopoCore.
public enum SemanticRanker {
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            guard a.isFinite, b.isFinite else { return nil }
            dot += a * b
            lhsNorm += a * a
            rhsNorm += b * b
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return Float(dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot()))
    }

    public static func nearest<ID: Hashable>(
        to query: [Float], among candidates: [(id: ID, vector: [Float])], limit: Int
    ) -> [(id: ID, score: Float)] {
        guard limit > 0 else { return [] }
        return candidates.compactMap { candidate -> (id: ID, score: Float)? in
            guard let score = cosineSimilarity(query, candidate.vector) else { return nil }
            return (candidate.id, score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return String(describing: $0.id) < String(describing: $1.id)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Weighted reciprocal-rank fusion. Semantic matches carry slightly more
    /// weight so Cmd+K can surface a strong meaning match without displacing a
    /// clear lexical hit entirely.
    public static func fuse<ID: Hashable>(
        lexical: [ID], semantic: [ID], limit: Int,
        lexicalWeight: Double = 1.0, semanticWeight: Double = 1.25
    ) -> [ID] {
        fuse(
            rankedLists: [
                (ids: lexical, weight: lexicalWeight),
                (ids: semantic, weight: semanticWeight),
            ],
            limit: limit)
    }

    /// Reciprocal-rank fusion across an arbitrary number of independently
    /// ranked retrieval channels. Ask uses this for several planned lexical
    /// and semantic queries without pretending their raw scores are directly
    /// comparable.
    public static func fuse<ID: Hashable>(
        rankedLists: [(ids: [ID], weight: Double)], limit: Int
    ) -> [ID] {
        guard limit > 0 else { return [] }
        var scores: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        var nextSeen = 0
        func add(_ ids: [ID], weight: Double) {
            for (rank, id) in ids.enumerated() {
                if firstSeen[id] == nil { firstSeen[id] = nextSeen; nextSeen += 1 }
                scores[id, default: 0] += weight / Double(60 + rank + 1)
            }
        }
        for list in rankedLists where list.weight > 0 {
            add(list.ids, weight: list.weight)
        }
        return scores.keys.sorted {
            let left = scores[$0, default: 0]
            let right = scores[$1, default: 0]
            if left != right { return left > right }
            return firstSeen[$0, default: .max] < firstSeen[$1, default: .max]
        }
        .prefix(limit)
        .map { $0 }
    }
}

/// Stable, process-independent hash used to avoid re-embedding unchanged text.
/// FNV-1a is sufficient here: this is a cache invalidation key, not a security
/// boundary, and retaining the hash inside KnopoCore avoids another dependency.
func embeddingContentHash(_ content: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in content.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

func embeddingEligibleSQL(alias: String) -> String {
    "TRIM(\(alias).content) <> '' "
        + "AND \(alias).content <> '---' "
        + "AND \(alias).content NOT LIKE '```%' "
        + "AND \(alias).content NOT LIKE '~~~%'"
}
