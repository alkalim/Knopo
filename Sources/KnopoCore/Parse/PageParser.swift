import Foundation

public struct ParsedPage: Sendable {
    /// Page properties and other text before the first outline block.
    public var preamble: String
    public var blocks: [Block]
    var rootMarkers: [ClipboardMarker] = []

    public init(preamble: String = "", blocks: [Block] = []) {
        self.preamble = preamble
        self.blocks = blocks
    }
}

enum ClipboardMarker: Sendable { case plain, bullet, numbered }

/// Parses the on-disk Markdown bullet-list format (SPEC §4.2) into a block tree.
///
/// Guarantees, together with `PageSerializer`, a byte-stable round trip: each
/// block keeps its exact source slice in `Block.raw`, re-emitted verbatim as
/// long as the block is unedited and its depth is unchanged.
public enum PageParser {

    public static func parse(_ text: String) -> ParsedPage {
        parse(text, plainLinesAsBlocks: false)
    }

    static func parse(
        _ text: String, plainLinesAsBlocks: Bool
    ) -> ParsedPage {
        let lines = splitKeepingTerminators(text)
        let preambleFences = plainLinesAsBlocks ? Set<Int>() : preambleFenceLines(lines)
        var preamble = ""
        var roots: [Block] = []
        var rootMarkers: [ClipboardMarker] = []
        // Open-ancestor chain: (indent, depth) plus the index path of the most
        // recently started block within the tree.
        var stack: [(indent: Int, depth: Int, contentColumn: Int)] = []
        var pathStack: [Int] = []
        var current: PendingBlock? = nil
        var inFence = false
        var hasList = false

        func finishCurrent() {
            guard let pending = current else { return }
            let block = pending.build(preserveID: !plainLinesAsBlocks)
            if plainLinesAsBlocks, pending.parentPath.isEmpty { rootMarkers.append(pending.marker) }
            insert(block, at: pending.parentPath, into: &roots)
            current = nil
        }

        for (lineIndex, line) in lines.enumerated() {
            if preambleFences.contains(lineIndex) {
                preamble += line
                continue
            }
            let leadingIndent = plainLinesAsBlocks ? clipboardIndent(line)
                : line.prefix { $0 == " " || $0 == "\t" }.count
            var bullet = inFence ? nil : (plainLinesAsBlocks ? matchClipboardBullet(line) : matchBullet(line))
            // Logseq also uses unindented Markdown headings as outline blocks.
            // Heading level affects styling, not outline depth.
            if !plainLinesAsBlocks, !inFence, leadingIndent == 0, line.first == "#",
               case .heading = BlockKind.classify(chomp(String(line))) {
                bullet = BulletMatch(indent: 0, text: chomp(String(line)), width: 0, marker: .plain)
            }
            if bullet != nil, !hasList {
                hasList = true
                stack.removeAll()
                pathStack.removeAll()
            } else if plainLinesAsBlocks, !inFence, bullet == nil {
                let content = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty, !hasList || leadingIndent < (current?.contentColumn ?? 0),
                   current == nil || matchProperty(content) == nil {
                    bullet = BulletMatch(indent: 0, text: content, marker: .plain)
                    hasList = false
                }
            }
            if let bullet {
                finishCurrent()
                while let top = stack.last, bullet.indent < top.indent {
                    stack.removeLast()
                    pathStack.removeLast()
                }
                let depth: Int
                if let top = stack.last {
                    if bullet.indent == top.indent
                        || (plainLinesAsBlocks && bullet.indent < top.contentColumn) {
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
                stack.append((bullet.indent, depth, bullet.indent + bullet.width))
                pathStack.append(position)

                var pending = PendingBlock(
                    indent: bullet.indent, depth: depth, parentPath: parentPath,
                    contentColumn: hasList ? bullet.indent + bullet.width : leadingIndent,
                    marker: bullet.marker
                )
                pending.appendRaw(line)
                pending.acceptFirstLine(bullet.text)
                if fenceToggles(bullet.text) { inFence = true }
                current = pending
            } else if var pending = current {
                pending.appendRaw(line)
                let stripped = stripContinuationIndent(line, contentColumn: pending.contentColumn,
                                                       expandTabs: plainLinesAsBlocks)
                let propertySource = plainLinesAsBlocks || pending.marker == .plain
                    ? stripped.trimmingCharacters(in: .whitespaces) : stripped
                if inFence {
                    pending.appendContentLine(stripped)
                    if fenceToggles(stripped) { inFence = false }
                } else if fenceToggles(stripped) {
                    pending.appendContentLine(stripped)
                    inFence = true
                } else if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Blank line: kept in raw for round-trip, not part of content.
                } else if let prop = matchProperty(propertySource) {
                    pending.acceptProperty(prop)
                } else {
                    pending.appendContentLine(plainLinesAsBlocks ? unescapeClipboardOrderedMarker(stripped) : stripped)
                }
                current = pending
            } else {
                preamble += line
            }
        }
        // Close pasted fences so they cannot absorb existing blocks on reload.
        if plainLinesAsBlocks, inFence,
           let opening = current?.contentLines.first(where: fenceToggles) {
            current?.appendContentLine(String(opening.trimmingCharacters(in: .whitespaces).prefix(3)))
        }
        finishCurrent()
        var parsed = ParsedPage(preamble: preamble, blocks: roots)
        parsed.rootMarkers = rootMarkers
        return parsed
    }

    // MARK: - Pending block accumulator

    private struct PendingBlock {
        var indent: Int
        var depth: Int
        var parentPath: [Int]
        var contentColumn: Int
        var marker: ClipboardMarker
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

        func build(preserveID: Bool) -> Block {
            var block = Block(
                id: preserveID ? (id ?? UUID()) : UUID(),
                content: contentLines.joined(separator: "\n"),
                children: [],
                collapsed: collapsed,
                idPersisted: preserveID && idPersisted,
                properties: properties,
                raw: RawSource(text: rawText, depth: depth)
            )
            if marker == .numbered { block.setNumbered(true) }
            return block
        }
    }

    // MARK: - Line helpers

    /// Only closed fences protect preamble examples. Without a closing fence,
    /// later outline blocks remain editable. Closed examples may contain bullets and headings.
    static func preambleFenceLines(_ lines: [Substring]) -> Set<Int> {
        var protected = Set<Int>()
        var opening: (index: Int, marker: Character, count: Int, indent: Int)?
        for (index, line) in lines.enumerated() {
            let text = chomp(String(line)).trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if let start = opening {
                let run = text.prefix { $0 == start.marker }
                if indent <= start.indent, run.count >= start.count,
                   text.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    protected.formUnion(start.index...index)
                    opening = nil
                }
            } else {
                if matchBullet(line) != nil { break }
                if line.first == "#", case .heading = BlockKind.classify(chomp(String(line))) { break }
                if let marker = text.first, marker == "`" || marker == "~" {
                    let count = text.prefix { $0 == marker }.count
                    if count >= 3 { opening = (index, marker, count, indent) }
                }
            }
        }
        return protected
    }

