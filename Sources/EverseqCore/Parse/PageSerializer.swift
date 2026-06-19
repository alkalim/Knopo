import Foundation

/// Serializes a block tree back to the on-disk format (SPEC §4.2).
///
/// Unedited blocks (with intact `raw` at an unchanged depth) are emitted
/// verbatim, byte for byte. Edited or new blocks are emitted canonically:
/// 2-space indentation per level, content lines, then property lines
/// (`key:: value`, then `id::`, then `collapsed:: true`).
public enum PageSerializer {

    public static func serialize(_ page: ParsedPage) -> String {
        serialize(preamble: page.preamble, blocks: page.blocks)
    }

    public static func serialize(preamble: String, blocks: [Block]) -> String {
        var out = preamble
        emit(blocks, depth: 0, into: &out)
        return out
    }

    private static func emit(_ blocks: [Block], depth: Int, into out: inout String) {
        for block in blocks {
            // If a previous raw slice lacked a trailing newline (file ended
            // without one) but more content follows, repair the separator.
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            if let raw = block.raw, raw.depth == depth {
                out += raw.text
            } else {
                emitCanonical(block, depth: depth, into: &out)
            }
            emit(block.children, depth: depth + 1, into: &out)
        }
    }

    private static func emitCanonical(_ block: Block, depth: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        let contIndent = indent + "  "
        let lines = block.content.isEmpty ? [] : block.content.components(separatedBy: "\n")
        var propLines = block.properties.map { "\($0.key):: \($0.value)" }
        if block.idPersisted {
            propLines.append("id:: \(block.id.uuidString.lowercased())")
        }
        if block.collapsed {
            propLines.append("collapsed:: true")
        }

        if let first = lines.first {
            out += indent + "- " + first + "\n"
            for line in lines.dropFirst() {
                out += line.isEmpty ? "\n" : contIndent + line + "\n"
            }
        } else if let firstProp = propLines.first {
            // Properties-only block (e.g. the page-properties front block):
            // the first property rides the bullet line, Logseq-style.
            out += indent + "- " + firstProp + "\n"
            propLines.removeFirst()
        } else {
            out += indent + "-\n"
        }
        for line in propLines {
            out += contIndent + line + "\n"
        }
    }
}
