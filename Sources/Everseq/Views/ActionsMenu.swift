import SwiftUI

/// The app's standard borderless "⋯" actions menu: a plain ellipsis (no circle,
/// no disclosure chevron), tinted tertiary (matching the cards' close button).
/// Used by the page header, the tag view, and the right-pane cards so they all
/// look identical.
struct ActionsMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                // Color on the label image itself (the borderless menu style
                // ignores `foregroundStyle` applied to the Menu). `tint` below is
                // a belt-and-suspenders for the glyph. This is the same color
                // `.tertiary` gives the ✕ close button, so the two match.
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(Color(nsColor: .tertiaryLabelColor))
    }
}
