import SwiftUI
import EverseqCore

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
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.self) { day in
                    JournalDaySection(day: day)
                    Divider().padding(.vertical, 16)
                }
            }
            .padding(20)
        }
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
                    Text(JournalDate(pageName: day)?.displayName ?? day)
                        .font(.system(size: 20 * BlockRenderer.zoom, weight: .bold))
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
            OutlineEditorView(pageName: day)
        }
    }
}
