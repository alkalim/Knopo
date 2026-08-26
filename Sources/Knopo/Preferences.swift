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

        var title: String { rawValue.capitalized }
    }

    static let standard = Preferences()

    static let themeKey = "appearanceTheme"
    static let defaultDateFormatKey = "defaultJournalDateFormat"

    private let defaults: UserDefaults
    private let syncsRenderer: Bool
    private var themeWasSet: Bool

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

    @Published var defaultDateFormat: JournalDateFormat {
        didSet {
            guard defaultDateFormat != oldValue else { return }
            defaults.set(defaultDateFormat.pattern, forKey: Self.defaultDateFormatKey)
        }
    }

    @Published var zoom: CGFloat {
        didSet {
            let clamped = min(max(zoom, BlockRenderer.minZoom), BlockRenderer.maxZoom)
            if clamped != zoom { zoom = clamped; return }
            guard zoom != oldValue else { return }
            defaults.set(Double(zoom), forKey: BlockRenderer.zoomKey)
            if syncsRenderer { BlockRenderer.zoom = zoom }
            renderRevision += 1
        }
    }

    @Published var density: CGFloat {
        didSet {
            let clamped = min(max(density, BlockRenderer.minDensity), BlockRenderer.maxDensity)
            if clamped != density { density = clamped; return }
            guard density != oldValue else { return }
            defaults.set(Double(density), forKey: BlockRenderer.densityKey)
            if syncsRenderer { BlockRenderer.density = density }
            renderRevision += 1
        }
    }

    /// Bumped for preferences that require cached attributed strings and row
    /// measurements to be rebuilt in every open graph.
    @Published private(set) var renderRevision = 0

    init(defaults: UserDefaults = .standard, syncsRenderer: Bool = true) {
        self.defaults = defaults
        self.syncsRenderer = syncsRenderer
        themeWasSet = defaults.object(forKey: Self.themeKey) != nil
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
        zoom = savedZoom > 0
            ? min(max(savedZoom, BlockRenderer.minZoom), BlockRenderer.maxZoom) : 1
        let savedDensity = CGFloat(defaults.double(forKey: BlockRenderer.densityKey))
        density = savedDensity > 0
            ? min(max(savedDensity, BlockRenderer.minDensity), BlockRenderer.maxDensity) : 1

        if syncsRenderer {
            Self.apply(theme)
            BlockRenderer.contentWeight = contentWeight
            BlockRenderer.bracketsEnabled = showPageRefBrackets
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
