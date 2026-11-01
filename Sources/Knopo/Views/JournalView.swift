import SwiftUI
import KnopoCore

/// Journal home: today first (even when empty), then previous non-empty days,
/// scrolling backwards (SPEC §10).
struct JournalView: View {
    @EnvironmentObject var app: AppState
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    private static let contentInset: CGFloat = 20

    var body: some View {
        let _ = app.dataVersion
        // `journalDays()` is memoized in AppState: the day list is reused across
        // edits and only rebuilt when the set of days changes, so typing in a
        // day doesn't re-scan every journal page. `LazyVStack` keeps rendering to
        // the visible days, so a long history stays cheap on both axes.
        let days = app.journalDays()
        GeometryReader { viewport in
            let width = Self.outlineWidth(in: viewport.size, scrollerStyle: scrollerStyle)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Today is built even when scrolled off: `⌘J` puts the caret in
                    // its writing block from anywhere in the feed (§10), and only an
                    // outline that exists can take that request.
                    if let today = days.first { JournalDay(day: today, outlineWidth: width) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days.dropFirst(), id: \.self) { day in
                            JournalDay(day: day, outlineWidth: width)
                        }
                    }
                }
                .padding(Self.contentInset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }

    static func outlineWidth(in viewport: CGSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        // Measure days at the feed width before the lazy stack places them.
        // A narrow initial measurement makes them shrink and shifts the scroll.
        let content = NSScrollView.contentSize(forFrameSize: viewport,
            horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: .noBorder, controlSize: .regular, scrollerStyle: scrollerStyle)
        return max(100, content.width - 2 * contentInset)
    }
}

/// One day in the feed, with the rule that introduces the next.
private struct JournalDay: View {
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
