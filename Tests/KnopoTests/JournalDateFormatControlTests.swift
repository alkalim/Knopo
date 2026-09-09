import Foundation
import Testing
@testable import Knopo
import KnopoCore

/// Selecting "Custom…" used to only *show* a pattern, leaving the previous
/// built-in style in effect until the text field lost focus - so switching from
/// ISO 8601 to Custom kept rendering ISO titles. It now applies the draft, which
/// only works if the draft is always valid.
@MainActor
@Suite struct JournalDateFormatControlTests {

    @Test func theCustomSeedIsAValidPattern() {
        #expect(JournalDateFormat.problem(
            withPattern: JournalDateFormatControl.customSeed) == nil)
    }

    @Test func switchingFromABuiltInStyleSeedsTheField() {
        for style in JournalDateFormat.Style.allCases {
            #expect(JournalDateFormatControl.customDraft(from: JournalDateFormat(style: style))
                == JournalDateFormatControl.customSeed)
        }
    }

    @Test func anExistingPatternIsKeptRatherThanSeeded() {
        #expect(JournalDateFormatControl.customDraft(
            from: JournalDateFormat(rawValue: "d MMM yyyy")) == "d MMM yyyy")
    }
}
