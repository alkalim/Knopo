import SwiftUI

/// In-page find bar (Cmd+F). Edits `Navigator`'s find state; the outline
/// controller does the matching, highlighting, and scrolling, and writes the
/// match count back.
struct FindBar: View {
    @EnvironmentObject var nav: Navigator
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $nav.findQuery)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { nav.findNext() }
                .frame(maxWidth: 280)

            Text(matchLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button { nav.findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(nav.findMatchCount == 0)
                .help("Previous match (⇧⌘G)")
            Button { nav.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(nav.findMatchCount == 0)
                .help("Next match (⌘G)")

            Button("Done") { nav.closeFind() }
                .keyboardShortcut(.cancelAction) // Esc closes

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { fieldFocused = true }
    }

    private var matchLabel: String {
        if nav.findQuery.isEmpty { return "" }
        if nav.findMatchCount == 0 { return "No matches" }
        return "\(nav.findOrdinal) of \(nav.findMatchCount)"
    }
}
