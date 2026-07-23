import SwiftUI
import KnopoCore

/// Page browser. Namespaced pages (`Projects/Outliner`) are flat pages grouped
/// hierarchically for display only (SPEC §3.2).
struct AllPagesView: View {
    private enum SectionID: Hashable {
        case journal
        case pages
        case namespace(String)

        var encoded: String {
            switch self {
            case .journal: return "journal"
            case .pages: return "pages"
            case .namespace(let name): return "namespace\t\(name)"
            }
        }
    }

    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    /// In a right-sidebar pane the card header shows the "All Pages" title, so
    /// this view's own title is suppressed (mirrors `PageScreen`/`TagViewScreen`).
    var inPane = false
    @State private var filter = ""
    @State private var newPageShown = false
    @State private var newPageName = ""

    var body: some View {
        let _ = app.dataVersion
        let pages = app.allPages().filter {
            filter.isEmpty
                || fuzzyMatch(query: filter, in: pageDisplayTitle($0.displayName))
                || fuzzyMatch(query: filter, in: $0.displayName)
        }
        let journals = pages.filter(\.isJournal).sorted {
            ($0.journalDate ?? $0.nameKey) > ($1.journalDate ?? $1.nameKey)
        }
        let groups = Dictionary(grouping: pages.filter { !$0.isJournal }) { listing in
            PageName.segments(listing.displayName).count > 1
                ? PageName.segments(listing.displayName)[0]
                : ""
        }
        .sorted { $0.key < $1.key }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !inPane {
                    Text("All Pages").font(.system(size: 24, weight: .bold))
                }
                Spacer()
                Button {
                    newPageName = ""
                    newPageShown = true
                } label: {
                    Label("New Page", systemImage: "plus")
                }
            }
            .padding(20)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter pages…", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            List {
                if let flat = groups.first(where: { $0.key.isEmpty })?.value {
                    pageSection("Pages", id: .pages, listings: flat)
                }
                ForEach(groups.filter { !$0.key.isEmpty }, id: \.key) { (namespace, members) in
                    pageSection(
                        namespace,
                        id: .namespace(namespace),
                        listings: members
                    )
                }
                if !journals.isEmpty {
                    pageSection("Journal", id: .journal, listings: journals)
                }
            }
            .listStyle(.inset)
        }
        .sheet(isPresented: $newPageShown) { newPageSheet }
    }

    private func pageRow(_ listing: PageListing) -> some View {
        Button {
            let target = NavTarget.page(name: listing.displayName)
            wantsSidebarClick() ? nav.openInRightSidebar(target) : nav.navigate(to: target)
        } label: {
            HStack {
                Image(systemName: listing.isJournal ? "calendar" : "doc.text")
                    .foregroundStyle(.secondary)
                Text(pageDisplayTitle(listing.displayName))
                if !listing.fileExists {
                    Text("stub").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(listing.blockCount)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(app.store.config.isFavourite(listing.displayName)
                ? "Unfavourite" : "Favourite") {
                app.toggleFavourite(listing.displayName)
            }
            Button("Open in Sidebar") {
                nav.openInRightSidebar(.page(name: listing.displayName))
            }
            Divider()
            Button("Delete…", role: .destructive) {
                try? nav.deletePage(named: listing.displayName)
            }
        }
    }

    private func pageSection(
        _ title: String,
        id: SectionID,
        listings: [PageListing]
    ) -> some View {
        let collapsed = app.allPagesCollapsedSections.contains(id.encoded)
        return Section {
            sectionHeader(title, id: id)
            if !filter.isEmpty || !collapsed {
                ForEach(listings, id: \.nameKey) { pageRow($0) }
            }
        }
        .listSectionSeparator(.hidden)
    }

    /// Native macOS `List` headers pin and draw a full-width bottom rule. This
    /// first row inside each section scrolls normally and owns its inset rule.
    private func sectionHeader(_ title: String, id: SectionID) -> some View {
        let collapsed = filter.isEmpty
            && app.allPagesCollapsedSections.contains(id.encoded)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                app.toggleAllPagesSection(id.encoded)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!filter.isEmpty)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private var newPageSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Page").font(.headline)
            TextField("Page name", text: $newPageName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(createPage)
            Text("Use “/” for namespaces, e.g. Projects/Outliner")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { newPageShown = false }
                Button("Create", action: createPage)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!PageName.isValid(newPageName))
            }
        }
        .padding(20)
    }

    private func createPage() {
        guard PageName.isValid(newPageName) else { return }
        do {
            _ = try app.store.createPage(named: newPageName)
            newPageShown = false
            nav.navigateToNewPage(named: newPageName)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
