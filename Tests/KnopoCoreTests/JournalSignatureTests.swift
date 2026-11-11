import Testing
import Foundation
@testable import KnopoCore

/// `journalDaySignature()` backs the journal home's memoized day list: it must
/// change when the *set* of non-empty journal days changes (add / delete /
/// empty), and stay put when only a day's content changes.
@Suite struct JournalSignatureTests {

    private func journal(_ name: String, _ blocks: [String]) -> PageDocument {
        PageDocument(name: name, blocks: blocks.map { Block(content: $0) },
                     isJournal: true, fileExists: true)
    }

    @Test func signatureTracksDaySet() throws {
        let cache = try CacheDB() // in-memory
        try cache.indexPage(journal("2026-06-10", ["a"]), stamp: nil)
        try cache.indexPage(journal("2026-06-11", ["b", "c"]), stamp: nil)
        let twoDays = try cache.journalDaySignature()

        // Editing within a day (same day set) — signature unchanged.
        try cache.indexPage(journal("2026-06-11", ["b", "c", "d"]), stamp: nil)
        expectEqual(try cache.journalDaySignature(), twoDays)

        // A new non-empty day — signature changes.
        try cache.indexPage(journal("2026-06-12", ["e"]), stamp: nil)
        let threeDays = try cache.journalDaySignature()
        expectTrue(threeDays != twoDays)

        // Deleting a day — signature changes (the removed day drops out).
        try cache.removePage(key: "2026-06-10")
        expectTrue(try cache.journalDaySignature() != threeDays)

        // Emptying a day (0 blocks) — signature changes; only 2026-06-12 remains.
        try cache.indexPage(journal("2026-06-11", []), stamp: nil)
        let oneDay = try cache.journalDaySignature()
        expectTrue(oneDay != twoDays)

        // The regression this fingerprint fixes: swap one day for another in the
        // same window. The *count* of days is unchanged (1), but the set differs,
        // so the signature must still change.
        try cache.indexPage(journal("2026-06-12", []), stamp: nil)    // drop the one day
        try cache.indexPage(journal("2026-07-01", ["x"]), stamp: nil) // add a different one
        expectTrue(try cache.journalDaySignature() != oneDay)
    }

    /// The real way a day goes empty: you delete its text, which leaves the file
    /// holding one blank bullet rather than no blocks at all. Counting blocks
    /// instead of content kept such a day in the feed for good — showing the
    /// empty-page hint on it, since its one row is blank (SPEC §10, §5.4).
    @Test func aDayEmptiedToOneBlankBlockDropsOutOfTheFeed() throws {
        let cache = try CacheDB()
        try cache.indexPage(journal("2026-06-10", ["morning notes"]), stamp: nil)
        try cache.indexPage(journal("2026-06-11", ["other notes"]), stamp: nil)
        expectEqual(try cache.journalDaysWithContent(), ["2026-06-11", "2026-06-10"])
        let both = try cache.journalDaySignature()

        // Delete the day's text, exactly as the editor leaves it.
        try cache.indexPage(journal("2026-06-10", [""]), stamp: nil)

        expectEqual(try cache.journalDaysWithContent(), ["2026-06-11"])
        // …and the fingerprint changed, so the memoized feed rebuilds rather than
        // keeping the day around until the next launch.
        expectTrue(try cache.journalDaySignature() != both)
    }

    /// Whitespace is not content either — a bullet holding a space, tab or newline.
    @Test func blankVariantsAllCountAsEmpty() throws {
        let cache = try CacheDB()
        try cache.indexPage(journal("2026-06-10", ["   ", "\n", "\t"]), stamp: nil)
        expectTrue(try cache.journalDaysWithContent().isEmpty)

        try cache.indexPage(journal("2026-06-10", ["   ", "real"]), stamp: nil)
        expectEqual(try cache.journalDaysWithContent(), ["2026-06-10"])
    }

    @Test func pagePropertiesKeepJournalInFeed() throws {
        let cache = try CacheDB()
        var day = journal("2026-06-10", [""])
        try cache.indexPage(day, stamp: nil)
        let empty = try cache.journalDaySignature()
        day.preamble = "mood:: good\n"
        try cache.indexPage(day, stamp: nil)
        expectEqual(try cache.journalDaysWithContent(), [day.name])
        let withProperties = try cache.journalDaySignature()
        expectTrue(withProperties != empty)
        day.preamble = "mood:: great\n"
        try cache.indexPage(day, stamp: nil)
        expectEqual(try cache.journalDaySignature(), withProperties)
        day.preamble = ""
        try cache.indexPage(day, stamp: nil)
        expectTrue(try cache.journalDaysWithContent().isEmpty)
        expectEqual(try cache.journalDaySignature(), empty)
    }
}
