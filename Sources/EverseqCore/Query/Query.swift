import Foundation

/// A `{{query …}}` expression (SPEC §17). A small, *closed* filter
/// language — no Datalog — so every node compiles to a known SQL fragment over
/// the `cache.db` facet tables. Phase 1 supports tags, page references, task
/// state, and properties, combined with `and` / `or` / `not`.
public indirect enum QueryExpr: Equatable, Sendable {
    case and([QueryExpr])
    case or([QueryExpr])
    case not(QueryExpr)
    /// Block carries `#tag` (tag stored normalized lowercase).
    case tag(String)
    /// Block links to `[[Page]]` (matched case-insensitively via `PageName.key`).
    case pageRef(String)
    /// Block's task marker is one of these states.
    case task([TodoState])
    /// Block has property `key` (and, when `value != nil`, that exact value).
    case property(key: String, value: String?)
}

/// Parses the text inside `{{query …}}` (after the `query` keyword) into a
/// `QueryExpr`. Returns nil on any malformed input, so the inline parser leaves
/// the literal `{{query …}}` untouched (round-trips, honouring §16).
///
/// Two equivalent surfaces:
/// - **Shorthand** — bare filters, implicitly AND-ed: `#urgent TODO [[Project X]]`
/// - **Structured** — s-expressions: `(and #urgent (not DONE) (or …))`
public enum QueryParser {

