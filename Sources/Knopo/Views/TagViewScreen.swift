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
        let groups = Dictionary(grouping: hits, by: \.pageDisplayName)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !inPane {
                    HStack {
                        Text("#\(tag)")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.purple)
                        Text("\(hits.count) block\(hits.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                ForEach(groups, id: \.key) { (page, groupHits) in
                    VStack(alignment: .leading, spacing: 4) {
                        // Journal pages show their pretty date, not the raw
                        // ISO / Logseq filename form; navigation uses the key.
                        Button(pageDisplayTitle(page)) {
                            nav.navigate(to: .page(name: page))
                        }
                        .buttonStyle(.link)
                        .font(.subheadline.weight(.semibold))
                        ForEach(groupHits, id: \.blockID) { hit in
                            tagHitRow(hit)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $renameShown) { renameSheet }
    }

    private func tagHitRow(_ hit: BacklinkHit) -> some View {
        let breadcrumb = (try? app.store.cache.breadcrumb(ofBlock: hit.blockID)) ?? []
        return VStack(alignment: .leading, spacing: 2) {
            if !breadcrumb.isEmpty {
                Text(breadcrumb.map { line in
                    let plain = InlineParser.plainText(InlineParser.parse(
                        line.components(separatedBy: "\n").first ?? line))
                    return plain.count > 30 ? String(plain.prefix(30)) + "…" : plain
                }.joined(separator: " › "))
                .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5).padding(.top, 5)
                Text(AttributedString(BlockRenderer.render(
                    content: hit.content,
                    context: BlockRenderer.Context(
                        resolveBlockRef: { [weak app] id in
                            app?.store.resolveBlock(id)?.block.content
                        },
                        assetsDir: app.store.assetsDir
                    )
                )))
                .environment(\.openURL, OpenURLAction { url in
                    nav.openURL(url, inSidebar: wantsSidebarClick())
                    return .handled
                })
            }
            .contentShape(Rectangle())
            .onTapGesture {
                nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: hit.blockID,
                                    content: hit.content, inSidebar: wantsSidebarClick())
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 1)
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
            NSAlert(error: error).runModal()
        }
    }
}
