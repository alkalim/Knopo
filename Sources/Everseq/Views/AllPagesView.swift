import SwiftUI
import EverseqCore

/// Page browser. Namespaced pages (`Projects/Outliner`) are flat pages grouped
/// hierarchically for display only (SPEC §3.2).
struct AllPagesView: View {
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
            filter.isEmpty || fuzzyMatch(query: filter, in: $0.displayName)
        }
        let groups = Dictionary(grouping: pages) { listing in
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
                // Ungrouped pages first, then namespace groups.
                if let flat = groups.first(where: { $0.key.isEmpty })?.value {
                    ForEach(flat, id: \.nameKey) { pageRow($0) }
                }
                ForEach(groups.filter { !$0.key.isEmpty }, id: \.key) { (namespace, members) in
                    Section(namespace) {
                        ForEach(members, id: \.nameKey) { pageRow($0) }
                    }
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
                Text(listing.displayName)
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
