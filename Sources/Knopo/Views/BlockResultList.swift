import AppKit
import SwiftUI
import KnopoCore

/// Blocks grouped by page, each with its breadcrumb. Linked References
/// (SPEC §9.1) and the tag view (§8.2) both show their results this way.
struct BlockResultList: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let groups: [(key: String, value: [BacklinkHit])]
    /// Reference rows edit in place. Tag view rows are read-only.
    let editable: Bool

    @State private var collapsedGroups: Set<String> = []

    /// One level of a list: a chevron and the gap after it.
    static var levelIndent: CGFloat { 18 * BlockRenderer.zoom }

    var body: some View {
        // Lazy so a long list only renders the rows in view.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
                let blockHits = group.value.filter { !$0.isPageResult }
                groupHeader(group.key, hasBlocks: !blockHits.isEmpty)
                    .padding(.top, index == 0 ? 0 : 10 * BlockRenderer.zoom)
                    .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 0) {
                    if !blockHits.isEmpty, !collapsedGroups.contains(group.key) {
                        // One query per visible group. The rows need each other's
                        // ancestors to nest and to share breadcrumbs.
                        let ancestors = (try? app.store.cache.breadcrumbs(
                            ofBlocks: blockHits.map(\.blockID))) ?? [:]
                        let numbering = SourceNumbering(app: app, page: group.key)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(ResultRowLayout.layout(blockHits, ancestors: ancestors,
                                                           markers: numbering.markers, widths: numbering.widths),
                                    id: \.hit.blockID) { row in
                                ResultRow(row: row, editable: editable)
                                    .padding(.leading, Self.levelIndent - ResultRowLayout.dotInset)
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .clipped()
                .contentShape(Rectangle())
            }
        }
    }

    /// The chevron collapses the group. The name opens the page, like any page link.
    private func groupHeader(_ sourcePage: String, hasBlocks: Bool) -> some View {
        HStack(spacing: 4 * BlockRenderer.zoom) {
            if hasBlocks {
                Button {
                    withAnimation(app.preferences.animationsEnabled ? .easeOut(duration: 0.16) : nil) {
                        if collapsedGroups.contains(sourcePage) { collapsedGroups.remove(sourcePage) }
                        else { collapsedGroups.insert(sourcePage) }
                    }
                } label: {
                    ResultChevron(expanded: !collapsedGroups.contains(sourcePage))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14 * BlockRenderer.zoom, height: 14 * BlockRenderer.zoom)
            }
            Button {
                let target = NavTarget.page(name: sourcePage)
                wantsSidebarClick() ? nav.openInRightSidebar(target) : nav.navigate(to: target)
            } label: {
                Text(app.displayTitle(for: sourcePage))
                    .font(.system(size: BlockRenderer.baseFontSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .linkColor))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Source blocks

    /// How a result row renders a block. A row has no width for a table grid,
    /// so a table shows its raw source (§5.2). A heading shows at body size so
    /// it does not outweigh the list.
    static func renderContext(_ app: AppState) -> BlockRenderer.Context {
        var context = BlockRenderer.Context(
            resolveBlockRef: { [weak app] id in app?.store.resolveBlock(id)?.block.content },
            assetsDir: app.store.assetsDir,
            tables: false
        )
        context.compactHeadings = true
        return context
    }

    /// The source block a result row shows. The row's id comes from the index.
    /// The store handles both matching indexed IDs and stale result IDs.
    static func sourceBlock(_ app: AppState, _ id: UUID) -> (pageName: String, block: Block)? {
        app.store.resolveBlock(id)
    }

    /// Rewrites a result row's source block. `change` returns nil to skip.
    @discardableResult
    static func updateSourceBlock(
        _ app: AppState, _ id: UUID, undoLabel: String, _ change: (String) -> String?
    ) -> Bool {
        guard let source = sourceBlock(app, id) else { return false }
        var doc = app.document(for: source.pageName)
        guard let path = doc.blocks.path(to: source.block.id),
              let content = change(source.block.content) else { return false }
        doc.blocks.update(at: path) { $0.content = content }
        app.commit(doc, undoLabel: undoLabel)
        return true
    }

    /// Writes an image resize from a result row to its source block.
    static func resizeImage(_ app: AppState, block: UUID, imageIndex: Int, width: CGFloat) {
        updateSourceBlock(app, block, undoLabel: "Resize Image") {
            InlineParser.settingImageWidth($0, imageIndex: imageIndex, width: Int(width.rounded()))
        }
    }
}

/// The disclosure chevron of a section or a page group.
struct ResultChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9 * BlockRenderer.zoom, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 14 * BlockRenderer.zoom, height: 14 * BlockRenderer.zoom)
            .contentShape(Rectangle())
    }
}

/// One result row, placed within its page group.
struct ResultRowLayout: Equatable {
    let hit: BacklinkHit
    /// Levels under an earlier row that is one of this block's ancestors.
    let depth: Int
    /// Ancestors below that row, or below the page when there is none. Empty
    /// when the row above at the same level already shows the same path.
    let breadcrumb: [BreadcrumbItem]
    var marker: OutlineNumbering.Marker? = nil
    var markerWidth: CGFloat = 0
    var indent: CGFloat = 0

