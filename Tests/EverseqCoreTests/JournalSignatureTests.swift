import Testing
import Foundation
@testable import EverseqCore

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
        expectEqual(try cache.journalDaySignature(), 2)

        // Editing within a day (same day set) — signature unchanged.
        try cache.indexPage(journal("2026-06-11", ["b", "c", "d"]), stamp: nil)
        expectEqual(try cache.journalDaySignature(), 2)

        // A new non-empty day — signature changes.
        try cache.indexPage(journal("2026-06-12", ["e"]), stamp: nil)
        expectEqual(try cache.journalDaySignature(), 3)

        // Deleting a day — signature changes (the removed day drops out).
        try cache.removePage(key: "2026-06-10")
        expectEqual(try cache.journalDaySignature(), 2)

        // Emptying a day (0 blocks) — signature changes.
        try cache.indexPage(journal("2026-06-11", []), stamp: nil)
        expectEqual(try cache.journalDaySignature(), 1)
    }
}
