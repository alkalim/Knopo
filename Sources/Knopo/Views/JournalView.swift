import SwiftUI
import KnopoCore

/// Journal home: today first (even when empty), then previous non-empty days,
/// scrolling backwards (SPEC §10).
struct JournalView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let _ = app.dataVersion
        JournalScrollView(days: app.journalDays())
            .ignoresSafeArea(edges: .top)
    }
}

/// One day in the feed, with the rule that introduces the next.
struct JournalDay: View {
    let day: String
    let outlineWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JournalDaySection(day: day, outlineWidth: outlineWidth)
            // More room above the separator than below it.
            Divider().padding(.top, 36).padding(.bottom, 16)
        }
    }
}

struct JournalDaySection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let day: String
    let outlineWidth: CGFloat

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
            OutlineEditorView(pageName: day, initialWidth: outlineWidth, inJournalFeed: true)
        }
    }
}
