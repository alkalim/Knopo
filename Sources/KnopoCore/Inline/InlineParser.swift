import Foundation

public struct ImageSize: Equatable, Sendable {
    public var width: Int?
    public var height: Int?

    public init(width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
    }
}

/// Inline Markdown node tree for one block's content (SPEC §5.1).
public indirect enum InlineNode: Equatable, Sendable {
    case text(String)
    case bold([InlineNode])
    case italic([InlineNode])
    case strike([InlineNode])
    case highlight([InlineNode])
    case code(String)
    case math(String)
    case link(label: String, url: String)
    /// A bare `http(s)://…` URL written without `[…](…)` — shown as itself and
    /// clickable (opens externally). Distinct from `.link` so it never falls
    /// back to internal page navigation. (SPEC §5.1)
    case autolink(String)
    case image(alt: String, src: String, size: ImageSize? = nil)
    case pageRef(String)
    case blockRef(UUID)
    /// Normalized (lowercased) tag name.
    case tag(String)
    /// `{{embed ((uuid))}}` / `{{embed [[Page]]}}` — read-only transclusion of
    /// a block subtree or page (SPEC §7.6).
    case embed(EmbedTarget)
    /// `{{query …}}` — a read-only query whose results render in place (§17).
    case query(QueryExpr)
    case lineBreak
}

/// What a `{{embed …}}` points at.
public enum EmbedTarget: Equatable, Hashable, Sendable {
    case block(UUID)
    case page(String)
}

/// Block-level classification of a block's content (SPEC §5.2).
public enum BlockKind: Equatable, Sendable {
    case paragraph(text: String, todo: TodoState?)
    case heading(level: Int, text: String)
    case quote(text: String)
    case fence(language: String, code: String)
    case horizontalRule

    public static func classify(_ content: String) -> BlockKind {
        if content == "---" { return .horizontalRule }
        if content.hasPrefix("```") || content.hasPrefix("~~~") {
            var lines = content.components(separatedBy: "\n")
            let language = String(lines.removeFirst().dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
            if let last = lines.last, fenceToggles(last) { lines.removeLast() }
            return .fence(language: language, code: lines.joined(separator: "\n"))
        }
        // Logseq/org-mode compatibility: `#+BEGIN_QUOTE … #+END_QUOTE` is a
        // quote container. Render-only — the markers round-trip untouched.
        if content.uppercased().hasPrefix("#+BEGIN_QUOTE") {
            var lines = content.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last,
               last.trimmingCharacters(in: .whitespaces).uppercased() == "#+END_QUOTE" {
                lines.removeLast()
            }
            return .quote(text: lines.joined(separator: "\n"))
        }
        if content.hasPrefix("#") {
            var level = 0
            var idx = content.startIndex
            while idx < content.endIndex, content[idx] == "#", level < 6 {
                level += 1
                idx = content.index(after: idx)
            }
            if level >= 1, idx < content.endIndex, content[idx] == " " {
                return .heading(level: level, text: String(content[content.index(after: idx)...]))
            }
        }
        if content.hasPrefix("> ") {
            return .quote(text: String(content.dropFirst(2)))
        }
        if let todo = TodoState(content: content) {
            let text = String(content.dropFirst(todo.rawValue.count))
                .trimmingCharacters(in: .whitespaces)
            return .paragraph(text: text, todo: todo)
        }
        return .paragraph(text: content, todo: nil)
    }

    /// Whether a newline inserted at `utf16Caret` falls inside a fenced code
    /// block — i.e. the block opens with a ``` / `~~~` fence and the caret is
    /// on or before the closing fence line (SPEC §5.5.1). The editor uses this
    /// to keep `Enter` from splitting a code block mid-fence: inside, `Enter`
    /// inserts a newline; only past the closing fence does it split.
    public static func caretInsideFence(_ content: String, utf16Caret: Int) -> Bool {
        guard content.hasPrefix("```") || content.hasPrefix("~~~") else { return false }
        let marker = String(content.prefix(3))
        var offset = 0 // UTF-16 offset at the start of the current line
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let lineEnd = offset + (line as NSString).length
            if i > 0, line.trimmingCharacters(in: .whitespaces) == marker {
                // On or before the closing fence line → inside.
                return utf16Caret <= lineEnd
            }
            offset = lineEnd + 1 // + the "\n"
        }
        // No closing fence yet: the whole block is an open fence.
        return true
    }
}

