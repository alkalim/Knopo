import SwiftUI

struct WindowRequest: Codable, Hashable {
    let root: URL
    let target: NavTarget
}

struct OpenInNewWindow: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppState
    let target: NavTarget

    var body: some View {
        Button("Open in New Window") {
            if let name = target.pageName { app.recordVisit(toPageNamed: name) }
            openWindow(value: WindowRequest(root: app.store.root, target: target))
        }
    }
}

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
