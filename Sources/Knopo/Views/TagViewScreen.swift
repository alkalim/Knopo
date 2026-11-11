import SwiftUI
import KnopoCore

/// Generated, read-only tag view: all blocks carrying the tag, grouped by
/// page, with breadcrumbs and click-to-navigate (SPEC §8.2). Not a page —
/// can't be edited, referenced, favourited, or linked to.
struct TagViewScreen: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let tag: String
    /// In a right-sidebar pane the card header shows the title + actions menu,
    /// so this view's own header is suppressed (mirrors `PageScreen`).
    var inPane = false

    @State private var renameShown = false
    @State private var renameText = ""

    var body: some View {
        let _ = app.dataVersion
        let hits = (try? app.store.cache.blocks(taggedWith: tag)) ?? []
        let pages = (try? app.store.cache.pages(taggedWith: tag)) ?? []
        let groups = PageGroupOrder.sorted(Dictionary(grouping: pages + hits, by: \.pageDisplayName))

        let content = VStack(alignment: .leading, spacing: 12 * BlockRenderer.zoom) {
            if !inPane {
                HStack {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "#\(tag)")   // the tag is data, not a key
                            .font(.system(size: BlockRenderer.pageTitleFontSize, weight: .bold))
                            .foregroundStyle(.purple)
                        if !pages.isEmpty {
                            Text("\(pages.count) pages")
                                .font(.system(size: BlockRenderer.baseFontSize))
                                .foregroundStyle(.secondary)
                        }
                        if !hits.isEmpty || pages.isEmpty {
                            Text("\(hits.count) blocks")
                                .font(.system(size: BlockRenderer.baseFontSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ActionsMenu {
                        Button(app.store.config.isFavouriteTag(tag)
                            ? "Remove from Favourites" : "Add to Favourites") {
                            app.toggleFavouriteTag(tag)
                        }
                        Divider()
                        Button("Rename Tag…") {
                            renameText = tag
                            renameShown = true
                        }
                    }
                }
                Text("Tag view — generated, read-only. Tags are labels, not pages.")
                    .font(.system(size: BlockRenderer.baseFontSize * 0.85))
                    .foregroundStyle(.secondary)
            }

            // Read-only results, laid out like Linked References.
            BlockResultList(groups: groups, editable: false)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)

        return Group {
            if inPane {
                // The sidebar scrolls the whole card stack.
                content
            } else {
                ScrollView { content }
            }
        }
        .sheet(isPresented: $renameShown) { renameSheet }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag").font(.headline)
            TextField("New tag name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(performRename)
            HStack {
                Spacer()
                Button("Cancel") { renameShown = false }
                Button("Rename", action: performRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func performRename() {
        let newTag = renameText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !newTag.isEmpty, newTag != tag else {
            renameShown = false
            return
        }
        do {
            try app.renameTag(from: tag, to: newTag)
            renameShown = false
            nav.navigate(to: .tag(newTag))
        } catch {
            NSAlert(for: error).runModal()
        }
    }
}
