import SwiftUI
import KnopoCore

/// Left sidebar: Journal (home), Favourites, Recents, Tags, All Pages (SPEC §12).
///
/// Selection uses a grey rounded pill with a normal label, tracked per row.
/// Selecting a page in Favourites does not also highlight it in Recents.
struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    @State private var journalJumpDate = Date()
    @State private var jumpPopoverShown = false

    /// The specific row the user last clicked, so a page living in several
    /// sections highlights only where it was selected.
    @State private var lastClickedRow: RowID?

    /// Recents as displayed: stable order while clicking around (no
    /// jump-to-top mid-session); new pages enter at the top, gone ones drop.
    @State private var recentsDisplay: [String] = []

    @AppStorage("sidebar.favouritesExpanded") private var favouritesExpanded = true
    @AppStorage("sidebar.recentsExpanded") private var recentsExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true

    /// Per-section display cap. Hardcoded for now; a Settings knob later.
    private let sectionLimit = 15

    enum RowID: Hashable {
        case journal
        case allPages
        case favourite(String)    // page key
        case favouriteTag(String) // tag
        case recent(String)       // page key
        case tag(String)

        init(favourite: Favourite) {
            switch favourite {
            case .page(let name): self = .favourite(PageName.key(name))
            case .tag(let tag): self = .favouriteTag(tag)
            }
        }
    }

    var body: some View {
        // Reading dataVersion ties this view to index changes.
        let _ = app.dataVersion
        List {
            Section {
                sidebarRow(.journal, target: .journalHome) {
                    Label(SectionName.journal, systemImage: "calendar").lineLimit(1)
                }
                .listRowBackground(selectionBackground(for: .journal))
                .contextMenu {
                    Button("Jump to Day…") {
                        journalJumpDate = Date()
                        jumpPopoverShown = true
                    }
                }
                .popover(isPresented: $jumpPopoverShown, arrowEdge: .trailing) {
                    DatePicker(
                        "Jump to day", selection: $journalJumpDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(10)
                    .onChange(of: journalJumpDate) { _, newValue in
                        jumpPopoverShown = false
                        nav.navigate(to: .page(name: JournalDate(date: newValue).pageName))
                    }
                }
                sidebarRow(.allPages, target: .allPages) {
                    Label(SectionName.allPages, systemImage: "doc.on.doc").lineLimit(1)
                }
                .listRowBackground(selectionBackground(for: .allPages))
            }

            let favourites = app.store.config.orderedFavourites(limitPerKind: sectionLimit)
            if !favourites.isEmpty {
                Section("Favourites", isExpanded: $favouritesExpanded) {
                    FavouriteRows(items: favourites, selection: { item in
                        selectionBackground(for: RowID(favourite: item))
                    }) { item in
                        switch item {
                        case .page(let name):
                            pageRow(name, rowID: RowID(favourite: item), icon: "doc.text")
                        case .tag(let tag):
                            favouriteTagRow(tag)
                        }
                    } move: { from, to in
                        guard favourites == app.store.config.orderedFavourites(limitPerKind: sectionLimit) else { return }
                        do {
                            try app.moveFavourites(favourites, from: from, to: to)
                        } catch {
                            NSAlert(for: error).runModal()
                        }
                    }
                }
            }

            if !recentsDisplay.isEmpty {
                Section("Recents", isExpanded: $recentsExpanded) {
                    ForEach(recentsDisplay.prefix(sectionLimit), id: \.self) { name in
                        let rowID = RowID.recent(PageName.key(name))
                        pageRow(name, rowID: rowID, icon: "clock")
                            .listRowBackground(selectionBackground(for: rowID))
                    }
                }
            }

            let tags = app.allTags
            if !tags.isEmpty {
                Section("Tags", isExpanded: $tagsExpanded) {
                    ForEach(tags.prefix(sectionLimit), id: \.tag) { entry in
                        sidebarRow(.tag(entry.tag), target: .tag(entry.tag)) {
                            HStack {
                                rowLabel(entry.tag, icon: "number")
                                Spacer(minLength: 4)
                                Text(verbatim: "\(entry.count)")   // a number, not a key
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .layoutPriority(1)
                            }
                        }
                        .listRowBackground(selectionBackground(for: .tag(entry.tag)))
                        .contextMenu { tagMenuItems(entry.tag) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .transaction { transaction in
            if !app.preferences.animationsEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { mergeRecents() }
        .onChange(of: app.dataVersion) { _, _ in mergeRecents() }
    }

    // MARK: - Recents stability

    /// Merges the store's recency list into the displayed one without
    /// reordering rows the user can see: existing entries keep their position,
    /// new entries push in at the top, evicted ones disappear. The true
    /// most-recent-first order reasserts itself on next launch.
    private func mergeRecents() {
        let fresh = app.recents
        let freshKeys = Set(fresh.map(PageName.key))
        var merged = recentsDisplay.filter { freshKeys.contains(PageName.key($0)) }
        let displayedKeys = Set(merged.map(PageName.key))
        let newcomers = fresh.filter { !displayedKeys.contains(PageName.key($0)) }
        merged.insert(contentsOf: newcomers, at: 0)
        if merged != recentsDisplay { recentsDisplay = merged }
    }

    // MARK: - Rows and selection

    /// How far AppKit insets a source-list row's selection from the row width.
    /// It draws the right-click outline there too. `SidebarSelectionInsetTests`
    /// measures it, so a system that changes it fails that test.
    static let selectionInset: CGFloat = 10

    @ViewBuilder
    private func sidebarRow<Content: View>(
        _ rowID: RowID, target: NavTarget, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            if wantsSidebarClick() {
                nav.openInRightSidebar(target)
            } else {
                lastClickedRow = rowID
                nav.navigate(to: target)
            }
        } label: {
            content()
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 7)
                // Standard macOS sidebar row height (Photos/Music): 28 pt,
                // pill filling the full row.
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Apply this to the finished list row so the pill lines up with AppKit’s context-menu outline.
    private func selectionBackground(for rowID: RowID) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected(rowID)
                ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                : Color.clear)
            .padding(.horizontal, Self.selectionInset)
    }

    /// A row highlights when it points at the current location — but if the
    /// page appears in several sections, only the row the user actually
    /// clicked (or Favourites first, for external navigation) lights up.
    private func isSelected(_ rowID: RowID) -> Bool {
        let current = Self.normalize(nav.current)
        guard Self.normalize(rowTarget(rowID)) == current else { return false }
        if let lastClickedRow,
           Self.normalize(rowTarget(lastClickedRow)) == current {
            return rowID == lastClickedRow
        }
        // Navigation didn't come from the sidebar: prefer Favourites.
        guard favouritesExpanded else { return true }
        let config = app.store.config
        switch rowID {
        case .recent(let key):
            return !config.favourites.prefix(sectionLimit).contains { PageName.key($0) == key }
        case .tag(let tag):
            return !config.favouriteTags.prefix(sectionLimit).contains(tag.lowercased())
        default:
            return true
        }
    }

    private func rowTarget(_ rowID: RowID) -> NavTarget {
        switch rowID {
        case .journal: return .journalHome
        case .allPages: return .allPages
        case .favourite(let key), .recent(let key): return .page(name: key)
        case .tag(let tag), .favouriteTag(let tag): return .tag(tag)
        }
    }

    /// Selection compares location only: zoom is page-internal, names are
    /// case-insensitive (SPEC §3.2).
    private static func normalize(_ target: NavTarget) -> NavTarget {
        switch target {
        case .page(let name, _): return .page(name: PageName.key(name))
        case .tag(let tag): return .tag(tag.lowercased())
        case .journalHome: return .journalHome
        case .allPages: return .allPages
        }
    }

    /// Shared row content: an icon column identical across every section
    /// (caption-sized, secondary) so icons line up, plus the title.
    private func rowLabel(_ text: String, icon: String) -> some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pageRow(
        _ name: String, rowID: RowID, icon: String
    ) -> some View {
        sidebarRow(rowID, target: .page(name: name)) {
            rowLabel(displayName(for: name), icon: icon)
        }
        .contextMenu {
            Button(app.store.config.isFavourite(name) ? "Unfavourite" : "Favourite") {
                app.toggleFavourite(name)
            }
            Button("Open in Sidebar") { nav.openInRightSidebar(.page(name: name)) }
            OpenInNewWindow(target: .page(name: name))
        }
    }

    /// A favourited tag row — same target as a Tags-section row, hash-iconed
    /// to read as a tag among the doc-iconed page favourites.
    private func favouriteTagRow(_ tag: String) -> some View {
        sidebarRow(.favouriteTag(tag), target: .tag(tag)) {
            rowLabel(tag, icon: "number")
        }
        .contextMenu { tagMenuItems(tag) }
    }

    @ViewBuilder
    private func tagMenuItems(_ tag: String) -> some View {
        Button(app.store.config.isFavouriteTag(tag)
            ? "Remove from Favourites" : "Add to Favourites") {
            app.toggleFavouriteTag(tag)
        }
        Button("Open in Sidebar") { nav.openInRightSidebar(.tag(tag)) }
        OpenInNewWindow(target: .tag(tag))
    }

    private func displayName(for name: String) -> String {
        app.displayTitle(for: name)
    }
}

struct FavouriteRows<Row: View, Selection: View>: View {
    let items: [Favourite]
    let selection: (Favourite) -> Selection
    @ViewBuilder let row: (Favourite) -> Row
    let move: (IndexSet, Int) -> Void

    // Scrolling updates row positions. Only the drag needs to redraw the insertion line.
    private final class RowFrames {
        var byItem: [Favourite: CGRect] = [:]
    }

    @State private var frames = RowFrames()
    @GestureState private var drag: FavouriteDrag?

    var body: some View {
        let insertion = drag?.destination(in: items, frames: frames.byItem)
        ForEach(items, id: \.self) { item in
            row(item)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frames.byItem[item] = $0
                }
                .onDisappear { frames.byItem.removeValue(forKey: item) }
                .overlay(alignment: insertion == items.count ? .bottom : .top) {
                    if let insertion, (insertion == items.count ? items.last : items[insertion]) == item {
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($drag) { value, state, _ in
                            state = FavouriteDrag(source: item, location: value.location)
                        }
                        .onEnded { value in
                            let drag = FavouriteDrag(source: item, location: value.location)
                            guard let to = drag.destination(in: items, frames: frames.byItem),
                                  let from = items.firstIndex(of: item) else { return }
                            move(IndexSet(integer: from), to)
                        }
                )
                // Drag modifiers can hide a background set on the inner button.
                .listRowBackground(selection(item))
        }
        .onMove(perform: move)
    }
}

struct FavouriteDrag {
    let source: Favourite
    let location: CGPoint

    func destination(in items: [Favourite], frames: [Favourite: CGRect]) -> Int? {
        let rows = items.indices.compactMap { index in
            frames[items[index]].map { (index: index, frame: $0) }
        }
        guard let first = rows.first, let last = rows.last,
              first.frame.union(last.frame).contains(location),
              let from = items.firstIndex(of: source) else { return nil }
        let to = rows.first { location.y < $0.frame.midY }?.index ?? last.index + 1
        return to == from || to == from + 1 ? nil : to
    }
}
