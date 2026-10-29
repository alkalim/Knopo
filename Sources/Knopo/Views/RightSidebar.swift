import SwiftUI
import KnopoCore

/// Right sidebar: a stack of panes opened with Cmd+Click, for side-by-side
/// reference work (SPEC §12). Each pane is a distinct, elevated "document" card
/// (à la Mail's thread view) that can collapse to its header.
struct RightSidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator

    private let cardCorner: CGFloat = 10
    private static let cardInset: CGFloat = 10
    private enum ScrollAnchor: Hashable { case top }
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        columnSurface
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
    }

    /// Recessed column so the lighter cards read as elevated documents.
    /// The grey stops at the toolbar's bottom edge. Under the toolbar it would
    /// show through the tab bar on 26 and merge with the toolbar on 15.
    @ViewBuilder
    private var columnSurface: some View {
        let column = paneList
            .background(Self.columnColor, ignoresSafeAreaEdges: [.horizontal, .bottom])
        if #available(macOS 26.0, *) {
            // The system toolbar background draws the line. Without an explicit
            // style, cards scrolled under the toolbar here stay sharp.
            column.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            column
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color(nsColor: .separatorColor)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
        }
    }

    private var paneList: some View {
        // Bulk close actions live in each card's ⋯ menu ("Close Other Panes")
        // and the menu bar ("Close All Right Panes") — no fixed in-pane bar.
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(nav.rightPanes.enumerated()), id: \.element.target) { (i, pane) in
                            // A rename or zoom changes the target and recreates the card.
                            // Moving another card preserves this card's editor.
                            card(index: i, pane: pane, outlineWidth: Self.outlineWidth(
                                in: viewport.size, scrollerStyle: scrollerStyle))
                                .id(pane.target)
                        }
                    }
                    .padding(.horizontal, Self.cardInset)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .id(ScrollAnchor.top)
                }
                .onChange(of: nav.rightPaneRevealToken) {
                    proxy.scrollTo(ScrollAnchor.top, anchor: .top)
                }
            }
        }
    }

    static func outlineWidth(in viewport: CGSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        // Reserve the legacy gutter for initial layout of long panes.
        // Attached outlines use their actual width if the scroller is hidden.
        let content = NSScrollView.contentSize(forFrameSize: viewport,
            horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: .noBorder, controlSize: .regular, scrollerStyle: scrollerStyle)
        return max(100, content.width - 2 * (cardInset + PageScreen.contentInset))
    }

    private func card(index i: Int, pane: RightPane, outlineWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(index: i, pane: pane)
            VStack(spacing: 0) {
                if !pane.collapsed {
                    VStack(spacing: 0) {
                        Divider().padding(.horizontal, 12)
                        paneContent(pane.target, outlineWidth: outlineWidth)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Keep the moving body below the header.
            // Clipping alone would still let it intercept header clicks.
            .clipped()
            .contentShape(Rectangle())
        }
        // Clip content to the rounded shape so opaque panes (e.g. All Pages'
        // List background) don't bleed white into the corners. Page panes are
        // transparent, so this is a no-op for them.
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Self.cardColor)
                // Use a lighter, broader shadow on 26 to soften the card edge.
                .shadow(color: .black.opacity(Self.isMacOS26OrLater ? 0.06 : 0.10),
                        radius: Self.isMacOS26OrLater ? 6 : 4,
                        y: Self.isMacOS26OrLater ? 1 : 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(Self.cardBorder, lineWidth: Self.isMacOS26OrLater ? 0.5 : 1)
        )
    }

    private func header(index i: Int, pane: RightPane) -> some View {
        HStack(spacing: 6) {
            // The disclosure + title is one big hit target (click anywhere on
            // the title row toggles), with separate menu / close buttons.
            Button {
                withAnimation(app.preferences.animationsEnabled ? .easeOut(duration: 0.16) : nil) {
                    nav.toggleRightPaneCollapsed(at: i)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(pane.collapsed ? 0 : 90))
                    Text(paneTitle(pane.target))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            cardMenu(index: i, for: pane.target)

            Button {
                nav.closeRightPane(at: i)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The card-header actions menu — the single menu for every pane type, so a
    /// tag pane and a page pane look identical (the content's own header is
    /// suppressed in-pane). The glyph is a plain `ellipsis` (not a filled
    /// circle): `Menu` ignores `.foregroundStyle` on its label, so a filled
    /// symbol rendered solid black — plain dots stay light and native.
    @ViewBuilder
    private func cardMenu(index i: Int, for target: NavTarget) -> some View {
        // All Pages has no type-specific actions, so only show its menu when
        // there are other panes to close.
        let hasTypeActions: Bool = { if case .allPages = target { return false }; return true }()
        if hasTypeActions || nav.rightPanes.count > 1 {
            menuButton {
                switch target {
                case .page(let name, _): pageMenuItems(name)
                case .journalHome: pageMenuItems(JournalDate.today().pageName)
                case .tag(let tag): tagMenuItems(tag)
                case .allPages: EmptyView()
                }
                if nav.rightPanes.count > 1 {
                    if hasTypeActions { Divider() }
                    Button("Close Other Panes") { nav.closeOtherRightPanes(at: i) }
                }
            }
        }
    }

    private func menuButton<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        ActionsMenu(content: items)
    }

    @ViewBuilder
    private func pageMenuItems(_ name: String) -> some View {
        Button(app.store.config.isFavourite(name)
            ? "Remove from Favourites" : "Add to Favourites") {
            app.toggleFavourite(name)
        }
        Button("Open in Main View") { nav.navigate(to: .page(name: name)) }
        Button("Reveal in Finder") { PageActions.revealInFinder(name, app: app) }
            .disabled(PageActions.file(of: name, app: app) == nil)
        Divider()
        Button("Rename Page…") { PageActions.promptRename(name, nav: nav) }
            .disabled(app.document(for: name).isJournal)
        Button("Delete Page…", role: .destructive) {
            PageActions.confirmDelete(name, app: app, nav: nav)
        }
    }

    @ViewBuilder
    private func tagMenuItems(_ tag: String) -> some View {
        Button(app.store.config.isFavouriteTag(tag)
            ? "Remove from Favourites" : "Add to Favourites") {
            app.toggleFavouriteTag(tag)
        }
        Button("Open in Main View") { nav.navigate(to: .tag(tag)) }
        Divider()
        Button("Rename Tag…") { PageActions.promptRenameTag(tag, app: app, nav: nav) }
    }

    @ViewBuilder
    private func paneContent(_ target: NavTarget, outlineWidth: CGFloat) -> some View {
        switch target {
        case .page(let name, let zoom):
            // Page panes size to content (no inner ScrollView), so the whole
            // pane stack scrolls together — no nested/double scrolling.
            PageScreen(pageName: name, zoom: zoom, inPane: true, initialOutlineWidth: outlineWidth)
        case .journalHome:
            // The navigator opens the journal home as today's page, so a pane
            // never holds this target. Show today's page if one does.
            PageScreen(pageName: JournalDate.today().pageName, inPane: true, initialOutlineWidth: outlineWidth)
        case .tag(let tag):
            TagViewScreen(tag: tag, inPane: true)
        case .allPages:
            // All Pages has its own scroll view, so bound its height here.
            AllPagesView(inPane: true).frame(height: 420)
        }
    }

    private func paneTitle(_ target: NavTarget) -> String {
        switch target {
        case .page(let name, _):
            return app.displayTitle(for: name)
        case .tag(let tag): return "#\(tag)"
        case .journalHome: return SectionName.journal
        case .allPages: return SectionName.allPages
        }
    }

    // MARK: - Appearance-adaptive surfaces
    //
    // Cards must read as *elevated* (lighter than the recessed column) in BOTH
    // light and dark modes. Semantic colors don't guarantee that ordering in
    // dark mode (`textBackgroundColor` is darker than `windowBackgroundColor`),
    // so we pin explicit greys per appearance.

    // macOS 26's chrome is lighter and flatter than Sequoia's, so the recessed
    // column and card outline that read correctly on 15 look too heavy there.
    // Lighten both on 26 only; leave the 15 values (which suit its chrome) be.
    static let isMacOS26OrLater: Bool = {
        if #available(macOS 26, *) { return true }
        return false
    }()

    static let columnColor = Color(nsColor: .dynamic(
        // On 26, pull the recessed column toward its extreme (near-white in
        // light, near-black in dark) so it reads as a clean backdrop rather
        // than a grey slab; 15 keeps its heavier grey to suit that chrome.
        light: NSColor(white: isMacOS26OrLater ? 0.98 : 0.94, alpha: 1),
        dark: NSColor(white: isMacOS26OrLater ? 0.10 : 0.12, alpha: 1)))

    static let cardColor = Color(nsColor: .dynamic(
        light: .textBackgroundColor,              // white
        dark: NSColor(white: 0.21, alpha: 1)))     // clearly above the column

    static let cardBorder = Color(nsColor: .dynamic(
        // Keep a faint edge on 26; retain the stronger outline on 15.
        light: NSColor.separatorColor.withAlphaComponent(isMacOS26OrLater ? 0.05 : 0.25),
        dark: NSColor(white: 1, alpha: isMacOS26OrLater ? 0.05 : 0.14)))
}

extension NSColor {
    /// A two-way appearance-adaptive color.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
