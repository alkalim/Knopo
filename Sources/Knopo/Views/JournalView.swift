import SwiftUI
import KnopoCore

/// Journal home: today first (even when empty), then previous non-empty days,
/// scrolling backwards (SPEC §10).
struct JournalView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let _ = app.dataVersion
        // `journalDays()` is memoized in AppState: the day list is reused across
        // edits and only rebuilt when the set of days changes, so typing in a
        // day doesn't re-scan every journal page. `LazyVStack` keeps rendering to
        // the visible days, so a long history stays cheap on both axes.
        let days = app.journalDays()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Today is built even when scrolled off: `⌘J` puts the caret in
                // its writing block from anywhere in the feed (§10), and only an
                // outline that exists can take that request.
                if let today = days.first { JournalDay(day: today) }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days.dropFirst(), id: \.self) { day in
                        JournalDay(day: day)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// One day in the feed, with the rule that introduces the next.
private struct JournalDay: View {
    let day: String

    var body: some View {
        JournalDaySection(day: day)
        // More room above the separator (between the day's last block and the
        // rule) than below it, so the rule reads as introducing the next day
        // rather than crowding this one.
        Divider().padding(.top, 36).padding(.bottom, 16)
    }
}

struct JournalDaySection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let day: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    nav.navigate(to: .page(name: day))
                } label: {
                    Text(app.displayTitle(for: day))
                        .font(.system(size: BlockRenderer.pageTitleFontSize, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Open day page (shows linked references)")
                if day == JournalDate.today().pageName {
                    Text("Today")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
            }
            OutlineEditorView(pageName: day, inJournalFeed: true)
        }
    }
}
