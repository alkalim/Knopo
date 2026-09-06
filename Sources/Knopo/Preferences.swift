import AppKit
import Combine
import Foundation
import KnopoCore

/// Per-app viewing preferences. One instance is shared by every graph window;
/// graph-owned settings continue to live in `GraphConfig`.
@MainActor
final class Preferences: ObservableObject {
    enum Theme: String, CaseIterable {
        case system, light, dark

        /// Explicit per case, never derived from `rawValue`: that is persisted
        /// under `appearanceTheme`.
        var title: String {
            switch self {
            case .system: return String(localized: "System", comment: "Appearance theme")
            case .light: return String(localized: "Light", comment: "Appearance theme")
            case .dark: return String(localized: "Dark", comment: "Appearance theme")
            }
        }
    }

    static let standard = Preferences()

    static let themeKey = "appearanceTheme"
    static let defaultDateFormatKey = BlockRenderer.journalDateFormatKey

    private let defaults: UserDefaults
    private let syncsRenderer: Bool
    private var themeWasSet: Bool
    private var dateFormatWasSet: Bool

    @Published var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Self.themeKey)
            themeWasSet = true
            if syncsRenderer { Self.apply(theme) }
        }
    }

    @Published var contentWeight: BlockRenderer.ContentWeight {
        didSet {
            guard contentWeight != oldValue else { return }
            defaults.set(contentWeight.rawValue, forKey: BlockRenderer.contentWeightKey)
            if syncsRenderer { BlockRenderer.contentWeight = contentWeight }
            renderRevision += 1
        }
    }

    @Published var showPageRefBrackets: Bool {
        didSet {
            guard showPageRefBrackets != oldValue else { return }
            defaults.set(showPageRefBrackets, forKey: BlockRenderer.pageRefBracketsKey)
            if syncsRenderer { BlockRenderer.bracketsEnabled = showPageRefBrackets }
            renderRevision += 1
        }
    }

    /// *The* journal date format, not a seed for a per-graph copy: it decides
    /// how every window renders a journal title.
    @Published var defaultDateFormat: JournalDateFormat {
        didSet {
            guard defaultDateFormat != oldValue else { return }
            defaults.set(defaultDateFormat.pattern, forKey: Self.defaultDateFormatKey)
            dateFormatWasSet = true
            if syncsRenderer { BlockRenderer.journalDateFormat = defaultDateFormat }
            renderRevision += 1
        }
    }

    var zoom: CGFloat {
        get { zoomValue }
        set { setZoom(newValue) }
    }
    @Published private var zoomValue: CGFloat

    var density: CGFloat {
        get { densityValue }
        set { setDensity(newValue) }
    }
    @Published private var densityValue: CGFloat

    /// Bumped for preferences that require cached attributed strings and row
    /// measurements to be rebuilt in every open graph.
    @Published private(set) var renderRevision = 0

    init(defaults: UserDefaults = .standard, syncsRenderer: Bool = true) {
        self.defaults = defaults
        self.syncsRenderer = syncsRenderer
        themeWasSet = defaults.object(forKey: Self.themeKey) != nil
        dateFormatWasSet = defaults.object(forKey: Self.defaultDateFormatKey) != nil
        theme = Theme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .system
        contentWeight = BlockRenderer.ContentWeight(
            rawValue: defaults.string(forKey: BlockRenderer.contentWeightKey) ?? "") ?? .medium
        showPageRefBrackets = defaults.bool(forKey: BlockRenderer.pageRefBracketsKey)

        if let raw = defaults.string(forKey: Self.defaultDateFormatKey),
           let format = JournalDateFormat(validating: raw) {
            defaultDateFormat = format
        } else {
            defaultDateFormat = .default
        }

        let savedZoom = CGFloat(defaults.double(forKey: BlockRenderer.zoomKey))
        zoomValue = savedZoom > 0
            ? min(max(savedZoom, BlockRenderer.minZoom), BlockRenderer.maxZoom) : 1
        let savedDensity = CGFloat(defaults.double(forKey: BlockRenderer.densityKey))
        densityValue = savedDensity > 0
            ? min(max(savedDensity, BlockRenderer.minDensity), BlockRenderer.maxDensity) : 1

        if syncsRenderer {
            Self.apply(theme)
            BlockRenderer.contentWeight = contentWeight
            BlockRenderer.bracketsEnabled = showPageRefBrackets
            BlockRenderer.journalDateFormat = defaultDateFormat
            BlockRenderer.zoom = zoom
            BlockRenderer.density = density
        }
    }

    /// Imports the old per-graph theme exactly once. The first graph opened on
    /// launch wins; after this call the app-level key is authoritative.
    func migrateThemeIfNeeded(from legacyValue: String) {
        guard !themeWasSet else { return }
        theme = Theme(rawValue: legacyValue) ?? .system
        // Assigning `.system` to its existing value does not enter didSet's
        // persistence path, so mark even that migration as complete explicitly.
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        themeWasSet = true
    }

    /// Imports the old per-graph date format exactly once, like the theme above.
    func migrateDateFormatIfNeeded(from legacyValue: JournalDateFormat) {
        guard !dateFormatWasSet else { return }
        defaultDateFormat = legacyValue
        // Assigning the value it already holds skips didSet, so record the
        // migration explicitly.
        defaults.set(defaultDateFormat.pattern, forKey: Self.defaultDateFormatKey)
        dateFormatWasSet = true
        if syncsRenderer { BlockRenderer.journalDateFormat = defaultDateFormat }
    }

    private func setZoom(_ proposed: CGFloat) {
        let value = min(max(proposed, BlockRenderer.minZoom), BlockRenderer.maxZoom)
        guard value != zoomValue else { return }
        zoomValue = value
        defaults.set(Double(value), forKey: BlockRenderer.zoomKey)
        if syncsRenderer { BlockRenderer.zoom = value }
        renderRevision += 1
    }

    private func setDensity(_ proposed: CGFloat) {
        let value = min(max(proposed, BlockRenderer.minDensity), BlockRenderer.maxDensity)
        guard value != densityValue else { return }
        densityValue = value
        defaults.set(Double(value), forKey: BlockRenderer.densityKey)
        if syncsRenderer { BlockRenderer.density = value }
        renderRevision += 1
    }

    private static func apply(_ theme: Theme) {
        switch theme {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
