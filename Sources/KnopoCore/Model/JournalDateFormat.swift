import Foundation

/// A journal-title display pattern stored in `.knopo/config.json`.
///
/// Patterns use `DateFormatter`'s Unicode syntax plus Knopo's English-only
/// `{ordinal}` extension immediately after a day field, for example
/// `MMM d{ordinal}, yyyy` → `Jun 10th, 2026`. Journal identity stays ISO; this
/// type affects display text only.
public struct JournalDateFormat: Codable, Equatable, Hashable, Sendable {
    public let pattern: String

    private static let ordinalMarker = "\u{F8FF}"
    private static let formatterCache = FormatterCache()

    public static let `default` = JournalDateFormat(pattern: "MMM d{ordinal}, yyyy")

    public static let presets: [JournalDateFormat] = [
        .default,
        JournalDateFormat(pattern: "MMMM d, yyyy"),
        JournalDateFormat(pattern: "d MMM yyyy"),
        JournalDateFormat(pattern: "d MMMM yyyy"),
        JournalDateFormat(pattern: "yyyy-MM-dd"),
    ]

    /// Accepts persisted input. Call `init?(validating:)` for user-entered text.
    public init(pattern: String) {
        // This was the declared default before formatting was implemented. Its
        // literal "th" was never used: JournalDate supplied the correct suffix.
        self.pattern = pattern == "MMM d'th', yyyy"
            ? Self.default.pattern
            : pattern
    }

    public init?(validating pattern: String) {
        let candidate = JournalDateFormat(pattern: pattern)
        guard candidate.validationError == nil else { return nil }
        self = candidate
    }

    /// Nil when the pattern is suitable for saving from Settings.
    ///
    /// English for now: most of these describe the Unicode-pattern UI that the
    /// semantic date styles retire. Localized once that ships - see
    /// workdocs/design/localization.md, phase 2b.
    public var validationError: String? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a date format."
        }

        let ordinal = "{ordinal}"
        let pieces = pattern.components(separatedBy: ordinal)
        guard pieces.count <= 2 else {
            return "Use {ordinal} at most once."
        }
        guard pieces.joined().rangeOfCharacter(from: CharacterSet(charactersIn: "{}")) == nil else {
            return "The only supported placeholder is {ordinal}."
        }
        if pieces.count == 2 {
            guard pieces[0].last == "d", Self.isOutsideQuotes(atEndOf: pieces[0]) else {
                return "Place {ordinal} immediately after d."
            }
        }
        guard Self.hasBalancedQuotes(pattern) else {
            return "Close the quoted literal in the date format."
        }
        guard !pattern.contains(Self.ordinalMarker) else {
            return "The Apple logo character is not supported in date formats."
        }
        guard !string(from: JournalDate(year: 2026, month: 6, day: 10)!).isEmpty else {
            return "This date format produces no text."
        }
        return nil
    }

    public func string(from journalDate: JournalDate) -> String {
        var components = DateComponents()
        components.calendar = Self.calendar
        components.timeZone = Self.timeZone
        components.year = journalDate.year
        components.month = journalDate.month
        components.day = journalDate.day
        guard let date = components.date else { return journalDate.pageName }

        let formatterPattern = pattern.replacingOccurrences(
            of: "{ordinal}", with: Self.ordinalMarker)
        return Self.formatterCache.string(from: date, pattern: formatterPattern)
            .replacingOccurrences(
                of: Self.ordinalMarker, with: Self.ordinalSuffix(journalDate.day))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(pattern: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pattern)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    private static let timeZone = TimeZone(identifier: "UTC")!

    private static func ordinalSuffix(_ day: Int) -> String {
        let tens = day % 100
        if (11...13).contains(tens) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func hasBalancedQuotes(_ pattern: String) -> Bool {
        var quoted = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            if pattern[index] == "'" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "'" {
                    index = pattern.index(after: next)
                    continue
                }
                quoted.toggle()
            }
            index = pattern.index(after: index)
        }
        return !quoted
    }

    private static func isOutsideQuotes(atEndOf prefix: String) -> Bool {
        hasBalancedQuotes(prefix)
    }

    /// `DateFormatter` is expensive to construct and is not thread-safe. Keep
    /// one per pattern and hold the lock for both lookup and formatting.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func string(from date: Date, pattern: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let formatter: DateFormatter
            if let cached = formatters[pattern] {
                formatter = cached
            } else {
                if formatters.count >= 32 {
                    formatters.removeAll(keepingCapacity: true)
                }
                let created = DateFormatter()
                created.locale = Locale(identifier: "en_US_POSIX")
                created.calendar = JournalDateFormat.calendar
                created.timeZone = JournalDateFormat.timeZone
                created.dateFormat = pattern
                formatters[pattern] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }
}