/// Recursive-descent tokenizer for the inline grammar. Emphasis nests
/// (`**bold with [[Page]]**` keeps the page ref); code spans and math are
/// opaque. Unmatched delimiters fall back to literal text.
public enum InlineParser {

    /// Characters with special inline meaning that a leading `\` escapes: the
    /// token openers (`#` `[` `(` `{`) and the formatting markers
    /// (`` ` `` `*` `~` `=` `$`). Not `\` itself (so `\\` stays literal).
    static let escapable: Set<Character> = ["#", "[", "(", "{", "`", "*", "~", "=", "$"]

    private struct ImageToken {
        var start: Int
        var end: Int
        var alt: String
        var src: String
        var size: ImageSize?
    }

    private static func find(
        _ close: [Character], in chars: [Character], from: Int, sameLine: Bool = true
    ) -> Int? {
        var index = from
        while index + close.count <= chars.count {
            if sameLine, chars[index] == "\n" { return nil }
            if Array(chars[index..<index + close.count]) == close { return index }
            index += 1
        }
        return nil
    }

    private static func findURLEnd(in chars: [Character], from: Int) -> Int? {
        var depth = 0
        var index = from
        while index < chars.count {
            switch chars[index] {
            case "\n": return nil
            case "(": depth += 1
            case ")":
                if depth == 0 { return index }
                depth -= 1
            default: break
            }
            index += 1
        }
        return nil
    }