    public static func parse(_ source: String) -> QueryExpr? {
        var tokens = tokenize(source)
        guard !tokens.isEmpty else { return nil }
        var terms: [QueryExpr] = []
        while !tokens.isEmpty {
            guard let expr = parseExpr(&tokens) else { return nil }
            terms.append(expr)
        }
        // Multiple top-level filters are implicitly AND-ed (shorthand).
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    // MARK: - Tokens

    private enum Token: Equatable {
        case open, close
        case tag(String)                       // #x / #[[x y]]
        case page(String)                      // [[x y]]
        case property(key: String, value: String?)
        case word(String)                      // bare word or quoted string
    }

    private static func tokenize(_ source: String) -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0

        func isBareTerminator(_ c: Character) -> Bool {
            c.isWhitespace || c == "(" || c == ")"
        }
        /// Reads a `"…"` string or a bare word starting at `i`; advances `i`.
        func readValueAtom() -> String? {
            skipSpaces()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "(" || c == ")" || c == "#" { return nil }
            if c == "[" , i + 1 < chars.count, chars[i + 1] == "[" { return nil }
            if c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 } // closing quote
                return s
            }
            var s = ""
            while i < chars.count, !isBareTerminator(chars[i]) { s.append(chars[i]); i += 1 }
            return s.isEmpty ? nil : s
        }
        func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" { tokens.append(.open); i += 1; continue }
            if c == ")" { tokens.append(.close); i += 1; continue }

            if c == "#" {
                // #[[multi word]] or #tag
                if i + 2 < chars.count, chars[i + 1] == "[", chars[i + 2] == "[" {
                    i += 3
                    var s = ""
                    while i + 1 < chars.count, !(chars[i] == "]" && chars[i + 1] == "]") {
                        s.append(chars[i]); i += 1
                    }
                    if i + 1 < chars.count { i += 2 } // ]]
                    tokens.append(.tag(s.trimmingCharacters(in: .whitespaces).lowercased()))
                } else {
                    i += 1
                    var s = ""
                    while i < chars.count, !isBareTerminator(chars[i]) { s.append(chars[i]); i += 1 }
                    tokens.append(.tag(s.lowercased()))
                }
                continue
            }

            if c == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                i += 2
                var s = ""
                while i + 1 < chars.count, !(chars[i] == "]" && chars[i + 1] == "]") {
                    s.append(chars[i]); i += 1
                }
                if i + 1 < chars.count { i += 2 } // ]]
                tokens.append(.page(s.trimmingCharacters(in: .whitespaces)))
                continue
            }

            if c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
                tokens.append(.word(s))
                continue
            }

            // A bare word — possibly a `key:: value` property.
            var word = ""
            while i < chars.count, !isBareTerminator(chars[i]) { word.append(chars[i]); i += 1 }
            if let range = word.range(of: "::") {
                let key = String(word[..<range.lowerBound])
                let inline = String(word[range.upperBound...])
                if !key.isEmpty {
                    if !inline.isEmpty {
                        tokens.append(.property(key: key, value: inline)) // key::value
                    } else {
                        // `key::` — take the next value atom as the value, if any.
                        let value = readValueAtom()
                        tokens.append(.property(key: key, value: value))
                    }
                    continue
                }
            }
            tokens.append(.word(word))
        }
        return tokens
    }

    // MARK: - Recursive-descent parser

    private static func parseExpr(_ tokens: inout [Token]) -> QueryExpr? {
        guard let token = tokens.first else { return nil }
        switch token {
        case .open:
            tokens.removeFirst()
            return parseCompound(&tokens)
        case .tag(let t):
            tokens.removeFirst(); return t.isEmpty ? nil : .tag(t)
        case .page(let p):
            tokens.removeFirst(); return p.isEmpty ? nil : .pageRef(p)
        case .property(let key, let value):
            tokens.removeFirst(); return .property(key: key, value: value)
        case .word(let w):
            tokens.removeFirst()
            // A bare task-state word (TODO / DONE) is a task filter.
            if let state = TodoState(rawValue: w.uppercased()) { return .task([state]) }
            return nil // unknown bare word → malformed
        case .close:
            return nil
        }
    }

    /// Parses the body after a `(` — a head keyword and its arguments — through
    /// the matching `)`.
    private static func parseCompound(_ tokens: inout [Token]) -> QueryExpr? {
        guard case .word(let head)? = tokens.first else { return nil }
        tokens.removeFirst()
        switch head.lowercased() {
        case "and":
            guard let args = parseArgs(&tokens) else { return nil }
            return .and(args)
        case "or":
            guard let args = parseArgs(&tokens) else { return nil }
            return .or(args)
        case "not":
            guard let inner = parseExpr(&tokens), expectClose(&tokens) else { return nil }
            return .not(inner)
        case "tag":
            guard let name = parseAtomString(&tokens), expectClose(&tokens) else { return nil }
            return .tag(name.lowercased())
        case "page":
            guard let name = parseAtomString(&tokens), expectClose(&tokens) else { return nil }
            return .pageRef(name)
        case "task":
            var states: [TodoState] = []
            while case .word(let w)? = tokens.first {
                tokens.removeFirst()
                guard let state = TodoState(rawValue: w.uppercased()) else { return nil }
                states.append(state)
            }
            guard !states.isEmpty, expectClose(&tokens) else { return nil }
            return .task(states)
        case "property":
            guard let key = parseAtomString(&tokens) else { return nil }
            var value: String?
            if case .word(let v)? = tokens.first { tokens.removeFirst(); value = v }
            else if case .page(let v)? = tokens.first { tokens.removeFirst(); value = v }
            guard expectClose(&tokens) else { return nil }
            return .property(key: key, value: value)
        default:
            return nil
        }
    }

    /// Parses zero or more expressions up to (and consuming) the closing `)`.
    private static func parseArgs(_ tokens: inout [Token]) -> [QueryExpr]? {
        var args: [QueryExpr] = []
        while let token = tokens.first, token != .close {
            guard let expr = parseExpr(&tokens) else { return nil }
            args.append(expr)
        }
        return expectClose(&tokens) ? args : nil
    }

    /// A bare string argument for `(tag …)` / `(page …)` / `(property …)`.
    private static func parseAtomString(_ tokens: inout [Token]) -> String? {
        switch tokens.first {
        case .word(let w): tokens.removeFirst(); return w
        case .page(let p): tokens.removeFirst(); return p
        case .tag(let t): tokens.removeFirst(); return t
        default: return nil
        }
    }

    private static func expectClose(_ tokens: inout [Token]) -> Bool {
        guard tokens.first == .close else { return false }
        tokens.removeFirst()
        return true
    }
}