    static var bulletSize: CGFloat { 5 * BlockRenderer.zoom }
    /// Padding around the shared marker slot keeps its full width clickable.
    static var markerInset: CGFloat { 6.5 * BlockRenderer.zoom }
    static var dotInset: CGFloat {
        markerInset + OutlineMarkerLayout.minimumSlot - OutlineMarkerLayout.bulletCenterOffset - bulletSize / 2
    }
    static func gutterWidth(slot: CGFloat) -> CGFloat {
        max(OutlineMarkerLayout.minimumSlot, slot) + 2 * markerInset
    }

    /// `hits` must be in document order, so an ancestor row comes first.
    static func layout(
        _ hits: [BacklinkHit], ancestors: [UUID: [BreadcrumbItem]],
        markers: [UUID: OutlineNumbering.Marker] = [:], widths: [UUID: CGFloat] = [:]
    ) -> [ResultRowLayout] {
        var depthOf: [UUID: Int] = [:]
        var contentX: [UUID: CGFloat] = [:]
        // The last path shown at each depth, with the row it hangs under.
        var shown: [Int: (parent: UUID?, path: [UUID])] = [:]
        var rows: [ResultRowLayout] = []
        for hit in hits {
            let path = ancestors[hit.blockID] ?? []
            let parentIndex = path.lastIndex { depthOf[$0.id] != nil }
            let parent = parentIndex.map { path[$0].id }
            let depth = parent.flatMap { depthOf[$0] }.map { $0 + 1 } ?? 0
            let below = parentIndex.map { Array(path[($0 + 1)...]) } ?? path
            // A shallower row ends the run of siblings below it.
            shown = shown.filter { $0.key <= depth }
            let repeats = shown[depth].map { $0.parent == parent && $0.path == below.map(\.id) } ?? false
            shown[depth] = (parent, below.map(\.id))
            depthOf[hit.blockID] = depth
            let marker = markers[hit.blockID]
            let slot = max(OutlineMarkerLayout.minimumSlot,
                widths[hit.blockID] ?? marker.flatMap { widths[$0.runID] } ?? 0)
            let indent = parent.flatMap { contentX[$0] }.map {
                $0 + OutlineRowCell.indentPerDepth - gutterWidth(slot: 0)
            } ?? 0
            contentX[hit.blockID] = indent + gutterWidth(slot: slot)
            rows.append(ResultRowLayout(hit: hit, depth: depth, breadcrumb: repeats ? [] : below,
                                        marker: marker, markerWidth: slot, indent: indent))
        }
        return rows
    }
}

