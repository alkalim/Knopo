import Foundation

/// `.knopo/config.json` — favourites and user settings (SPEC §4.1, §11.1).
/// Authoritative (not rebuildable), unlike `cache.db`.
public struct GraphConfig: Codable, Equatable, Sendable {
    /// Ordered list of favourite page display names.
    public var favourites: [String] = []
    /// Ordered list of favourite tag names (normalized lowercase). Tags are
    /// labels, not pages (§8), so they favourite into their own list.
    public var favouriteTags: [String] = []
    /// Display format for journal dates; only the default is implemented.
    public var dateFormat: String = "MMM d'th', yyyy"
    /// "system" | "light" | "dark"
    public var theme: String = "system"
    /// Right-sidebar layout (SPEC §12), persisted so a graph reopens as left.
    /// Encoded `NavTarget`s for the open panes (newest first); the app layer
    /// owns the encoding — the config just stores the opaque strings.
    public var rightPanes: [String] = []
    /// User-dragged right-sidebar width as a fraction (0–1) of the detail area,
    /// so it scales with the window and restores at any window size; nil →
    /// proportional default. (Replaces the old points-based `rightPaneWidth`.)
    public var rightPaneFraction: Double?
    /// Opaque app-layer identifiers for collapsed All Pages sections.
    public var allPagesCollapsedSections: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case favourites, favouriteTags, dateFormat, theme, rightPanes, rightPaneFraction
        case allPagesCollapsedSections
    }

    // Decode field-by-field so older config files (predating a field) still
    // load with defaults instead of failing the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try c.decodeIfPresent([String].self, forKey: .favourites) ?? []
        favouriteTags = try c.decodeIfPresent([String].self, forKey: .favouriteTags) ?? []
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? "MMM d'th', yyyy"
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        rightPanes = try c.decodeIfPresent([String].self, forKey: .rightPanes) ?? []
        rightPaneFraction = try c.decodeIfPresent(Double.self, forKey: .rightPaneFraction)
        allPagesCollapsedSections =
            try c.decodeIfPresent([String].self, forKey: .allPagesCollapsedSections) ?? []
    }

    public static func load(from url: URL) -> GraphConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(GraphConfig.self, from: data)
        else { return GraphConfig() }
        return config
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Favourites

    public func isFavourite(_ pageName: String) -> Bool {
        let key = PageName.key(pageName)
        return favourites.contains { PageName.key($0) == key }
    }

    public mutating func toggleFavourite(_ pageName: String) {
        let key = PageName.key(pageName)
        if let idx = favourites.firstIndex(where: { PageName.key($0) == key }) {
            favourites.remove(at: idx)
        } else {
            favourites.append(pageName)
        }
    }

    public mutating func renameFavourite(from oldName: String, to newName: String) {
        let key = PageName.key(oldName)
        for i in favourites.indices where PageName.key(favourites[i]) == key {
            favourites[i] = newName
        }
    }

    public mutating func removeFavourite(_ pageName: String) {
        let key = PageName.key(pageName)
        favourites.removeAll { PageName.key($0) == key }
    }

    // MARK: Favourite tags

    public func isFavouriteTag(_ tag: String) -> Bool {
        favouriteTags.contains(tag.lowercased())
    }

    public mutating func toggleFavouriteTag(_ tag: String) {
        let key = tag.lowercased()
        if let idx = favouriteTags.firstIndex(of: key) {
            favouriteTags.remove(at: idx)
        } else {
            favouriteTags.append(key)
        }
    }

    public mutating func renameFavouriteTag(from oldTag: String, to newTag: String) {
        let old = oldTag.lowercased()
        let new = newTag.lowercased()
        for i in favouriteTags.indices where favouriteTags[i] == old {
            favouriteTags[i] = new
        }
    }
}
