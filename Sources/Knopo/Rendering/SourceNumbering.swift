import Foundation
import KnopoCore

/// All surfaces share the store's source labels and one set of measured widths.
@MainActor
struct SourceNumbering {
    var markers: [UUID: OutlineNumbering.Marker]
    var widths: [UUID: CGFloat]

    struct Cached {
        var snapshot: OutlineNumbering.Snapshot
        var typography: String
        var value: SourceNumbering
    }

    init(app: AppState, page: String) {
        self.init(app: app, canonicalPage: app.store.canonicalPageName(for: page))
    }

    init(app: AppState, canonicalPage page: String) {
        let key = PageName.key(page)
        let snapshot = (try? app.store.numbering(onCanonicalPageNamed: page)) ?? OutlineNumbering.Snapshot(blocks: [])
        let typography = OutlineMarkerLayout.typographyKey
        if let cached = app.sourceNumberingCache[key], cached.snapshot === snapshot,
           cached.typography == typography {
            self = cached.value
            return
        }
        markers = snapshot.markers
        let runs = OutlineMarkerLayout.runWidths(markers)
        widths = markers.mapValues { runs[$0.runID] ?? OutlineMarkerLayout.minimumSlot }
        // Loaded pages keep their semantic snapshots in GraphStore. This cache
        // only saves font measurements for recently displayed pages.
        if app.sourceNumberingCache.count >= 128 { app.sourceNumberingCache.removeAll(keepingCapacity: true) }
        app.sourceNumberingCache[key] = Cached(snapshot: snapshot, typography: typography, value: self)
    }
}
