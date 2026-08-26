import Foundation

/// Journal pages are named by ISO date `2026-06-10` (SPEC §10) and displayed
/// using the user's date format setting (default `Jun 10th, 2026`).
public struct JournalDate: Equatable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: comps),
              cal.component(.year, from: date) == year,
              cal.component(.month, from: date) == month,
              cal.component(.day, from: date) == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// Parses a journal page name in any recognized spelling: ISO `2026-06-10`,
    /// Logseq's underscore filename `2026_06_10`, or the friendly display /
    /// Logseq reference form `Jun 10th, 2026`. All fold to the same day, so a
    /// `[[Jun 10th, 2026]]` reference resolves to the journal file. Strict about
    /// validity (zero-padded numbers, real calendar date).
    public init?(pageName: String) {
        let parts = pageName.replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: "-")
        if parts.count == 3,
           parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            self.init(year: y, month: m, day: d)
        } else if let f = Self.parseFriendly(pageName) {
            self.init(year: f.year, month: f.month, day: f.day)
        } else {
            return nil
        }
    }

    /// Parses the display form `Jun 10th, 2026` (also Logseq's default journal
    /// reference format) back to its date. Month is case-insensitive and may be
    /// abbreviated or full; the ordinal suffix and comma are optional.
    static func parseFriendly(_ s: String) -> (year: Int, month: Int, day: Int)? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        let tokens = s.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard tokens.count == 3,
              let month = months.firstIndex(where: { tokens[0].hasPrefix($0) }).map({ $0 + 1 })
        else { return nil }
        let digits = tokens[1].prefix { $0.isNumber }
        let suffix = String(tokens[1].dropFirst(digits.count))
        guard let day = Int(digits),
              suffix.isEmpty || ["st", "nd", "rd", "th"].contains(suffix),
              tokens[2].count == 4, let year = Int(tokens[2])
        else { return nil }
        return (year, month, day)
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!; self.month = c.month!; self.day = c.day!
    }

    public static func today() -> JournalDate { JournalDate(date: Date()) }

    /// The canonical page name: `2026-06-10`.
    public var pageName: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func displayName(using format: JournalDateFormat) -> String {
        format.string(from: self)
    }

    public static func ordinalSuffix(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    public func adding(days: Int) -> JournalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        let date = cal.date(from: comps)!
        let shifted = cal.date(byAdding: .day, value: days, to: date)!
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return JournalDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    public static func < (lhs: JournalDate, rhs: JournalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
