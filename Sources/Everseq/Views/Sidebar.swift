import SwiftUI
import EverseqCore

/// Left sidebar: Journal (home), Favourites, Recents, Tags, All Pages (SPEC §12).
///
/// Selection is drawn as the unemphasized rounded pill first-party sidebars
/// use (grey background, accent label) and is tracked per row — selecting a
/// page in Favourites does not also highlight it in Recents.
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
    }

    var body: some View {
        // Reading dataVersion ties this view to index changes.
        let _ = app.dataVersion
        List {
            Section {
                sidebarRow(.journal, target: .journalHome) {
                    Label("Journal", systemImage: "calendar").lineLimit(1)
                }
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
                    Label("All Pages", systemImage: "doc.on.doc").lineLimit(1)
                }
            }

            if !app.favourites.isEmpty || !app.favouriteTags.isEmpty {
                Section("Favourites", isExpanded: $favouritesExpanded) {
                    // Pages use a doc icon, tags a hash, so type reads at a
                    // glance without a star (the section says "favourite").
                    ForEach(app.favourites.prefix(sectionLimit), id: \.self) { name in
                        pageRow(name, rowID: .favourite(PageName.key(name)),
                                icon: "doc.text")
                    }
                    .onMove { from, to in
                        try? app.store.updateConfig {
                            $0.favourites.move(fromOffsets: from, toOffset: to)
                        }
                        app.dataVersion += 1
                    }
                    ForEach(app.favouriteTags.prefix(sectionLimit), id: \.self) { tag in
                        favouriteTagRow(tag)
                    }
                    .onMove { from, to in
                        try? app.store.updateConfig {
                            $0.favouriteTags.move(fromOffsets: from, toOffset: to)
                        }
                        app.dataVersion += 1
                    }
                }
            }

            if !recentsDisplay.isEmpty {
                Section("Recents", isExpanded: $recentsExpanded) {
                    ForEach(recentsDisplay.prefix(sectionLimit), id: \.self) { name in
                        pageRow(name, rowID: .recent(PageName.key(name)),
                                icon: "clock")
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
                                Text("\(entry.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .layoutPriority(1)
                            }
                        }
                        .contextMenu { tagFavouriteButton(entry.tag) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

    @ViewBuilder
    private func sidebarRow<Content: View>(
        _ rowID: RowID, target: NavTarget, @ViewBuilder content: () -> Content
    ) -> some View {
        let selected = isSelected(rowID, target: target)
        Button {
            if wantsSidebarClick() {
                nav.openInRightSidebar(target)
            } else {
                lastClickedRow = rowID
                nav.navigate(to: target)
            }
        } label: {
            content()
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 7)
                // Standard macOS sidebar row height (Photos/Music): 28 pt,
                // pill filling the full row.
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pill hugs the row content (inset from the sidebar edges), like
        // first-party sidebars — not the full row width.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected
                    ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                    : Color.clear)
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    /// A row highlights when it points at the current location — but if the
    /// page appears in several sections, only the row the user actually
    /// clicked (or Favourites first, for external navigation) lights up.
    private func isSelected(_ rowID: RowID, target: NavTarget) -> Bool {
        guard Self.normalize(target) == Self.normalize(nav.current) else { return false }
        if let lastClickedRow,
           Self.normalize(rowTarget(lastClickedRow)) == Self.normalize(nav.current) {
            return rowID == lastClickedRow
        }
        // Navigation didn't come from the sidebar: prefer Favourites.
        if case .recent(let key) = rowID {
            return !app.favourites.contains { PageName.key($0) == key }
        }
        return true
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
        }
    }

    /// A favourited tag row — same target as a Tags-section row, hash-iconed
    /// to read as a tag among the doc-iconed page favourites.
    private func favouriteTagRow(_ tag: String) -> some View {
        sidebarRow(.favouriteTag(tag), target: .tag(tag)) {
            rowLabel(tag, icon: "number")
        }
        .contextMenu { tagFavouriteButton(tag) }
    }

    @ViewBuilder
    private func tagFavouriteButton(_ tag: String) -> some View {
        Button(app.store.config.isFavouriteTag(tag)
            ? "Remove from Favourites" : "Add to Favourites") {
            app.toggleFavouriteTag(tag)
        }
        Button("Open in Sidebar") { nav.openInRightSidebar(.tag(tag)) }
    }

    private func displayName(for name: String) -> String {
        if let date = JournalDate(pageName: name) { return date.displayName }
        return name
    }
}
