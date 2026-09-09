import Foundation

/// How a journal title is displayed. App-wide: the app layer persists it in user
/// preferences, and `GraphConfig` only decodes the legacy per-graph value.
///
/// Either one of the built-in `Style`s, which the OS renders in the user's
/// locale, or a raw Unicode pattern as an escape hatch. Journal *identity* stays
/// ISO either way; this type affects display text only.
public struct JournalDateFormat: Codable, Equatable, Hashable, Sendable {
    /// The built-in formats. Field order, separators and month names all come
    /// from the locale: `abbreviated` is `Jun 10, 2026` in en_US, `10. Juni
    /// 2026` in de_DE and `2026年6月10日` in ja_JP.
    public enum Style: String, CaseIterable, Sendable {
        /// Shortened month name.
        case abbreviated
        /// Full month name.
        case long
        /// All-numeric, in the locale's field order.
        case numeric
        /// `2026-06-10`, the same form as the filename. Never localized.
        case iso
    }

    /// What gets persisted: a `Style.rawValue`, or a Unicode pattern.
    public let rawValue: String

    /// Nil when this is a custom pattern.
    public var style: Style? { Style(rawValue: rawValue) }
    /// Nil when this is a built-in style.
    public var customPattern: String? { style == nil ? rawValue : nil }

    public static let `default` = JournalDateFormat(style: .abbreviated)

    public static let presets: [JournalDateFormat] = Style.allCases.map(JournalDateFormat.init)

    public init(style: Style) {
        rawValue = style.rawValue
    }

    /// Accepts persisted input: a style name resolves to that style, anything
    /// else is treated as a pattern. Call `init?(validating:)` for user-entered
    /// text.
    public init(rawValue: String) {
        // This was the declared default before formatting was implemented. Its
        // literal "th" was never used: JournalDate supplied the correct suffix.
        self.rawValue = rawValue == "MMM d'th', yyyy" ? "MMM d{ordinal}, yyyy" : rawValue
    }

    public init?(validating rawValue: String) {
        let candidate = JournalDateFormat(rawValue: rawValue)
        if let pattern = candidate.customPattern,
           Self.problem(withPattern: pattern) != nil { return nil }
        self = candidate
    }

    // MARK: - Rendering

    /// `locale` is a parameter so tests can pin one; the app always wants the
    /// user's.
    public func string(from journalDate: JournalDate, locale: Locale = .current) -> String {
        guard let style else {
            return Self.string(from: journalDate, pattern: rawValue, locale: locale)
        }
        switch style {
        // The identity form itself, so it cannot drift from the filename.
        case .iso: return journalDate.pageName
        case .numeric: return Self.string(from: journalDate, template: "yMd", locale: locale)
        case .abbreviated: return Self.string(from: journalDate, template: "yMMMd", locale: locale)
        case .long: return Self.string(from: journalDate, template: "yMMMMd", locale: locale)
        }
    }

    /// Asks the locale how it orders and punctuates the requested fields, then
    /// formats with the pattern it hands back.
    private static func string(
        from journalDate: JournalDate, template: String, locale: Locale
    ) -> String {
        let locale = gregorian(locale)
        return string(
            from: journalDate,
            pattern: formatterCache.pattern(for: template, locale: locale),
            locale: locale)
    }

    /// The same locale, but asked how it writes *Gregorian* dates.
    ///
    /// Pinning the formatter's calendar is not enough. A region whose default
    /// calendar is not Gregorian gets a template carrying an era field - Thai
    /// and Islamic regions produce `dd/MM/y GGGG`, the Japanese calendar
    /// `GGGGGy/MM/dd` - so a Gregorian date renders as "10/06/2026 A" or
    /// "AD2026/06/10". Asking a Gregorian locale drops the era, because for
    /// Gregorian dates the locale does not print one.
    private static func gregorian(_ locale: Locale) -> Locale {
        guard locale.calendar.identifier != .gregorian else { return locale }
        var components = Locale.Components(locale: locale)
        components.calendar = .gregorian
        return Locale(components: components)
    }

    private static func string(
        from journalDate: JournalDate, pattern: String, locale: Locale
    ) -> String {
        guard let date = date(for: journalDate) else { return journalDate.pageName }
        // Format around `{ordinal}` rather than substituting a sentinel into the
        // pattern: any sentinel can collide with a character the user typed.
        // Validation keeps the split point outside quotes, so the pieces are
        // each a valid pattern on their own.
        let pieces = pattern.components(separatedBy: "{ordinal}")
        let rendered = pieces.map { formatterCache.string(from: date, pattern: $0, locale: locale) }
        guard pieces.count > 1 else { return rendered[0] }
        return rendered.joined(separator: ordinalSuffix(journalDate.day, locale: locale))
    }

