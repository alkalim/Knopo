import Foundation
import Testing
@testable import KnopoCore

@Suite struct JournalDateFormatTests {
    private let june = JournalDate(year: 2026, month: 6, day: 10)!
    private let january = JournalDate(year: 2026, month: 1, day: 10)!

    private func render(_ style: JournalDateFormat.Style, _ date: JournalDate, _ locale: String)
        -> String
    {
        JournalDateFormat(style: style).string(from: date, locale: Locale(identifier: locale))
    }

    /// Field order, separators and month names all come from the locale - the
    /// point of the built-in styles.
    @Test func builtInStylesFollowTheLocale() {
        expectEqual(render(.numeric, june, "en_US"), "6/10/2026")
        expectEqual(render(.abbreviated, june, "en_US"), "Jun 10, 2026")
        expectEqual(render(.long, june, "en_US"), "June 10, 2026")

        // German leads with the day and abbreviates with a trailing period.
        expectEqual(render(.numeric, january, "de_DE"), "10.1.2026")
        expectEqual(render(.abbreviated, january, "de_DE"), "10. Jan. 2026")
        expectEqual(render(.long, january, "de_DE"), "10. Januar 2026")

        // Japanese leads with the year and uses its own field markers.
        expectEqual(render(.abbreviated, june, "ja_JP"), "2026年6月10日")
    }

    /// The ISO style is the page name itself, so a title can never disagree with
    /// the filename - whatever the region's calendar or digits.
    @Test func isoStyleIsTheFilenameForm() {
        for locale in ["en_US", "ja_JP", "ar_EG", "th_TH"] {
            expectEqual(render(.iso, june, locale), june.pageName)
            expectEqual(render(.iso, june, locale), "2026-06-10")
        }
    }

    /// A Gregorian ISO date names the page, so the title names the same day even
    /// where the region's default calendar does not - Thai would otherwise show
    /// the Buddhist year 2569, and the Japanese calendar R8.
    ///
    /// `en_TH` and `en_SA` are the reachable cases: an English UI in a region
    /// whose calendar is not Gregorian. Both used to render a stray era marker,
    /// "10/06/2026 A", because the locale's template carries `GGGG`.
    @Test func nonGregorianRegionsStillNameTheGregorianDay() {
        expectEqual(render(.numeric, june, "en_TH"), "10/06/2026")
        expectEqual(render(.numeric, june, "en_SA"), "10/06/2026")
        expectEqual(render(.numeric, june, "th_TH"), "10/6/2026")
        expectEqual(render(.numeric, june, "ja_JP@calendar=japanese"), "2026/6/10")
    }

    @Test func ordinalSuffixHandlesEnglishExceptions() {
        let expected = [
            1: "1st", 2: "2nd", 3: "3rd", 4: "4th",
            11: "11th", 12: "12th", 13: "13th",
            21: "21st", 22: "22nd", 23: "23rd",
        ]
        let format = JournalDateFormat(rawValue: "d{ordinal}")
        for (day, text) in expected {
            expectEqual(
                format.string(
                    from: JournalDate(year: 2026, month: 1, day: day)!,
                    locale: Locale(identifier: "en_US")),
                text)
        }
    }

    /// `{ordinal}` is no longer English: Foundation supplies each locale's own
    /// suffix, and locales that prefix their ordinals get none rather than a
    /// misplaced marker.
    @Test func ordinalSuffixFollowsTheLocale() {
        let format = JournalDateFormat(rawValue: "d{ordinal}")
        expectEqual(format.string(from: june, locale: Locale(identifier: "en_US")), "10th")
        expectEqual(format.string(from: june, locale: Locale(identifier: "de_DE")), "10.")
        expectEqual(format.string(from: june, locale: Locale(identifier: "fr_FR")), "10e")
        expectEqual(format.string(from: june, locale: Locale(identifier: "ja_JP")), "10")
    }

    @Test func customPatternRendersInTheLocale() {
        let format = JournalDateFormat(rawValue: "MMMM d{ordinal}, yyyy")
        expectEqual(
            format.string(from: june, locale: Locale(identifier: "en_US")),
            "June 10th, 2026")
        expectEqual(
            format.string(from: june, locale: Locale(identifier: "de_DE")),
            "Juni 10., 2026")
    }

    @Test func rejectsUnusableCustomPatterns() {
        expectEqual(JournalDateFormat.problem(withPattern: ""), .empty)
        expectEqual(JournalDateFormat.problem(withPattern: "MMM {ordinal}, yyyy"),
                    .ordinalNotAfterDay)
        expectEqual(JournalDateFormat.problem(withPattern: "d{ordinal}{ordinal}"),
                    .repeatedOrdinal)
        expectEqual(JournalDateFormat.problem(withPattern: "yyyy {unknown}"),
                    .unknownPlaceholder)
        expectEqual(JournalDateFormat.problem(withPattern: "MMM d 'unfinished"),
                    .unbalancedQuote)
        expectNil(JournalDateFormat.problem(withPattern: "yyyy/MM/dd"))
        expectNil(JournalDateFormat.problem(withPattern: "MMM d{ordinal}, yyyy"))
    }

    /// The Apple logo used to be rejected, because `{ordinal}` was implemented by
    /// substituting U+F8FF into the pattern and replacing it afterwards. The
    /// placeholder is now handled by formatting around it, so the character is
    /// just a character.
    @Test func privateUseCharactersSurviveInAPattern() {
        expectNil(JournalDateFormat.problem(withPattern: "d{ordinal} \u{F8FF} yyyy"))
        expectEqual(
            JournalDateFormat(rawValue: "d{ordinal} '\u{F8FF}' yyyy")
                .string(from: june, locale: Locale(identifier: "en_US")),
            "10th \u{F8FF} 2026")
    }

    /// A pattern spelling a style name would decode back as that style, so it
    /// cannot be saved as a pattern.
    @Test func styleNamesAreReservedAgainstCustomPatterns() {
        for style in JournalDateFormat.Style.allCases {
            expectEqual(JournalDateFormat.problem(withPattern: style.rawValue), .reservedName)
        }
    }

    @Test func stylesAndPatternsRoundTripAsOneString() throws {
        for preset in JournalDateFormat.presets {
            let data = try JSONEncoder().encode(preset)
            expectEqual(String(decoding: data, as: UTF8.self), "\"\(preset.rawValue)\"")
            expectEqual(try JSONDecoder().decode(JournalDateFormat.self, from: data), preset)
        }
        expectEqual(JournalDateFormat.default.rawValue, "abbreviated")

        // A stored pattern stays a pattern, and a stored style name a style.
        expectNotNil(JournalDateFormat(rawValue: "d MMM yyyy").customPattern)
        expectEqual(JournalDateFormat(rawValue: "long").style, .long)
    }

    /// The declared default from before formatting existed still loads, as the
    /// pattern it always meant.
    @Test func legacyPatternNormalizesOnDecode() throws {
        let decoded = try JSONDecoder().decode(
            JournalDateFormat.self, from: Data("\"MMM d'th', yyyy\"".utf8))
        expectEqual(decoded.customPattern, "MMM d{ordinal}, yyyy")
        expectEqual(
            decoded.string(from: june, locale: Locale(identifier: "en_US")),
            "Jun 10th, 2026")
    }

    @Test func cachedFormattersAreSafeAcrossTasks() async {
        let format = JournalDateFormat(rawValue: "EEEE, MMMM d{ordinal}, yyyy")
        let day = june
        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<200 {
                group.addTask { format.string(from: day, locale: Locale(identifier: "en_US")) }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        expectEqual(Set(values), ["Wednesday, June 10th, 2026"])
    }
}
