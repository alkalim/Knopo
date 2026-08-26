import Foundation
import Testing
@testable import KnopoCore

@Suite struct JournalDateFormatTests {
    private let sample = JournalDate(year: 2026, month: 6, day: 10)!

    @Test func presetsProduceTheirDisplayedExamples() {
        expectEqual(
            JournalDateFormat.presets.map { $0.string(from: sample) },
            ["Jun 10th, 2026", "June 10, 2026", "10 Jun 2026",
             "10 June 2026", "2026-06-10"])
    }

    @Test func ordinalSuffixHandlesEnglishExceptions() {
        let expected = [
            1: "1st", 2: "2nd", 3: "3rd", 4: "4th",
            11: "11th", 12: "12th", 13: "13th",
            21: "21st", 22: "22nd", 23: "23rd",
        ]
        let format = JournalDateFormat(pattern: "d{ordinal}")
        for (day, text) in expected {
            expectEqual(
                format.string(from: JournalDate(year: 2026, month: 1, day: day)!),
                text)
        }
    }

    @Test func customUnicodePatternAndOrdinal() {
        let format = JournalDateFormat(pattern: "EEEE, MMMM d{ordinal}, yyyy")
        expectEqual(format.string(from: sample), "Wednesday, June 10th, 2026")
    }

    @Test func validatesCustomPatterns() {
        expectNil(JournalDateFormat(validating: ""))
        expectNil(JournalDateFormat(validating: "MMM {ordinal}, yyyy"))
        expectNil(JournalDateFormat(validating: "d{ordinal}{ordinal}"))
        expectNil(JournalDateFormat(validating: "yyyy {unknown}"))
        expectNil(JournalDateFormat(validating: "MMM d 'unfinished"))
        expectNotNil(JournalDateFormat(validating: "yyyy/MM/dd"))
        expectNotNil(JournalDateFormat(validating: "MMM d{ordinal}, yyyy"))
    }

    @Test func legacyPatternNormalizesAndCodableStaysAString() throws {
        let decoded = try JSONDecoder().decode(
            JournalDateFormat.self, from: Data("\"MMM d'th', yyyy\"".utf8))
        expectEqual(decoded, .default)
        expectEqual(decoded.string(from: sample), "Jun 10th, 2026")
        expectEqual(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self),
                    "\"MMM d{ordinal}, yyyy\"")
    }
}