    /// Splits text into lines, each retaining its terminator, so concatenating
    /// all lines reproduces the input exactly.
    static func splitKeepingTerminators(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\n" || ch == "\r\n" {
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
        if l.hasSuffix("\r\n") { l.removeLast() }
        else if l.hasSuffix("\n") || l.hasSuffix("\r") { l.removeLast() }
        return l
    }

    struct BulletMatch {
        var indent: Int
        /// Text after "- " (terminator stripped). Empty for a bare "-".
        var text: String
        var width: Int = 2
        var marker: ClipboardMarker = .bullet
    }

    /// Ordered markers are accepted only on the clipboard, never from graph files.
    static func matchClipboardBullet(_ line: Substring) -> BulletMatch? {
        if var bullet = matchBullet(line) {
            bullet.indent = clipboardIndent(line)
            return bullet
        }
        let whitespace = line.prefix { $0 == " " || $0 == "\t" }.count
        let indent = clipboardIndent(line)
        let source = line.dropFirst(whitespace)
        let digits = source.prefix { $0 >= "0" && $0 <= "9" }
        guard (1...9).contains(digits.count) else { return nil }
        let suffix = source.dropFirst(digits.count)
        guard let delimiter = suffix.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = suffix.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first?.isNewline == true
        else { return nil }
        let padding = rest.prefix { $0 == " " || $0 == "\t" }
        let markerEnd = indent + digits.count + 1
        let column = padding.reduce(markerEnd) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
        return BulletMatch(indent: indent, text: chomp(String(rest.dropFirst(padding.count))),
                           width: max(markerEnd + 1, column) - indent, marker: .numbered)
    }

    private static func clipboardIndent(_ line: Substring) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
    }

    static func escapeClipboardOrderedMarker(_ line: String) -> String {
        guard let position = clipboardOrderedEscapePosition(line) else { return line }
        var escaped = line
        escaped.insert("\\", at: position)
        return escaped
    }

    private static func unescapeClipboardOrderedMarker(_ line: String) -> String {
        guard let position = clipboardOrderedEscapePosition(line), line[position] == "\\" else { return line }
        var unescaped = line
        unescaped.remove(at: position)
        return unescaped
    }

    // Add and remove one escape layer, preserving backslashes already in the body.
    private static func clipboardOrderedEscapePosition(_ line: String) -> String.Index? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let digits = line.dropFirst(indent).prefix { $0 >= "0" && $0 <= "9" }.count
        guard (1...9).contains(digits) else { return nil }
        let position = line.index(line.startIndex, offsetBy: indent + digits)
        let suffix = line[position...].drop { $0 == "\\" }
        guard let delimiter = suffix.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = suffix.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first?.isNewline == true
        else { return nil }
        return position
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
        if afterDash == line.endIndex || line[afterDash].isNewline {
            return BulletMatch(indent: indent, text: "")
        }
        guard line[afterDash] == " " else { return nil }
        let text = chomp(String(line[line.index(after: afterDash)...]))
        return BulletMatch(indent: indent, text: text)
    }

    /// Removes up to `contentColumn` leading whitespace characters.
    static func stripContinuationIndent(
        _ line: Substring, contentColumn: Int, expandTabs: Bool = false
    ) -> String {
        var removed = 0
        var i = line.startIndex
        while removed < contentColumn, i < line.endIndex,
              line[i] == " " || line[i] == "\t" {
            removed = expandTabs && line[i] == "\t" ? (removed / 4 + 1) * 4 : removed + 1
            i = line.index(after: i)
        }
        return String(repeating: " ", count: max(0, removed - contentColumn)) + line[i...]
    }

    /// `key:: value` (or `key::` with empty value) — key starts with a letter,
    /// then letters/digits/`-`/`_`/`.`.
    public static func matchProperty(_ line: String) -> BlockProperty? {
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
