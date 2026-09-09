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
            #expect(JournalDateFormatControl.customDraft(
                from: JournalDateFormat(style: style), remembered: "")
                == JournalDateFormatControl.customSeed)
        }
    }

    @Test func anExistingPatternIsKeptRatherThanSeeded() {
        #expect(JournalDateFormatControl.customDraft(
            from: JournalDateFormat(rawValue: "d MMM yyyy"), remembered: "yyyy/MM/dd")
            == "d MMM yyyy")
    }

    /// Switching to a built-in style and back has to bring the user's own
    /// pattern back, not the seed.
    @Test func aRememberedPatternSurvivesATripThroughTheStyles() {
        #expect(JournalDateFormatControl.customDraft(
            from: JournalDateFormat(style: .iso), remembered: "EEEE, d MMM yyyy")
            == "EEEE, d MMM yyyy")
    }

    /// A remembered value that no longer validates must not be handed back.
    @Test func anUnusableRememberedPatternFallsBackToTheSeed() {
        for junk in ["", "yyyy {unknown}", "long", "MMM d 'unfinished"] {
            #expect(JournalDateFormatControl.customDraft(
                from: JournalDateFormat(style: .numeric), remembered: junk)
                == JournalDateFormatControl.customSeed)
        }
    }

    // MARK: - Picker transitions

    private typealias Control = JournalDateFormatControl

    /// The case every upgrading user hits: a custom pattern in preferences, and
    /// `remembered` still empty because the key is new. Leaving Custom has to
    /// keep the pattern, or the first trip through a style discards it.
    @Test func leavingCustomKeepsTheOutgoingPattern() {
        let step = Control.step(
            selecting: "iso", draft: "EEEE, d MMM yyyy",
            remembered: "", format: JournalDateFormat(rawValue: "EEEE, d MMM yyyy"))
        #expect(step.apply == JournalDateFormat(style: .iso))
        #expect(step.remember == "EEEE, d MMM yyyy")

        // …and coming back restores it rather than the seed.
        let back = Control.step(
            selecting: "__custom__", draft: "EEEE, d MMM yyyy",
            remembered: "EEEE, d MMM yyyy", format: JournalDateFormat(style: .iso))
        #expect(back.draft == "EEEE, d MMM yyyy")
        #expect(back.apply == JournalDateFormat(rawValue: "EEEE, d MMM yyyy"))
    }

    /// An edit still inside the 400 ms commit debounce is not lost by switching.
    @Test func leavingCustomKeepsAnUncommittedEdit() {
        let step = Control.step(
            selecting: "numeric", draft: "yyyy/MM/dd",
            remembered: "MMM d{ordinal}, yyyy",
            format: JournalDateFormat(rawValue: "MMM d{ordinal}, yyyy"))
        #expect(step.remember == "yyyy/MM/dd")
        #expect(step.apply == JournalDateFormat(style: .numeric))
    }

    /// A half-typed pattern is not worth keeping, and must not be applied.
    @Test func leavingCustomDiscardsAnUnusableDraft() {
        let step = Control.step(
            selecting: "long", draft: "MMM d 'unfinished",
            remembered: "d MMM yyyy", format: JournalDateFormat(rawValue: "d MMM yyyy"))
        #expect(step.remember == nil)
        #expect(step.apply == JournalDateFormat(style: .long))
    }

    /// Entering Custom applies what it shows - the bug fixed in 9e1cea6.
    @Test func enteringCustomAppliesWhatItShows() {
        let step = Control.step(
            selecting: "__custom__", draft: "iso",
            remembered: "", format: JournalDateFormat(style: .iso))
        #expect(step.draft == Control.customSeed)
        #expect(step.apply == JournalDateFormat(rawValue: Control.customSeed))
        #expect(step.remember == Control.customSeed)
    }

    @Test func selectingAStyleAppliesIt() {
        for style in JournalDateFormat.Style.allCases {
            let step = Control.step(
                selecting: style.rawValue, draft: "d MMM yyyy",
                remembered: "d MMM yyyy", format: JournalDateFormat(style: .abbreviated))
            #expect(step.apply == JournalDateFormat(style: style))
        }
    }
}
