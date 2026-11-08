import Foundation

/// A named document consisting of an ordered tree of blocks. (SPEC §3.2)
/// Maps 1:1 to a Markdown file once it has content; a referenced page with no
/// file is a *stub* and is represented by a PageDocument with `fileExists == false`.
public struct PageDocument: Identifiable, Sendable {
    /// Display name — the casing from when the page was first created.
    public var name: String
    /// Top-level blocks.
    public var blocks: [Block]
    /// Verbatim lines preceding the first bullet, preserved for round-trip.
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
    /// preamble text itself round-trips untouched. Non-property lines are ignored.
    public var preambleProperties: [BlockProperty] {
        preamble.components(separatedBy: "\n").compactMap(PageParser.matchProperty)
    }

    /// Alternative page names from the preamble and first block.
    public var aliases: [String] {
        Self.aliases(in: preambleProperties + pageProperties, pageName: name)
    }

    static func aliases(in properties: [BlockProperty], pageName: String) -> [String] {
        var seen: Set<String> = [PageName.key(pageName)]
        return properties.filter { $0.key.lowercased() == "alias" }.flatMap { property in
            // Bracketed names can contain commas, such as [[Doe, Jane]].
            var parts: [String] = []
            var remaining = property.value[...]
            while !remaining.isEmpty {
                remaining = remaining.drop(while: { $0.isWhitespace || $0 == "," })
                guard !remaining.isEmpty else { break }
                if remaining.hasPrefix("[["), let end = remaining.range(of: "]]") {
                    parts.append(String(remaining.dropFirst(2)[..<end.lowerBound]))
                    remaining = remaining[end.upperBound...].drop(while: { $0.isWhitespace })
                    // A bracketed name must be a complete list entry.
                    if let next = remaining.first, next != "," {
                        parts.removeLast()
                        remaining = remaining.drop(while: { $0 != "," })
                    }
                } else {
                    let end = remaining.firstIndex(of: ",") ?? remaining.endIndex
                    parts.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
            }
            return parts.compactMap { part -> String? in
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                // Calendar names always identify their journal day.
                guard PageName.isValid(name), JournalDate(pageName: name) == nil,
                      seen.insert(PageName.key(name)).inserted else { return nil }
                return name
            }
        }
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
