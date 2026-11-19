import Foundation
import Testing
import KnopoCore
@testable import Knopo

@Suite struct FavouriteDragTests {
    @Test func dropPositionUsesRowMidpointsAndRejectsNoOps() {
        let items: [Favourite] = [.page("A"), .tag("A"), .page("C")]
        let frames: [Favourite: CGRect] = [
            .page("A"): CGRect(x: 10, y: 20, width: 100, height: 28),
            .tag("A"): CGRect(x: 10, y: 56, width: 100, height: 28),
            .page("C"): CGRect(x: 10, y: 92, width: 100, height: 28)
        ]
        func destination(_ y: CGFloat, x: CGFloat = 20) -> Int? {
            FavouriteDrag(source: .tag("A"), location: CGPoint(x: x, y: y))
                .destination(in: items, frames: frames)
        }

        #expect(destination(21) == 0)
        #expect(destination(116) == 3)
        #expect(destination(54) == nil)
        #expect(destination(75) == nil)
        #expect(destination(130) == nil)
        #expect(destination(21, x: 120) == nil)
    }

    @MainActor
    @Test func tagMovesBetweenPagesAndKeepsHiddenFavourites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }

        let pages = (1...17).map { "Page \($0)" }
        try store.updateConfig {
            $0.orderedFavourites = pages.map(Favourite.page) + [.tag("one"), .tag("two")]
        }
        let visible = app.store.config.orderedFavourites(limitPerKind: 15)
        #expect(visible == pages.prefix(15).map(Favourite.page) + [.tag("one"), .tag("two")])
        try app.moveFavourites(visible, from: IndexSet(integer: 16), to: 1)

        let saved = GraphConfig.load(from: store.configURL)
        #expect(saved.favourites == pages)
        #expect(saved.favouriteTags == ["two", "one"])
        #expect(Array(saved.orderedFavourites.prefix(3)) == [.page("Page 1"), .tag("two"), .page("Page 2")])
        #expect(app.store.config.orderedFavourites(limitPerKind: 15).last == .tag("one"))
    }
}
