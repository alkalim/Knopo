import SwiftUI
import KnopoCore

/// Left sidebar: Journal (home), Favourites, Recents, Tags, All Pages (SPEC §12).
///
/// Selecting a page in Favourites does not also highlight it in Recents.
struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    @State private var journalJumpDate = Date()
    @State private var jumpPopoverShown = false

    /// The specific row the user last clicked, so a page living in several
    /// sections highlights only where it was selected.
    @State private var lastClickedRow: RowID?
    @State private var pendingRow: RowID?
    @FocusState private var sidebarFocused: Bool

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
        case favourite(String)
        case favouriteTag(String) // tag
        case recent(String)
        case tag(String)

        init(favourite: Favourite) {
            switch favourite {
            case .page(let name): self = .favourite(name)
            case .tag(let tag): self = .favouriteTag(tag)
            }
        }
    }

    var body: some View {
        // Reading dataVersion ties this view to index changes.
        let _ = app.dataVersion
        List(selection: Binding(get: { selectedRow }, set: selectRow)) {
            Section {
                sidebarRow(.journal) {
                    Label(SectionName.journal, systemImage: "calendar").lineLimit(1)
                }
                .tag(RowID.journal)
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
                sidebarRow(.allPages) {
                    Label(SectionName.allPages, systemImage: "doc.on.doc").lineLimit(1)
                }
                .tag(RowID.allPages)
            }

            let favourites = app.store.config.orderedFavourites(limitPerKind: sectionLimit)
            if !favourites.isEmpty {
                Section("Favourites", isExpanded: $favouritesExpanded) {
                    FavouriteRows(items: favourites) { item in
                        switch item {
                        case .page(let name):
                            pageRow(name, rowID: .favourite(name), icon: "doc.text")
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
                        let rowID = RowID.recent(name)
                        pageRow(name, rowID: rowID, icon: "clock")
                            .tag(rowID)
                    }
                }
            }

            let tags = app.allTags
            if !tags.isEmpty {
                Section("Tags", isExpanded: $tagsExpanded) {
                    ForEach(tags.prefix(sectionLimit), id: \.tag) { entry in
                        sidebarRow(.tag(entry.tag)) {
                            HStack {
                                rowLabel(entry.tag, icon: "number")
                                Spacer(minLength: 4)
                                Text(verbatim: "\(entry.count)")   // a number, not a key
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .layoutPriority(1)
                            }
                        }
                        .tag(RowID.tag(entry.tag))
                        .contextMenu { tagMenuItems(entry.tag) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .listItemTint(.monochrome)
        .focused($sidebarFocused)
        .transaction { transaction in
            if !app.preferences.animationsEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: nav.current) { _, target in
            if let lastClickedRow, Self.normalize(rowTarget(lastClickedRow)) != Self.normalize(target) {
                self.lastClickedRow = nil
            }
        }
        .onDisappear { pendingRow = nil }
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

    private func sidebarRow<Content: View>(
        _ row: RowID, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            sidebarFocused = true
            selectRow(row)
        } label: {
            content()
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { nav.openInRightSidebar(rowTarget(row)) })
        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { nav.openInRightSidebar(rowTarget(row)) })
    }

    private func selectRow(_ row: RowID?) {
        guard let row else { return }
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           !event.modifierFlags.intersection([.command, .shift]).isEmpty {
            nav.openInRightSidebar(rowTarget(row))
            return
        }
        let target = rowTarget(row)
        let origin = nav.current
        lastClickedRow = row
        guard target != origin else {
            pendingRow = nil
            return
        }
        guard pendingRow != row else { return }
        pendingRow = row

        // Let AppKit submit the selection highlight before laying out the destination.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          false, CFIndex.max) { _, _ in
            DispatchQueue.main.async {
                guard pendingRow == row else { return }
                pendingRow = nil
                if nav.current == origin { nav.navigate(to: target) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private var selectedRow: RowID? {
        if let pendingRow { return pendingRow }
        let current = Self.normalize(nav.current)
        let favourites = favouritesExpanded
            ? app.store.config.orderedFavourites(limitPerKind: sectionLimit).map(RowID.init(favourite:)) : []
        let favourite = favourites.first { Self.normalize(rowTarget($0)) == current }
        let alternate: RowID?
        switch current {
        case .journalHome: return .journal
        case .allPages: return .allPages
        case .page(let key, _):
            alternate = recentsExpanded ? recentsDisplay.prefix(sectionLimit)
                .first { PageName.key($0) == key }.map(RowID.recent) : nil
        case .tag(let tag):
            alternate = tagsExpanded ? .tag(tag) : nil
        }
        if let alternate, alternate == lastClickedRow { return alternate }
        return favourite ?? alternate
    }

    private func rowTarget(_ rowID: RowID) -> NavTarget {
        switch rowID {
        case .journal: return .journalHome
        case .allPages: return .allPages
        case .favourite(let name), .recent(let name): return .page(name: name)
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
        sidebarRow(rowID) {
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
        sidebarRow(.favouriteTag(tag)) {
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

struct FavouriteRows<Row: View>: View {
    let items: [Favourite]
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
                .tag(Sidebar.RowID(favourite: item))
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
