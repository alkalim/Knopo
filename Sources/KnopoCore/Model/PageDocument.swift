import Foundation

/// A named document consisting of an ordered tree of blocks. (SPEC §3.2)
/// Maps 1:1 to a Markdown file once it has content; a referenced page with no
/// file is a *stub* and is represented by a PageDocument with `fileExists == false`.
public struct PageDocument: Identifiable, Sendable {
    /// Display name — the casing from when the page was first created.
    public var name: String
    /// Top-level blocks.
    public var blocks: [Block]
    /// Page properties and other text preceding the first outline block.
    public var preamble: String
    /// Whether the page lives in `journals/` (or is named like an ISO date there).
    public var isJournal: Bool
    /// Whether a file currently backs this page (false = stub).
    public var fileExists: Bool
    /// Unsaved in-memory changes.
    public var isDirty: Bool

    public var id: String { PageName.key(name) }
    public var nameKey: String { PageName.key(name) }

    public init(
        name: String,
        blocks: [Block] = [],
        preamble: String = "",
        isJournal: Bool = false,
        fileExists: Bool = false,
        isDirty: Bool = false
    ) {
        self.name = name
        self.blocks = blocks
        self.preamble = preamble
        self.isJournal = isJournal
        self.fileExists = fileExists
        self.isDirty = isDirty
    }

    /// Page-level properties: `key:: value` pairs of the first block. (SPEC §3.2)
    public var pageProperties: [BlockProperty] {
        blocks.first?.properties ?? []
    }

    /// Properties written in the preamble — un-bulleted `key:: value` lines
    /// before the first block (the Logseq page-property convention). Indexed
    /// alongside the first block's own properties so they're queryable; the
    /// unedited source lines round-trip untouched. Fenced examples are ignored.
    public var preambleProperties: [BlockProperty] {
        preamblePropertyLines.map(\.property)
    }

    private var preamblePropertyLines: [(line: Int, property: BlockProperty)] {
        preambleLines.enumerated().compactMap { index, line in
            guard let property = line.property else { return nil }
            return (index, property)
        }
    }

    /// Source lines with page properties identified separately from fenced examples.
    public var preambleLines: [(text: String, property: BlockProperty?)] {
        let lines = PageParser.splitKeepingTerminators(preamble)
        let fences = PageParser.preambleFenceLines(lines)
        return lines.enumerated().map { index, line in
            let text = PageParser.chomp(String(line))
            return (text, fences.contains(index) ? nil : PageParser.matchProperty(text))
        }
    }

    /// Replaces or removes one page property, preserving all other source lines.
    /// An index equal to the property count appends a new property.
    @discardableResult
    public mutating func setPreambleProperty(at index: Int, to property: BlockProperty?) -> Bool {
        if let property, !Self.isValidPreambleProperty(property) { return false }
        let existing = preamblePropertyLines
        guard index >= 0, index <= existing.count else { return false }
        var lines = PageParser.splitKeepingTerminators(preamble).map(String.init)
        if index == existing.count {
            guard let property else { return false }
            return insertPreambleProperty(property, at: index)
        } else {
            let source = existing[index]
            guard property != source.property else { return true }
            if let property {
                let ending = lines[source.line].last?.isNewline == true
                    ? String(lines[source.line].suffix(1)) : ""
                lines[source.line] = "\(property.key):: \(property.value)" + ending
            } else {
                lines.remove(at: source.line)
            }
            preamble = lines.joined()
        }
        return true
    }

    /// Inserts a property between existing rows without rewriting their source.
    @discardableResult
    public mutating func insertPreambleProperty(_ property: BlockProperty, at index: Int) -> Bool {
        let existing = preamblePropertyLines
        guard Self.isValidPreambleProperty(property), index >= 0, index <= existing.count else { return false }
        var lines = PageParser.splitKeepingTerminators(preamble).map(String.init)
        let newline = lines.first(where: { $0.last?.isNewline == true }).map { String($0.suffix(1)) } ?? "\n"
        let position = index < existing.count ? existing[index].line : existing.last.map { $0.line + 1 } ?? 0
        if position > 0, lines[position - 1].last?.isNewline != true { lines[position - 1] += newline }
        lines.insert("\(property.key):: \(property.value)" + newline, at: position)
        preamble = lines.joined()
        return true
    }

    public static func isValidPreambleProperty(_ property: BlockProperty) -> Bool {
        !property.value.contains(where: \.isNewline)
            && PageParser.matchProperty("\(property.key):: \(property.value)") == property
    }

    /// `title::` overrides the display name. (SPEC §4.2)
    public func displayTitle(
        using dateFormat: JournalDateFormat, locale: Locale = .current
    ) -> String {
        if let t = pageProperties.first(where: { $0.key == "title" })?.value,
           !t.isEmpty {
            return t
        }
        if isJournal, let date = JournalDate(pageName: name) {
            return date.displayName(using: dateFormat, locale: locale)
        }
        return name
    }

    /// True when the page has no meaningful content (used for lazy journal files
    /// and stub materialization).
    public var isEffectivelyEmpty: Bool {
        preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blocks.flattened.allSatisfy {
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.properties.isEmpty
            }
    }
}