    private static func pipeImageSize(in rawAlt: String) -> (alt: String, size: ImageSize?) {
        guard let pipe = rawAlt.lastIndex(of: "|") else { return (rawAlt, nil) }
        let tail = rawAlt[rawAlt.index(after: pipe)...]
        func decimal(_ value: Substring) -> Int? {
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
                return nil
            }
            return Int(value)
        }
        if let width = decimal(tail) {
            return (String(rawAlt[..<pipe]), ImageSize(width: width))
        }
        let dimensions = tail.split(separator: "x", omittingEmptySubsequences: false)
        if dimensions.count == 2,
           let width = decimal(dimensions[0]), let height = decimal(dimensions[1]) {
            return (String(rawAlt[..<pipe]), ImageSize(width: width, height: height))
        }
        return (rawAlt, nil)
    }

    /// Parses Logseq's `:width N, :height N` image-size map.
    static func parseLogseqSize(_ inner: String) -> ImageSize? {
        let fields = inner.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count) else { return nil }
        var width: Int?
        var height: Int?
        for field in fields {
            let parts = field.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2,
                  parts[1].unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }),
                  let value = Int(parts[1]), value >= 1 else { return nil }
            switch parts[0] {
            case ":width" where width == nil: width = value
            case ":height" where height == nil: height = value
            default: return nil
            }
        }
        guard width != nil || height != nil else { return nil }
        return ImageSize(width: width, height: height)
    }

    private static func imageToken(in chars: [Character], at start: Int) -> ImageToken? {
        guard start + 1 < chars.count, chars[start] == "!", chars[start + 1] == "[",
              let altEnd = find(["]"], in: chars, from: start + 2),
              altEnd + 1 < chars.count, chars[altEnd + 1] == "(",
              let srcEnd = findURLEnd(in: chars, from: altEnd + 2) else { return nil }

        let rawAlt = String(chars[start + 2..<altEnd])
        let parsedAlt = pipeImageSize(in: rawAlt)
        let src = String(chars[altEnd + 2..<srcEnd])
        var end = srcEnd + 1
        var logseqSize: ImageSize?
        if end < chars.count, chars[end] == "{",
           let suffixEnd = find(["}"], in: chars, from: end + 1),
           let parsed = parseLogseqSize(String(chars[end + 1..<suffixEnd])) {
            logseqSize = parsed
            end = suffixEnd + 1
        }
        return ImageToken(
            start: start, end: end, alt: parsedAlt.alt, src: src,
            size: parsedAlt.size ?? logseqSize
        )
    }

    public static func parse(_ text: String) -> [InlineNode] {
        let chars = Array(text)
        var nodes: [InlineNode] = []
        var literal = ""
        var i = 0

        func flush() {
            if !literal.isEmpty {
                nodes.append(.text(literal))
                literal = ""
            }
        }

        func slice(_ a: Int, _ b: Int) -> String { String(chars[a..<b]) }

        /// Index just past `close`, searching from `from`; nil if absent
        /// before a newline (when sameLine) or end.
        func find(_ close: [Character], from: Int, sameLine: Bool = true) -> Int? {
            var j = from
            while j + close.count <= chars.count {
                if sameLine, chars[j] == "\n" { return nil }
                if Array(chars[j..<j + close.count]) == close { return j }
                j += 1
            }
            return nil
        }

        /// Index of the `)` that closes a link/image destination, honoring
        /// parens *inside* the URL (e.g. `…/image_(3).png`) by tracking nesting —
        /// CommonMark allows balanced parens in a destination. nil if none on the
        /// line. Without this the first inner `)` truncates the URL and the
        /// image/link breaks.
        func findURLEnd(from: Int) -> Int? {
            var depth = 0
            var j = from
            while j < chars.count {
                switch chars[j] {
                case "\n": return nil
                case "(": depth += 1
                case ")": if depth == 0 { return j }; depth -= 1
                default: break
                }
                j += 1
            }
            return nil
        }

        func isTagChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }

        /// End index of a bare `http(s)://…` URL starting at `from`, or nil if
        /// there isn't one. The run stops at whitespace / `<` / `>` / backtick,
        /// then sheds trailing sentence punctuation and an unbalanced `)` — so
        /// `(see https://x.com/a_(b)).` links `https://x.com/a_(b)`, not the
        /// trailing `).`. (GFM-style autolink.)
        func autolinkEnd(from: Int) -> Int? {
            let rest = String(chars[from...]).lowercased()
            let scheme = rest.hasPrefix("https://") ? 8 : (rest.hasPrefix("http://") ? 7 : 0)
            guard scheme > 0 else { return nil }
            var end = from + scheme
            while end < chars.count, !chars[end].isWhitespace, !"<>`".contains(chars[end]) {
                end += 1
            }
            guard end > from + scheme else { return nil } // need a host
            trim: while end > from + scheme {
                switch chars[end - 1] {
                case ".", ",", ";", ":", "!", "?", "'", "\"":
                    end -= 1
                case ")":
                    let opens = chars[from..<end].lazy.filter { $0 == "(" }.count
                    let closes = chars[from..<end].lazy.filter { $0 == ")" }.count
                    if closes > opens { end -= 1 } else { break trim }
                default:
                    break trim
                }
            }
            return end > from + scheme ? end : nil
        }

        while i < chars.count {
            let c = chars[i]
            let prev: Character? = i > 0 ? chars[i - 1] : nil

            switch c {
            case "\\":
                // A backslash escapes the next character when it has special
                // inline meaning, emitting it as literal text (and consuming the
                // backslash) — so `\#tag`, `\[[Page]]`, `\((id))`, `\{{query}}`,
                // `` \`code` ``, `\*`, `\~`, `\=`, and `\$5` are never parsed as a
                // tag / ref / query / code / emphasis / math (nor indexed as one).
                // `\` itself isn't escapable, so `\\` stays two backslashes and
                // paths like `C:\Users` are untouched. Before an ordinary
                // character the backslash stays literal.
                if i + 1 < chars.count, Self.escapable.contains(chars[i + 1]) {
                    literal.append(chars[i + 1])
                    i += 2
                } else {
                    literal.append(c); i += 1
                }

            case "\n":
                flush()
                nodes.append(.lineBreak)
                i += 1

            case "`":
                if let end = find(["`"], from: i + 1), end > i + 1 {
                    flush()
                    nodes.append(.code(slice(i + 1, end)))
                    i = end + 1
                } else {
                    literal.append(c); i += 1
                }

            case "[":
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    if let end = find(["]", "]"], from: i + 2),
                       case let name = slice(i + 2, end),
                       !name.isEmpty, !name.contains("["), !name.contains("]") {
                        flush()
                        nodes.append(.pageRef(name))
                        i = end + 2
                        continue
                    }
                }
                if let labelEnd = find(["]"], from: i + 1),
                   labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(",
                   let urlEnd = findURLEnd(from: labelEnd + 2) {
                    flush()
                    nodes.append(.link(label: slice(i + 1, labelEnd), url: slice(labelEnd + 2, urlEnd)))
                    i = urlEnd + 1
                } else {
                    literal.append(c); i += 1
                }

            case "!":
                if let image = Self.imageToken(in: chars, at: i) {
                    flush()
                    nodes.append(.image(alt: image.alt, src: image.src, size: image.size))
                    i = image.end
                } else {
                    literal.append(c); i += 1
                }

            case "(":
                if i + 1 < chars.count, chars[i + 1] == "(",
                   let end = find([")", ")"], from: i + 2),
                   let uuid = UUID(uuidString: slice(i + 2, end)) {
                    flush()
                    nodes.append(.blockRef(uuid))
                    i = end + 2
                } else {
                    literal.append(c); i += 1
                }

            case "{":
                // `{{embed ((uuid))}}` / `{{embed [[Page]]}}` → an embed node.
                // Any other `{{…}}` (e.g. future `{{query …}}`) stays literal,
                // honouring the §17 reservation.
                if i + 1 < chars.count, chars[i + 1] == "{",
                   let end = find(["}", "}"], from: i + 2) {
                    let inner = slice(i + 2, end)
                    if let target = Self.embedTarget(inner) {
                        flush()
                        nodes.append(.embed(target))
                    } else if let query = Self.queryExpr(inner) {
                        flush()
                        nodes.append(.query(query))
                    } else {
                        flush()
                        nodes.append(.text("{{\(inner)}}")) // literal, round-trips
                    }
                    i = end + 2
                } else {
                    literal.append(c); i += 1
                }

            case "#":
                // A tag must start the text or follow whitespace/bracketing
                // punctuation; `x#y` is not a tag. (SPEC §8.1)
                let boundaryOK = prev == nil || prev!.isWhitespace
                    || "([{'\"".contains(prev!)
                guard boundaryOK else { literal.append(c); i += 1; continue }
                if i + 2 < chars.count, chars[i + 1] == "[", chars[i + 2] == "[" {
                    if let end = find(["]", "]"], from: i + 3),
                       case let name = slice(i + 3, end)
                           .trimmingCharacters(in: .whitespaces).lowercased(),
                       !name.isEmpty, !name.contains("["), !name.contains("]") {
                        flush()
                        nodes.append(.tag(name))
                        i = end + 2
                        continue
                    }
                    literal.append(c); i += 1
                    continue
                }
                var j = i + 1
                while j < chars.count, isTagChar(chars[j]) { j += 1 }
                if j > i + 1 {
                    flush()
                    nodes.append(.tag(slice(i + 1, j).lowercased()))
                    i = j
                } else {
                    literal.append(c); i += 1
                }

            case "*":
                if i + 2 < chars.count, chars[i + 1] == "*", chars[i + 2] == "*",
                   let end = find(["*", "*", "*"], from: i + 3), end > i + 3 {
                    // `***text***` → bold + italic (CommonMark strong+emphasis).
                    flush()
                    nodes.append(.bold([.italic(parse(slice(i + 3, end)))]))
                    i = end + 3
                } else if i + 1 < chars.count, chars[i + 1] == "*",
                   let end = find(["*", "*"], from: i + 2), end > i + 2 {
                    flush()
                    nodes.append(.bold(parse(slice(i + 2, end))))
                    i = end + 2
                } else if let end = find(["*"], from: i + 1), end > i + 1,
                          chars[i + 1] != "*" {
                    flush()
                    nodes.append(.italic(parse(slice(i + 1, end))))
                    i = end + 1
                } else {
                    literal.append(c); i += 1
                }

            case "~":
                if i + 1 < chars.count, chars[i + 1] == "~",
                   let end = find(["~", "~"], from: i + 2), end > i + 2 {
                    flush()
                    nodes.append(.strike(parse(slice(i + 2, end))))
                    i = end + 2
                } else {
                    literal.append(c); i += 1
                }

            case "=":
                if i + 1 < chars.count, chars[i + 1] == "=",
                   let end = find(["=", "="], from: i + 2), end > i + 2 {
                    flush()
                    nodes.append(.highlight(parse(slice(i + 2, end))))
                    i = end + 2
                } else {
                    literal.append(c); i += 1
                }

            case "$":
                if let end = find(["$"], from: i + 1), end > i + 1 {
                    flush()
                    nodes.append(.math(slice(i + 1, end)))
                    i = end + 1
                } else {
                    literal.append(c); i += 1
                }

            case "h", "H":
                // A bare URL must start the text or follow whitespace / opening
                // punctuation, so `foohttp://x` and `…#http` don't linkify.
                let boundaryOK = prev == nil || prev!.isWhitespace
                    || "([{<'\"".contains(prev!)
                if boundaryOK, let end = autolinkEnd(from: i) {
                    flush()
                    nodes.append(.autolink(slice(i, end)))
                    i = end
                } else {
                    literal.append(c); i += 1
                }

            default:
                literal.append(c); i += 1
            }
        }
        flush()
        return nodes
    }

    /// Parses the inside of `{{…}}` as an embed target, else nil (not an embed).
    /// Accepts `embed ((uuid))` and `embed [[Page Name]]`, leniently spaced.
    static func embedTarget(_ inner: String) -> EmbedTarget? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("embed") else { return nil }
        let rest = trimmed.dropFirst("embed".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("(("), rest.hasSuffix("))") {
            let id = rest.dropFirst(2).dropLast(2)
            if let uuid = UUID(uuidString: String(id)) { return .block(uuid) }
        }
        if rest.hasPrefix("[["), rest.hasSuffix("]]") {
            let name = String(rest.dropFirst(2).dropLast(2))
            if !name.isEmpty, !name.contains("["), !name.contains("]") { return .page(name) }
        }
        return nil
    }

    /// Parses the inside of `{{…}}` as a `{{query …}}` expression, else nil.
    static func queryExpr(_ inner: String) -> QueryExpr? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("query") else { return nil }
        let rest = trimmed.dropFirst("query".count)
        // The keyword must be followed by whitespace or an opening paren (so a
        // word like "querying" isn't mistaken for a query).
        guard rest.isEmpty || rest.first!.isWhitespace || rest.first! == "(" else { return nil }
        return QueryParser.parse(String(rest))
    }

    /// Plain-text rendering of nodes (for previews, search snippets).
    public static func plainText(_ nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let s): return s
            case .bold(let n), .italic(let n), .strike(let n), .highlight(let n):
                return plainText(n)
            case .code(let s), .math(let s): return s
            case .link(let label, _): return label
            case .autolink(let url): return url
            case .image(let alt, _, _): return alt
            case .pageRef(let name): return name
            case .blockRef: return "(…)"
            case .tag(let t): return "#" + t
            case .embed, .query: return ""
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    /// Rewrites the n-th parsed image token to the pipe width form, preserving
    /// every character outside that token. A nil width removes either size form.
    public static func settingImageWidth(
        _ content: String, imageIndex: Int, width: Int?
    ) -> String? {
        guard imageIndex >= 0 else { return nil }
        let chars = Array(content)
        var images: [ImageToken] = []
        var index = 0
        while index < chars.count {
            switch chars[index] {
            case "\\":
                if index + 1 < chars.count, escapable.contains(chars[index + 1]) {
                    index += 2
                } else {
                    index += 1
                }
            case "`":
                if let end = find(["`"], in: chars, from: index + 1), end > index + 1 {
                    index = end + 1
                } else {
                    index += 1
                }
            case "$":
                if let end = find(["$"], in: chars, from: index + 1), end > index + 1 {
                    index = end + 1
                } else {
                    index += 1
                }
            case "[":
                if index + 1 < chars.count, chars[index + 1] == "[",
                   let end = find(["]", "]"], in: chars, from: index + 2),
                   case let name = String(chars[index + 2..<end]),
                   !name.isEmpty, !name.contains("["), !name.contains("]") {
                    index = end + 2
                } else if let labelEnd = find(["]"], in: chars, from: index + 1),
                          labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(",
                          let urlEnd = findURLEnd(in: chars, from: labelEnd + 2) {
                    index = urlEnd + 1
                } else {
                    index += 1
                }
            case "(":
                if index + 1 < chars.count, chars[index + 1] == "(",
                   let end = find([")", ")"], in: chars, from: index + 2),
                   UUID(uuidString: String(chars[index + 2..<end])) != nil {
                    index = end + 2
                } else {
                    index += 1
                }
            case "{":
                if index + 1 < chars.count, chars[index + 1] == "{",
                   let end = find(["}", "}"], in: chars, from: index + 2) {
                    index = end + 2
                } else {
                    index += 1
                }
            case "!":
                if let image = imageToken(in: chars, at: index) {
                    images.append(image)
                    index = image.end
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }
        guard images.indices.contains(imageIndex) else { return nil }
        let image = images[imageIndex]
        let sizedAlt = width.map { "\(image.alt)|\($0)" } ?? image.alt
        let replacement = "![\(sizedAlt)](\(image.src))"
        return String(chars[..<image.start]) + replacement + String(chars[image.end...])
    }
}
