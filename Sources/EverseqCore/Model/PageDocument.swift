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

    /// `title::` overrides the display name. (SPEC §4.2)
    public var displayTitle: String {
        if let t = pageProperties.first(where: { $0.key == "title" })?.value,
           !t.isEmpty {
            return t
        }
        if isJournal, let date = JournalDate(pageName: name) {
            return date.displayName
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
