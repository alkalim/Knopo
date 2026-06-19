import SwiftUI
import EverseqCore

/// Cmd+K: fuzzy page-name match on top, full-text block search below.
/// Enter navigates, Cmd+Enter opens in the right sidebar (SPEC §12).
struct SearchPalette: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private enum Result {
        case page(String)
        case createPage(String)
        case block(SearchHit)
    }

    var body: some View {
        let results = computeResults()
        VStack(spacing: 0) {
            TextField("Search pages and blocks…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .focused($fieldFocused)
                .onSubmit { activate(results, sidebar: false) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(results.count - 1, 0)); return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0); return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    activate(results, sidebar: true)
                    return .handled
                }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { (i, result) in
                            resultRow(result, selected: i == selection)
                                .id(i)
                                .onTapGesture {
                                    selection = i
                                    activate(results, sidebar: wantsSidebarClick())
                                }
                        }
                        if results.isEmpty {
                            Text(query.isEmpty ? "Type to search" : "No results")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                }
                .onChange(of: selection) { _, newValue in
                    proxy.scrollTo(newValue)
                }
            }
            // Fixed height: the palette must not resize as results change.
            .frame(height: 380)
        }
        // Keep content clear of the sheet's large corner radius (macOS 26).
        .padding(10)
        .frame(width: 560)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func computeResults() -> [Result] {
        guard !query.isEmpty else {
            return app.pageNames(matching: "").prefix(12).map { .page($0) }
        }
        var results: [Result] = app.pageNames(matching: query).prefix(8).map { .page($0) }
        let exactExists = app.allPages().contains {
            PageName.key($0.displayName) == PageName.key(query)
        }
        if !exactExists, PageName.isValid(query) {
            results.append(.createPage(query))
        }
        let hits = (try? app.store.cache.searchBlocks(query, limit: 20)) ?? []
        results += hits.map { .block($0) }
        return results
    }

    @ViewBuilder
    private func resultRow(_ result: Result, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch result {
            case .page(let name):
                Image(systemName: JournalDate(pageName: name) != nil ? "calendar" : "doc.text")
                    .foregroundStyle(.secondary)
                Text(pageDisplayTitle(name))
            case .createPage(let name):
                Image(systemName: "plus.circle").foregroundStyle(.green)
                Text("Create page “\(name)”")
            case .block(let hit):
                Image(systemName: "text.alignleft").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snippet(hit.content)).lineLimit(1)
                    Text(pageDisplayTitle(hit.pageDisplayName))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func activate(_ results: [Result], sidebar: Bool) {
        guard results.indices.contains(selection) else { return }
        let target: NavTarget
        switch results[selection] {
        case .page(let name):
            target = .page(name: name)
        case .createPage(let name):
            _ = try? app.store.createPage(named: name)
            nav.focusFirstBlock = name // focus the empty first block on load
            target = .page(name: name)
        case .block(let hit):
            target = .page(name: hit.pageDisplayName, zoom: hit.blockID)
        }
        dismiss()
        sidebar ? nav.openInRightSidebar(target) : nav.navigate(to: target)
    }

    private func snippet(_ content: String) -> String {
        InlineParser.plainText(InlineParser.parse(
            content.components(separatedBy: "\n").first ?? content))
    }
}
