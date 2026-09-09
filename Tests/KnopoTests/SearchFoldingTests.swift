import Foundation
import Testing
@testable import Knopo

/// Page-name search has to fold accents the way block search already does
/// through FTS5's `remove_diacritics 2` (SPEC §17, localization phase 2c).
@Suite struct SearchFoldingTests {

    @Test func accentedPagesMatchAnUnaccentedQuery() {
        #expect(matchTier(query: "cafe", in: "Café") == 0)
        #expect(matchTier(query: "Cafe", in: "café") == 0)
        #expect(matchTier(query: "cafe", in: "Café Notes") == 1)
        #expect(matchTier(query: "notes", in: "Café Notes") == 2)
        #expect(fuzzyMatch(query: "cfe", in: "Café"))
    }

    /// And the other way round: typing the accent still finds the plain page.
    @Test func accentedQueriesMatchUnaccentedPages() {
        #expect(matchTier(query: "café", in: "Cafe") == 0)
        #expect(matchTier(query: "naïve", in: "Naive Ideas") == 1)
        #expect(fuzzyMatch(query: "café", in: "CAFE"))
    }

    @Test func nonMatchesStayNonMatches() {
        #expect(matchTier(query: "zebra", in: "Café") == nil)
        #expect(!fuzzyMatch(query: "xyz", in: "Café"))
    }

    /// The ASCII fast path has to agree with folding, since most names take it.
    @Test func asciiFastPathAgreesWithFolding() {
        for text in ["Projects/Outliner", "ALL CAPS", "mixed Case 123", ""] {
            #expect(searchFolded(text) == text.folding(
                options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
        }
    }

    /// Ranking must not depend on the machine's region.
    @Test func foldingIsLocaleIndependent() {
        #expect(searchFolded("İstanbul") == searchFolded("İSTANBUL"))
        #expect(matchTier(query: "istanbul", in: "Istanbul") == 0)
    }
}