    private static func date(for journalDate: JournalDate) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = journalDate.year
        components.month = journalDate.month
        components.day = journalDate.day
        return components.date
    }

    // MARK: - Custom-pattern validation

    /// Why a hand-typed pattern cannot be saved. The engine names the problem;
    /// the app layer words it, so KnopoCore needs no bundle of its own.
    public enum PatternProblem: Sendable, Equatable {
        case empty
        /// Spells one of the built-in style names, which would decode as that
        /// style and never as a pattern.
        case reservedName
        case repeatedOrdinal
        case unknownPlaceholder
        case ordinalNotAfterDay
        case unbalancedQuote
        case producesNoText
    }

    /// Nil when `pattern` is suitable for saving as a custom format.
    public static func problem(withPattern pattern: String) -> PatternProblem? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        guard Style(rawValue: pattern) == nil else { return .reservedName }

        let pieces = pattern.components(separatedBy: "{ordinal}")
        guard pieces.count <= 2 else { return .repeatedOrdinal }
        guard pieces.joined().rangeOfCharacter(from: CharacterSet(charactersIn: "{}")) == nil else {
            return .unknownPlaceholder
        }
        if pieces.count == 2 {
            guard pieces[0].last == "d", hasBalancedQuotes(pieces[0]) else {
                return .ordinalNotAfterDay
            }
        }
        guard hasBalancedQuotes(pattern) else { return .unbalancedQuote }
        guard let sample = JournalDate(year: 2026, month: 6, day: 10),
              !string(from: sample, pattern: pattern, locale: .current).isEmpty
        else { return .producesNoText }
        return nil
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - Internals

    private static let formatterCache = FormatterCache()

    /// Gregorian and UTC even when the user's region is not: a journal page is
    /// identified by a Gregorian ISO date, so its title has to name the same
    /// day. Only the *language* of the title follows the locale.
    private static let timeZone = TimeZone(identifier: "UTC")!
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// The locale's ordinal suffix for a day, or "" where it has none.
    ///
    /// Foundation gives the whole ordinal ("10th", "10.", "10e"), so the suffix
    /// is what follows the number. Locales that *prefix* instead - Japanese
    /// "第10" - get nothing rather than a misplaced marker; `{ordinal}` is an
    /// escape-hatch feature, and no built-in style uses it.
    private static func ordinalSuffix(_ day: Int, locale: Locale) -> String {
        numberCache.ordinalSuffix(day, locale: locale)
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

    /// `DateFormatter` is expensive to construct and is not thread-safe. Keep
    /// one per pattern and locale, and hold the lock for both lookup and
    /// formatting.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]
        private var patterns: [String: String] = [:]

        /// `dateFormat(fromTemplate:)` is a CLDR lookup costing ~2.3 µs, and it
        /// otherwise runs on every render, ahead of the formatter cache.
        func pattern(for template: String, locale: Locale) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = "\(locale.identifier)\u{0}\(template)"
            if let cached = patterns[key] { return cached }
            let resolved = DateFormatter.dateFormat(
                fromTemplate: template, options: 0, locale: locale) ?? template
            patterns[key] = resolved
            return resolved
        }

        func string(from date: Date, pattern: String, locale: Locale) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = "\(locale.identifier)\u{0}\(pattern)"
            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                if formatters.count >= 32 {
                    formatters.removeAll(keepingCapacity: true)
                }
                let created = DateFormatter()
                created.locale = locale
                created.calendar = JournalDateFormat.calendar
                created.timeZone = JournalDateFormat.timeZone
                created.dateFormat = pattern
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }

    private static let numberCache = NumberFormatterCache()

    private final class NumberFormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: NumberFormatter] = [:]
        private var suffixes: [String: String] = [:]

        /// Two `NumberFormatter` lookups cost ~1.8 µs, so the answer is kept:
        /// there are only ever 31 days per locale.
        func ordinalSuffix(_ day: Int, locale: Locale) -> String {
            lock.lock()
            let key = "\(locale.identifier)\u{0}\(day)"
            if let cached = suffixes[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let plain = string(day, style: .none, locale: locale)
            let ordinal = string(day, style: .ordinal, locale: locale)
            let suffix = ordinal.hasPrefix(plain)
                ? String(ordinal.dropFirst(plain.count))
                : ""   // a locale that prefixes its ordinals has no suffix to add
            lock.lock()
            suffixes[key] = suffix
            lock.unlock()
            return suffix
        }

        func string(_ value: Int, style: NumberFormatter.Style, locale: Locale) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = "\(locale.identifier)\u{0}\(style.rawValue)"
            let formatter: NumberFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                let created = NumberFormatter()
                created.locale = locale
                created.numberStyle = style
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
    }
}
