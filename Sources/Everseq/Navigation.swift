import AppKit
import Foundation
import EverseqCore

/// A navigable destination. Pages and tag views can also open in right-sidebar
/// panes (SPEC §12).
enum NavTarget: Hashable {
    /// A page, optionally zoomed into one block (breadcrumb root).
    case page(name: String, zoom: UUID? = nil)
    /// The generated, read-only tag view (SPEC §8.2).
    case tag(String)
    /// Journal home: today + previous days, infinite scroll (SPEC §10).
    case journalHome
    case allPages

    var pageName: String? {
        if case .page(let name, _) = self { return name }
        return nil
    }

    /// Stable string form for persisting open right-sidebar panes (SPEC §12).
    /// Tab-delimited; page/tag names never contain tabs (PageName validation).
    var encoded: String {
        switch self {
        case .page(let name, let zoom): return "page\t\(name)\t\(zoom?.uuidString ?? "")"
        case .tag(let tag): return "tag\t\(tag)"
        case .journalHome: return "journalHome"
        case .allPages: return "allPages"
        }
    }

    init?(encoded: String) {
        let parts = encoded.components(separatedBy: "\t")
        switch parts.first {
        case "page" where parts.count == 3:
            self = .page(name: parts[1], zoom: parts[2].isEmpty ? nil : UUID(uuidString: parts[2]))
        case "tag" where parts.count == 2:
            self = .tag(parts[1])
        case "journalHome": self = .journalHome
        case "allPages": self = .allPages
        default: return nil
        }
    }
}

/// One open right-sidebar pane: a target plus whether it's collapsed to its
/// header (Mail-style thread cards, SPEC §12). Persisted via `encoded`.
struct RightPane: Hashable {
    var target: NavTarget
    var collapsed: Bool = false

    /// `"<0|1>\t<target.encoded>"` — the collapse flag, then the target's own
    /// (also tab-delimited) form.
    var encoded: String {
        (collapsed ? "1" : "0") + "\t" + target.encoded
    }

    init(target: NavTarget, collapsed: Bool = false) {
        self.target = target
        self.collapsed = collapsed
    }

    init?(encoded: String) {
        // New form: a leading "0"/"1" collapse flag.
        if let tab = encoded.firstIndex(of: "\t") {
            let flag = encoded[..<tab]
            if flag == "0" || flag == "1" {
                guard let t = NavTarget(encoded: String(encoded[encoded.index(after: tab)...]))
                else { return nil }
                self.init(target: t, collapsed: flag == "1")
                return
            }
        }
        // Legacy form (predating collapse): a bare NavTarget encoding.
        guard let t = NavTarget(encoded: encoded) else { return nil }
        self.init(target: t)
    }
}

/// A request to scroll to and briefly flash one block on a page, set when a
/// query / backlink / tag result is clicked. Matched by `blockID` first, then by
/// `content` — block UUIDs aren't stable across a re-parse unless `id::`-pinned,
/// so the content fallback keeps the highlight working when the id has drifted.
struct BlockHighlight: Equatable {
    let pageKey: String
    let blockID: UUID
    let content: String
}

/// Back/forward history (Cmd+[, Cmd+]).
struct NavHistory {
    private(set) var back: [NavTarget] = []
    private(set) var forward: [NavTarget] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func push(from current: NavTarget) {
        back.append(current)
        forward.removeAll()
        if back.count > 100 { back.removeFirst() }
    }

    mutating func goBack(from current: NavTarget) -> NavTarget? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    mutating func goForward(from current: NavTarget) -> NavTarget? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }
}

/// Cmd+click and Shift+click both open in the right sidebar (SPEC §12 names
/// Cmd; Shift matches Logseq muscle memory).
@MainActor
func wantsSidebarClick() -> Bool {
    let flags = NSEvent.modifierFlags
    return flags.contains(.command) || flags.contains(.shift)
}

