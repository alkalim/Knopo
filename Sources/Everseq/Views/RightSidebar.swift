import SwiftUI
import EverseqCore

/// Right sidebar: a stack of panes opened with Cmd+Click, for side-by-side
/// reference work (SPEC §12). Each pane is a distinct, elevated "document" card
/// (à la Mail's thread view) that can collapse to its header.
struct RightSidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator

    private let cardCorner: CGFloat = 10

    var body: some View {
        paneList
            // Recessed column so the lighter cards read as elevated documents.
            // Crucially, DON'T let the grey bleed up into the top safe area
            // (under the window toolbar) — otherwise the recessed grey and the
            // toolbar merge into one mass running to the window's top border.
            // Respecting the top edge stops the grey at the toolbar's bottom; a
            // separator there makes the boundary crisp.
            .background(Self.columnColor, ignoresSafeAreaEdges: [.horizontal, .bottom])
            .safeAreaInset(edge: .top, spacing: 0) {
                Color(nsColor: .separatorColor)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
    }

    private var paneList: some View {
        // Bulk close actions live in each card's ⋯ menu ("Close Other Panes")
        // and the menu bar ("Close All Right Panes") — no fixed in-pane bar.
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(nav.rightPanes.enumerated()), id: \.offset) { (i, pane) in
                    card(index: i, pane: pane)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private func card(index i: Int, pane: RightPane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(index: i, pane: pane)
            if !pane.collapsed {
                Divider().padding(.horizontal, 12)
                paneContent(pane.target)
            }
        }
        // Clip content to the rounded shape so opaque panes (e.g. All Pages'
        // List background) don't bleed white into the corners. Page panes are
        // transparent, so this is a no-op for them.
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Self.cardColor)
                // A soft, diffuse shadow carries the elevation; the border is
                // just a whisper so it doesn't read as a hard outline.
                .shadow(color: .black.opacity(0.10), radius: 4, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(Self.cardBorder, lineWidth: 1)
        )
    }

    private func header(index i: Int, pane: RightPane) -> some View {
        HStack(spacing: 6) {
            // The disclosure + title is one big hit target (click anywhere on
            // the title row toggles), with separate menu / close buttons.
            Button {
                nav.toggleRightPaneCollapsed(at: i)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(pane.collapsed ? 0 : 90))
                        .animation(.easeInOut(duration: 0.15), value: pane.collapsed)
                    Text(paneTitle(pane.target))
                        .font(.callout.weight(.semibold))
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
        .padding(.vertical, 7)
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
    private func paneContent(_ target: NavTarget) -> some View {
        switch target {
        case .page(let name, let zoom):
            // Page panes size to content (no inner ScrollView), so the whole
            // pane stack scrolls together — no nested/double scrolling.
            PageScreen(pageName: name, zoom: zoom, inPane: true)
        case .journalHome:
            // In a pane, the journal is just today's page — not the full
            // infinite-scroll home — and sizes to content like other pages.
            PageScreen(pageName: JournalDate.today().pageName, inPane: true)
        case .tag(let tag):
            // These bring their own ScrollView, so bound their height here.
            TagViewScreen(tag: tag, inPane: true).frame(height: 420)
        case .allPages:
            AllPagesView(inPane: true).frame(height: 420)
        }
    }

    private func paneTitle(_ target: NavTarget) -> String {
        switch target {
        case .page(let name, _):
            return JournalDate(pageName: name)?.displayName ?? name
        case .tag(let tag): return "#\(tag)"
        case .journalHome: return "Journal"
        case .allPages: return "All Pages"
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
        light: NSColor(white: isMacOS26OrLater ? 0.965 : 0.94, alpha: 1),  // lighter dim grey
        dark: NSColor(white: 0.12, alpha: 1)))    // recessed, the darkest layer

    static let cardColor = Color(nsColor: .dynamic(
        light: .textBackgroundColor,              // white
        dark: NSColor(white: 0.21, alpha: 1)))     // clearly above the column

    static let cardBorder = Color(nsColor: .dynamic(
        light: NSColor.separatorColor.withAlphaComponent(isMacOS26OrLater ? 0.12 : 0.25),
        dark: NSColor(white: 1, alpha: 0.14)))     // a visible rim in the dark
}

extension NSColor {
    /// A two-way appearance-adaptive color.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
