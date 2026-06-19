import SwiftUI

/// The app's standard borderless "⋯" actions menu: a plain ellipsis (no circle,
/// no disclosure chevron), tinted secondary. Used by the page header, the tag
/// view, and the right-pane cards so they all look identical.
struct ActionsMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Applied to the Menu (not the label) so it actually tints the glyph.
        .foregroundStyle(.secondary)
    }
}
