import Foundation

/// Page-name rules (SPEC §3.2): unique case-insensitively; `\ # [ ]` and
/// leading/trailing whitespace are forbidden; `/` is allowed and reserved for
/// namespace grouping (flat pages, hierarchical display only).
public enum PageName {
    /// Normalization key for uniqueness. Case-insensitive for ordinary pages;
    /// date-named pages canonicalize to their ISO date, so every spelling of a
    /// day — `2026-06-10`, Logseq's `2026_06_10`, etc. — is one journal
    /// identity. This is what lets an ISO `[[2026-06-10]]` reference resolve to
    /// an imported underscore-named journal file.
    public static func key(_ name: String) -> String {
        if let date = JournalDate(pageName: name) { return date.pageName }
        return name.lowercased()
    }

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let forbidden: Set<Character> = ["\\", "#", "[", "]"]
        guard !name.contains(where: { forbidden.contains($0) }) else { return false }
        guard !name.contains("\n") else { return false }
        // No empty namespace segments ("a//b", "/a", "a/").
        if name.contains("/") {
            let segments = name.components(separatedBy: "/")
            guard segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return false
            }
        }
        return true
    }

    /// Namespace segments for hierarchical display in the page browser.
    public static func segments(_ name: String) -> [String] {
        name.components(separatedBy: "/")
    }

    // MARK: Filenames (SPEC §4.1)

    /// Characters that must be percent-encoded in filenames: `%` (the escape
    /// itself), `/` (path separator), and `:` (legacy macOS separator).
    public static func fileName(for name: String) -> String {
        var out = ""
        for ch in name.unicodeScalars {
            switch ch {
            case "%": out += "%25"
            case "/": out += "%2F"
            case ":": out += "%3A"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + ".md"
    }

    /// Inverse of `fileName(for:)`. Returns nil if the file is not a page file.
    public static func name(fromFileName fileName: String) -> String? {
        guard fileName.lowercased().hasSuffix(".md") else { return nil }
        let stem = String(fileName.dropLast(3))
        return stem.removingPercentEncoding ?? stem
    }
}
