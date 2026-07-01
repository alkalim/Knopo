import SwiftUI
import EverseqCore

/// A page: header, breadcrumbs (when zoomed), outline editor, linked and
/// unlinked references (SPEC §6, §9).
struct PageScreen: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String
    var zoom: UUID? = nil
    var inPane = false

    @State private var renameSheetShown = false
    @State private var renameText = ""

    var body: some View {
        let _ = app.dataVersion
        let doc = app.document(for: pageName)
        let content = VStack(alignment: .leading, spacing: 12) {
            // In a pane the card's own header shows the title (and stays visible
            // when collapsed), so the page header here would just duplicate it.
            if !inPane {
                header(doc)
            }
            if zoom != nil {
                BreadcrumbBar(pageName: pageName, zoom: zoom)
            }
            OutlineEditorView(pageName: pageName, zoom: zoom)
            if !inPane {
                Divider().padding(.vertical, 8)
                ReferencesSection(pageName: pageName)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)

        return Group {
            if inPane {
                // In a right-sidebar pane the surrounding RightSidebar scrolls;
                // a second ScrollView here would nest and double-scroll.
                content
            } else {
                ScrollView { content }
            }
        }
        .sheet(isPresented: $renameSheetShown) { renameSheet }
    }

    private func header(_ doc: PageDocument) -> some View {
        HStack(spacing: 8) {
            Text(doc.displayTitle)
                .font(.system(size: 24 * BlockRenderer.zoom, weight: .bold))
            if !doc.fileExists {
                Text("stub")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ActionsMenu {
                Button(app.store.config.isFavourite(doc.name)
                    ? "Remove from Favourites" : "Add to Favourites") {
                    app.toggleFavourite(doc.name)
                }
                Divider()
                Button("Rename Page…") {
                    renameText = doc.name
                    renameSheetShown = true
                }
                .disabled(doc.isJournal)
                Button("Open in Sidebar") {
                    nav.openInRightSidebar(.page(name: pageName, zoom: zoom))
                }
                Divider()
                Button("Delete Page…", role: .destructive) { confirmDelete(doc) }
            }
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Page").font(.headline)
            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(performRename)
            HStack {
                Spacer()
                Button("Cancel") { renameSheetShown = false }
                Button("Rename", action: performRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!PageName.isValid(renameText))
            }
        }
        .padding(20)
    }

    private func performRename() {
        guard PageName.isValid(renameText), renameText != pageName else {
            renameSheetShown = false
            return
        }
        do {
            try nav.renamePage(from: pageName, to: renameText)
            renameSheetShown = false
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func confirmDelete(_ doc: PageDocument) {
        PageActions.confirmDelete(doc.name, app: app, nav: nav)
    }
}

/// `Page › parent › parent` when zoomed into a block (SPEC §12).
struct BreadcrumbBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String
    let zoom: UUID?

    var body: some View {
        let doc = app.document(for: pageName)
        HStack(spacing: 4) {
            Button(doc.displayTitle) {
                nav.navigate(to: .page(name: pageName))
            }
            .buttonStyle(.link)
            if let zoom, let path = doc.blocks.path(to: zoom) {
                ForEach(1...path.count, id: \.self) { i in
                    let ancestorPath = Array(path.prefix(i))
                    if let block = doc.blocks.block(at: ancestorPath) {
                        Text("›").foregroundStyle(.tertiary)
                        Button {
                            if i == path.count { return }
                            nav.navigate(to: .page(name: pageName, zoom: block.id))
                        } label: {
                            Text(snippet(block.content))
                                .lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .disabled(i == path.count)
                    }
                }
            }
        }
        .font(.caption)
    }

    private func snippet(_ content: String) -> String {
        let plain = InlineParser.plainText(InlineParser.parse(
            content.components(separatedBy: "\n").first ?? content))
        return plain.count > 40 ? String(plain.prefix(40)) + "…" : plain
    }
}