/// Internal URL scheme used by rendered links.
/// everseq://page/<name>, everseq://block/<uuid>, everseq://tag/<name>
enum EverseqURL {
    static func page(_ name: String) -> URL {
        URL(string: "everseq://page/\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)")!
    }

    static func block(_ id: UUID) -> URL {
        URL(string: "everseq://block/\(id.uuidString.lowercased())")!
    }

    /// Navigate to a block *on a known page* — carries the page name (so it
    /// opens reliably) plus the block to zoom into. Used by query/backlink
    /// results, where the block's index id may not survive a re-parse (only
    /// `id::`-persisted blocks have stable ids), so a bare `block(id)` can fail
    /// to resolve its page.
    static func block(_ id: UUID, onPage name: String) -> URL {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return URL(string: "everseq://page/\(encoded)?block=\(id.uuidString.lowercased())")!
    }

    static func tag(_ name: String) -> URL {
        URL(string: "everseq://tag/\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)")!
    }

    /// Decodes an internal or external URL into a navigation action.
    static func decode(_ url: URL) -> NavTarget? {
        guard url.scheme == "everseq" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Decode from the *percent-encoded* path: a namespaced name like
        // "Test/Page1" encodes its `/` as `%2F`, and `url.lastPathComponent`
        // would decode that back into a separator and return just "Page1",
        // opening the wrong (stub) page.
        let rawPath = comps?.percentEncodedPath ?? ""
        let stripped = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let value = stripped.removingPercentEncoding ?? stripped
        switch url.host {
        case "page":
            // `everseq://page/<name>?block=<uuid>` zooms into that block.
            if let item = comps?.queryItems?.first(where: { $0.name == "block" }),
               let raw = item.value, let id = UUID(uuidString: raw) {
                return .page(name: value, zoom: id)
            }
            return .page(name: value)
        case "tag": return .tag(value)
        case "block":
            guard let id = UUID(uuidString: value) else { return nil }
            return .page(name: "", zoom: id) // resolved by AppState via index
        default: return nil
        }
    }
}

/// A page's list/header display title: journal pages show their pretty date
/// ("Apr 21st, 2026"); other pages use the literal name. Shared by the
/// references section, search palette, query results, and pane titles.
func pageDisplayTitle(_ name: String) -> String {
    JournalDate(pageName: name)?.displayName ?? name
}

/// Page-management actions shared by the page header and the right-pane card
/// menu, so the delete/rename flows have a single source of truth (SPEC §13).
@MainActor
enum PageActions {
    /// Aggregates incoming block-ref counts for the whole page, confirms, then
    /// trashes the file (SPEC §7.4, §13).
    static func confirmDelete(_ name: String, app: AppState, nav: Navigator) {
        let doc = app.document(for: name)
        let ids = doc.blocks.flattened.map(\.id)
        let refCount = (try? app.store.cache.incomingRefCount(forBlockIDs: ids)) ?? 0
        let alert = NSAlert()
        alert.messageText = "Delete “\(doc.displayTitle)”?"
        var info = "The file moves to the Trash. Links to this page become stubs."
        if refCount > 0 {
            info += " \(refCount) block reference\(refCount == 1 ? "" : "s") into this page will break."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? nav.deletePage(named: doc.name)
        }
    }

    /// Rename via a modal text field (matches the AppKit alert style; the main
    /// page view uses its own inline sheet).
    static func promptRename(_ name: String, nav: Navigator) {
        let alert = NSAlert()
        alert.messageText = "Rename Page"
        alert.informativeText = "Enter a new name for “\(name)”."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PageName.isValid(new), new != name else { return }
            do { try nav.renamePage(from: name, to: new) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    /// Rename a tag (a label, not a page — §8) across the graph.
    static func promptRenameTag(_ tag: String, app: AppState, nav: Navigator) {
        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.informativeText = "Enter a new name for #\(tag)."
        let field = NSTextField(string: tag)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !new.isEmpty, new != tag else { return }
            do {
                try app.renameTag(from: tag, to: new)
                nav.navigate(to: .tag(new))
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