/// One result block: breadcrumb and content. An editable row writes edits
/// through to the source page (SPEC §9.1). A read-only row opens its block
/// on click (§8.2).
struct ResultRow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let row: ResultRowLayout
    let editable: Bool

    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    private var hit: BacklinkHit { row.hit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !row.breadcrumb.isEmpty {
                // Starts at the bullet, so the block reads as under its path.
                breadcrumbBar
                    .padding(.leading, ResultRowLayout.dotInset)
                    .padding(.top, 4 * BlockRenderer.zoom)
            }
            HStack(alignment: .top, spacing: 0) {
                bullet
                if editing {
                    editField
                } else {
                    content
                }
            }
        }
        .padding(.trailing, 4)
        .padding(.leading, row.indent)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }

    private var content: some View {
        ResultBlockText(
            text: BlockRenderer.render(content: hit.content,
                                       context: BlockResultList.renderContext(app)),
            onLink: { url, sidebar in nav.openURL(url, inSidebar: sidebar) },
            onImageResize: editable ? { index, width in
                BlockResultList.resizeImage(app, block: hit.blockID,
                                            imageIndex: index, width: width)
            } : nil,
            hoverHint: editable ? L("Double-click to edit here. Click the bullet or number to open this block.") : nil,
            onClick: { clickCount, sidebar in
                // Cmd/Shift-click opens the block in the sidebar, in any row.
                if sidebar {
                    openBlock(inSidebar: true)
                } else if editable {
                    guard clickCount >= 2 else { return }
                    draft = currentContent()
                    editing = true
                } else {
                    openBlock(inSidebar: false)
                }
            })
    }

    private var editField: some View {
        // `as String` picks the verbatim initializer: an empty label is not a key.
        TextField("" as String, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: BlockRenderer.baseFontSize))
            .padding(.vertical, OutlineRowCell.contentInsetV)
            .focused($fieldFocused)
            // A new field has no focus, so typing would go elsewhere.
            .onAppear { fieldFocused = true }
            .onSubmit(commitEdit)
            // Leaving the field saves, like leaving a block in the outline.
            .onChange(of: fieldFocused) { _, focused in
                if !focused && editing { commitEdit() }
            }
            .onExitCommand { editing = false }
    }

    /// The bullet opens the block, as in the outline. The row highlight shows
    /// which block that is.
    private var bullet: some View {
        Button { openBlock(inSidebar: wantsSidebarClick()) } label: {
            if let marker = row.marker {
                Text(verbatim: marker.label)
                    .font(Font(OutlineMarkerLayout.font))
                    .foregroundStyle(.secondary)
                    .frame(width: row.markerWidth, alignment: .trailing)
                    .padding(.horizontal, ResultRowLayout.markerInset)
                    .frame(height: BlockRenderer.lineHeight(forSource: ""))
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(String(localized: "Item \(marker.label), go to block",
                        comment: "Accessible action for a numbered result marker")))
            } else {
                Circle()
                .fill(Color.secondary.opacity(hovering ? 0.9 : 0.5))
                .frame(width: ResultRowLayout.bulletSize, height: ResultRowLayout.bulletSize)
                .offset(x: ResultRowLayout.bulletSize / 2 - OutlineMarkerLayout.bulletCenterOffset)
                .frame(width: max(OutlineMarkerLayout.minimumSlot, row.markerWidth), alignment: .trailing)
                .padding(.horizontal, ResultRowLayout.markerInset)
                .frame(height: BlockRenderer.lineHeight(forSource: ""))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .padding(.top, OutlineRowCell.contentInsetV)
        .hoverHint(L("Open this block. ⌘-click or Shift-click to open in the right sidebar."))
    }

    /// Each ancestor opens its own block.
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(row.breadcrumb.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Text(verbatim: "›") }
                BreadcrumbSegment(title: snippet(item.content)) {
                    nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: item.id,
                                        content: item.content, inSidebar: wantsSidebarClick())
                }
            }
        }
        .font(.system(size: BlockRenderer.baseFontSize * 0.85))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func openBlock(inSidebar: Bool) {
        nav.navigateToBlock(pageName: hit.pageDisplayName, blockID: hit.blockID,
                            content: hit.content, inSidebar: inSidebar)
    }

    private func currentContent() -> String {
        BlockResultList.sourceBlock(app, hit.blockID)?.block.content ?? hit.content
    }

    private func commitEdit() {
        let draft = draft
        editing = false
        // An unchanged draft writes nothing, so it leaves no undo step.
        if BlockResultList.updateSourceBlock(app, hit.blockID, undoLabel: "Edit Reference", {
            $0 == draft ? nil : draft
        }) {
            app.flushPendingSaves()
        }
    }

    private func snippet(_ content: String) -> String {
        let plain = BlockRenderer.plainPreview(content).trimmingCharacters(in: .whitespaces)
        return plain.count > 30 ? String(plain.prefix(30)) + "…" : plain
    }
}

/// A breadcrumb entry that underlines on hover, so it reads as clickable.
private struct BreadcrumbSegment: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title).underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Block content in a result row. Uses the outline's text view, so links,
/// tag pills and click handling match the outline.
struct ResultBlockText: NSViewRepresentable {
    let text: NSAttributedString
    var onLink: (URL, Bool) -> Void
    /// Nil turns image resize handles off. Without it a handle would do nothing.
    var onImageResize: ((_ imageIndex: Int, _ width: CGFloat) -> Void)?
    var hoverHint: String? = nil
    var fitsContent = false
    var verticalInset = OutlineRowCell.contentInsetV
    var allowsTextSelection = false
    /// A click on plain text: its click count, and whether Cmd or Shift asks
    /// for the sidebar.
    var onClick: ((_ clickCount: Int, _ sidebar: Bool) -> Void)?

    func makeNSView(context: Context) -> RenderedTextView {
        let view = RenderedTextView.create()
        view.autoresizingMask = []
        return view
    }

    func updateNSView(_ view: RenderedTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
        view.onLinkClick = onLink
        view.allowsImageResize = onImageResize != nil
        view.onImageResize = onImageResize ?? { _, _ in }
        view.hoverHint = hoverHint
        view.allowsTextSelection = allowsTextSelection
        view.textContainerInset.height = verticalInset
        view.setAccessibilityHelp(hoverHint)
        let onClick = onClick
        view.onFocusRequest = { _ in onClick?(NSApp?.currentEvent?.clickCount ?? 1, false) }
        // The text view sends Cmd/Shift-clicks here, meant for node selection.
        // A result list selects nothing, so they open the sidebar.
        view.onSelectRequest = { _, _ in onClick?(1, true) }
    }

    static func dismantleNSView(_ view: RenderedTextView, coordinator: ()) {
        HoverHint.shared.dismiss(for: view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: RenderedTextView, context: Context
    ) -> CGSize? {
        let availableWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let width = fitsContent ? min(availableWidth, ceil(text.size().width)) : availableWidth
        // The outline's row height without the gap between rows.
        let height = OutlineRowCell.height(for: text, contentWidth: width)
            - 2 * OutlineRowCell.verticalPadding
            - 2 * (OutlineRowCell.contentInsetV - verticalInset)
        return CGSize(width: width, height: height)
    }
}
