import Foundation

/// References and tags parsed out of one block's content — the derived data
/// the index stores per block (SPEC §3.1, §17).
public struct ExtractedRefs: Equatable, Sendable {
    /// Page names as written (display case); normalize with `PageName.key`.
    public var pageRefs: [String] = []
    public var blockRefs: [UUID] = []
    /// Normalized lowercase tag names.
    public var tags: [String] = []

    public init() {}
}

public enum RefExtractor {

    /// Extracts refs/tags from block content, skipping fenced code regions and
    /// inline code spans. A block that *is* a fence yields nothing.
    public static func extract(from content: String) -> ExtractedRefs {
        var refs = ExtractedRefs()
        if case .fence = BlockKind.classify(content) { return refs }

        // Multi-line blocks may embed a fence mid-content; parse only the
        // non-fenced segments.
        var inFence = false
        var segment = ""
        func flushSegment() {
            guard !segment.isEmpty else { return }
            collect(InlineParser.parse(segment), into: &refs)
            segment = ""
        }
        for line in content.components(separatedBy: "\n") {
            if fenceToggles(line) {
                if !inFence { flushSegment() }
                inFence.toggle()
                continue
            }
            if !inFence { segment += line + "\n" }
        }
        flushSegment()
        return refs
    }

    private static func collect(_ nodes: [InlineNode], into refs: inout ExtractedRefs) {
        for node in nodes {
            switch node {
            case .pageRef(let name):
                refs.pageRefs.append(name)
            case .blockRef(let id):
                refs.blockRefs.append(id)
            case .embed(.block(let id)):
                refs.blockRefs.append(id) // an embed references its target (§7.5)
            case .embed(.page(let name)):
                refs.pageRefs.append(name)
            case .tag(let tag):
                refs.tags.append(tag)
            case .bold(let inner), .italic(let inner),
                 .strike(let inner), .highlight(let inner):
                collect(inner, into: &refs)
            default:
                break
            }
        }
    }
}
