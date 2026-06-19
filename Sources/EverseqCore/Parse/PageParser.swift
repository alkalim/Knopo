import Foundation

public struct ParsedPage: Sendable {
    /// Verbatim text before the first bullet (rare; preserved untouched).
    public var preamble: String
    public var blocks: [Block]

    public init(preamble: String = "", blocks: [Block] = []) {
        self.preamble = preamble
        self.blocks = blocks
    }
}

/// Parses the on-disk Markdown bullet-list format (SPEC §4.2) into a block tree.
///
/// Guarantees, together with `PageSerializer`, a byte-stable round trip: each
/// block keeps its exact source slice in `Block.raw`, re-emitted verbatim as
/// long as the block is unedited and its depth is unchanged.
public enum PageParser {

    public static func parse(_ text: String) -> ParsedPage {
        let lines = splitKeepingTerminators(text)
        var preamble = ""
        var roots: [Block] = []
        // Open-ancestor chain: (indent, depth) plus the index path of the most
        // recently started block within the tree.
        var stack: [(indent: Int, depth: Int)] = []
        var pathStack: [Int] = []
        var current: PendingBlock? = nil
        var inFence = false

        func finishCurrent() {
            guard let pending = current else { return }
            insert(pending.build(), at: pending.parentPath, into: &roots)
            current = nil
        }

        for line in lines {
            let bullet = inFence ? nil : matchBullet(line)
            if let bullet {
                finishCurrent()
                while let top = stack.last, bullet.indent < top.indent {
                    stack.removeLast()
                    pathStack.removeLast()
                }
                let depth: Int
                if let top = stack.last {
                    if bullet.indent == top.indent {
                        depth = top.depth
                        stack.removeLast()
                        pathStack.removeLast()
                    } else {
                        depth = top.depth + 1
                    }
                } else {
                    depth = 0
                }
                let parentPath = pathStack
                let position = childCount(at: parentPath, in: roots)
                stack.append((bullet.indent, depth))
                pathStack.append(position)

                var pending = PendingBlock(
                    indent: bullet.indent, depth: depth, parentPath: parentPath
                )
                pending.appendRaw(line)
                pending.acceptFirstLine(bullet.text)
                if fenceToggles(bullet.text) { inFence = true }
                current = pending
            } else if var pending = current {
                pending.appendRaw(line)
                let stripped = stripContinuationIndent(line, contentColumn: pending.indent + 2)
                if inFence {
                    pending.appendContentLine(stripped)
                    if fenceToggles(stripped) { inFence = false }
                } else if fenceToggles(stripped) {
                    pending.appendContentLine(stripped)
                    inFence = true
                } else if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Blank line: kept in raw for round-trip, not part of content.
                } else if let prop = matchProperty(stripped) {
                    pending.acceptProperty(prop)
                } else {
                    pending.appendContentLine(stripped)
                }
                current = pending
            } else {
                preamble += line
            }
        }
        finishCurrent()
        return ParsedPage(preamble: preamble, blocks: roots)
    }

    // MARK: - Pending block accumulator

    private struct PendingBlock {
        var indent: Int
        var depth: Int
        var parentPath: [Int]
        var rawText = ""
        var contentLines: [String] = []
        var id: UUID? = nil
        var idPersisted = false
        var collapsed = false
        var properties: [BlockProperty] = []

        mutating func appendRaw(_ line: Substring) { rawText += line }

        mutating func acceptFirstLine(_ text: String) {
            // A bullet line that is itself a `key:: value` line (page-properties
            // block style) counts as a property, not content.
            if !fenceToggles(text), let prop = PageParser.matchProperty(text) {
                acceptProperty(prop)
            } else {
                contentLines.append(text)
            }
        }

        mutating func appendContentLine(_ line: String) {
            contentLines.append(PageParser.chomp(line))
        }

        mutating func acceptProperty(_ prop: BlockProperty) {
            switch prop.key {
            case "id":
                if let uuid = UUID(uuidString: prop.value) {
                    id = uuid
                    idPersisted = true
                } else {
                    properties.append(prop)
                }
            case "collapsed":
                if prop.value == "true" { collapsed = true }
                else { properties.append(prop) }
            default:
                properties.append(prop)
            }
        }

        func build() -> Block {
            Block(
                id: id ?? UUID(),
                content: contentLines.joined(separator: "\n"),
                children: [],
                collapsed: collapsed,
                idPersisted: idPersisted,
                properties: properties,
                raw: RawSource(text: rawText, depth: depth)
            )
        }
    }

    // MARK: - Line helpers

    /// Splits text into lines, each retaining its terminator, so concatenating
    /// all lines reproduces the input exactly.
    static func splitKeepingTerminators(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\n" {
                lines.append(text[start...i])
                i = text.index(after: i)
                start = i
            } else if ch == "\r" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "\n" {
                    lines.append(text[start...next])
                    i = text.index(after: next)
                } else {
                    lines.append(text[start...i])
                    i = next
                }
                start = i
            } else {
                i = text.index(after: i)
            }
        }
        if start < text.endIndex { lines.append(text[start...]) }
        return lines
    }

    /// Strips a trailing line terminator, if any.
    static func chomp(_ line: String) -> String {
        var l = line
        if l.hasSuffix("\r\n") { l.removeLast(2) }
        else if l.hasSuffix("\n") || l.hasSuffix("\r") { l.removeLast() }
        return l
    }

    struct BulletMatch {
        var indent: Int
        /// Text after "- " (terminator stripped). Empty for a bare "-".
        var text: String
    }

    /// Matches `^(\s*)- (.*)$` or a bare `^(\s*)-$` (empty block).
    static func matchBullet(_ line: Substring) -> BulletMatch? {
        var indent = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            indent += 1
            i = line.index(after: i)
        }
        guard i < line.endIndex, line[i] == "-" else { return nil }
        let afterDash = line.index(after: i)
        if afterDash == line.endIndex || line[afterDash] == "\n" || line[afterDash] == "\r" {
            return BulletMatch(indent: indent, text: "")
        }
        guard line[afterDash] == " " else { return nil }
        let text = chomp(String(line[line.index(after: afterDash)...]))
        return BulletMatch(indent: indent, text: text)
    }

    /// Removes up to `contentColumn` leading whitespace characters.
    static func stripContinuationIndent(_ line: Substring, contentColumn: Int) -> String {
        var removed = 0
        var i = line.startIndex
        while removed < contentColumn, i < line.endIndex,
              line[i] == " " || line[i] == "\t" {
            removed += 1
            i = line.index(after: i)
        }
        return String(line[i...])
    }

    /// `key:: value` (or `key::` with empty value) — key starts with a letter,
    /// then letters/digits/`-`/`_`/`.`.
    static func matchProperty(_ line: String) -> BlockProperty? {
        let l = chomp(line)
        let sep: Range<String.Index>
        if let r = l.range(of: ":: ") {
            sep = r
        } else if l.hasSuffix("::"), let r = l.range(of: "::", options: .backwards) {
            sep = r
        } else {
            return nil
        }
        let key = String(l[l.startIndex..<sep.lowerBound])
        guard let first = key.first, first.isLetter,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        let value = String(l[sep.upperBound...])
        return BlockProperty(key: key, value: value)
    }

    // MARK: - Tree building

    private static func insert(_ block: Block, at parentPath: [Int], into roots: inout [Block]) {
        if parentPath.isEmpty {
            roots.append(block)
            return
        }
        var path = parentPath
        let first = path.removeFirst()
        guard roots.indices.contains(first) else {
            roots.append(block) // malformed indentation; degrade gracefully
            return
        }
        insert(block, at: path, into: &roots[first].children)
    }

    private static func childCount(at parentPath: [Int], in roots: [Block]) -> Int {
        if parentPath.isEmpty { return roots.count }
        return roots.block(at: parentPath)?.children.count ?? 0
    }
}

/// True if the (indent-stripped) line opens or closes a fenced code block.
func fenceToggles(_ line: String) -> Bool {
    let trimmed = PageParser.chomp(line).trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
}
