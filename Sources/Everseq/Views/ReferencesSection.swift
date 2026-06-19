import SwiftUI
import EverseqCore

/// Linked References and Unlinked References below page content (SPEC §9).
struct ReferencesSection: View {
    @EnvironmentObject var app: AppState
    let pageName: String

    @State private var collapsedGroups: Set<String> = []
    @State private var unlinkedExpanded = false

    var body: some View {
        let _ = app.dataVersion
        let backlinks = (try? app.store.cache.backlinks(of: PageName.key(pageName))) ?? []
        let unlinked = (try? app.store.cache.unlinkedReferences(toPageNamed: pageName)) ?? []

        VStack(alignment: .leading, spacing: 10) {
            if !backlinks.isEmpty {
                linkedSection(backlinks)
            }
            if !unlinked.isEmpty {
                unlinkedSection(unlinked)
            }
        }
    }

    // MARK: - Linked (SPEC §9.1)

    @ViewBuilder
    private func linkedSection(_ hits: [BacklinkHit]) -> some View {
        let groups = Dictionary(grouping: hits, by: \.pageDisplayName)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        HStack(spacing: 6) {
            Text("Linked References").font(.headline)
            Text("\(hits.count)")
                .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        }
        ForEach(groups, id: \.key) { (sourcePage, groupHits) in
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    toggleGroup(sourcePage)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: collapsedGroups.contains(sourcePage)
                            ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(pageDisplayTitle(sourcePage))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                if !collapsedGroups.contains(sourcePage) {
                    ForEach(groupHits, id: \.blockID) { hit in
                        BacklinkRow(hit: hit, contextPage: pageName)
                            .padding(.leading, 14)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleGroup(_ key: String) {
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) }
        else { collapsedGroups.insert(key) }
    }

    // MARK: - Unlinked (SPEC §9.2)

    @ViewBuilder
    private func unlinkedSection(_ hits: [SearchHit]) -> some View {
        Button {
            unlinkedExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: unlinkedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text("Unlinked References").font(.headline)
                Text("\(hits.count)")
                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 6)

        if unlinkedExpanded {
            ForEach(hits, id: \.blockID) { hit in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pageDisplayTitle(hit.pageDisplayName))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(AttributedString(BlockRenderer.render(
                            content: hit.content, context: renderContext())))
                    }
                    Spacer()
                    Button("Link") { link(hit) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.leading, 14)
            }
        }
    }

    /// Wraps the matched text in `[[...]]` in the source block (SPEC §9.2).
    private func link(_ hit: SearchHit) {
        var doc = app.document(for: hit.pageDisplayName)
        guard let path = doc.blocks.path(to: hit.blockID) else { return }
        let pattern = "(?<![\\[\\w#])" + NSRegularExpression.escapedPattern(for: pageName) + "(?![\\]\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return }
        doc.blocks.update(at: path) { block in
            let content = block.content
            let range = NSRange(content.startIndex..., in: content)
            if let match = regex.firstMatch(in: content, range: range),
               let r = Range(match.range, in: content) {
                block.content = content.replacingCharacters(
                    in: r, with: "[[\(pageName)]]")
            }
        }
        app.commit(doc, undoLabel: "Link Reference")
        app.flushPendingSaves()
    }

    private func renderContext() -> BlockRenderer.Context {
        BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir
        )
    }
}

/// One backlink block: breadcrumb + content, editable in place — edits write
/// through to the source page (SPEC §9.1).
struct BacklinkRow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let hit: BacklinkHit
    let contextPage: String

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !hit.breadcrumb.isEmpty {
                Text(hit.breadcrumb.map(snippet).joined(separator: " › "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit(commitEdit)
                        .onExitCommand { editing = false }
                } else {
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
                    .onTapGesture(count: 2) {
                        draft = currentContent()
                        editing = true
                    }
                    .help("Double-click to edit in place; click links to navigate")
                }
                Spacer(minLength: 0)
                Button {
                    nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: hit.blockID,
                                        content: hit.content, inSidebar: wantsSidebarClick())
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Go to block")
            }
        }
        .padding(.vertical, 2)
    }

    private func currentContent() -> String {
        guard let doc = optionalDoc(),
              let path = doc.blocks.path(to: hit.blockID),
              let block = doc.blocks.block(at: path) else { return hit.content }
        return block.content
    }

    private func commitEdit() {
        guard var doc = optionalDoc(),
              let path = doc.blocks.path(to: hit.blockID) else {
            editing = false
            return
        }
        doc.blocks.update(at: path) { $0.content = draft }
        app.commit(doc, undoLabel: "Edit Reference")
        app.flushPendingSaves()
        editing = false
    }

    private func optionalDoc() -> PageDocument? {
        app.document(for: hit.pageDisplayName)
    }

    private func snippet(_ content: String) -> String {
        let plain = InlineParser.plainText(InlineParser.parse(
            content.components(separatedBy: "\n").first ?? content))
        return plain.count > 30 ? String(plain.prefix(30)) + "…" : plain
    }
}
