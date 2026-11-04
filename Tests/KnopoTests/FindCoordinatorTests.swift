import AppKit
import Testing
@testable import Knopo

@MainActor
@Suite struct FindCoordinatorTests {
    private final class Participant: FindParticipant {
        let findSortKey: CGFloat
        var updates = 0
        var reveals = 0
        var current: Int?
        var cleared = false

        init(_ position: CGFloat) { findSortKey = position }
        func findUpdate(query: String) -> Int { updates += 1; return 3 }
        func findSetCurrent(_ localIndex: Int?, reveal: Bool) {
            current = localIndex
            if reveal, localIndex != nil { reveals += 1 }
        }
        func findClear() { cleared = true; current = nil }
    }

    @Test func scrollingPreservesCurrentMatchWithoutRevealingIt() {
        let find = FindCoordinator()
        let reading = Participant(100)
        find.register(reading)
        find.sync(active: true, query: "entry", stepToken: 0, forward: true)
        find.sync(active: true, query: "entry", stepToken: 1, forward: true)
        #expect(reading.current == 1)
        let reveals = reading.reveals

        let above = Participant(200)
        find.register(above)
        #expect(reading.current == 1)
        #expect(reading.updates == 1)
        #expect(reading.reveals == reveals)
        #expect(above.current == nil)
        #expect(above.reveals == 0)
        find.unregister(above)
        #expect(above.cleared)
        #expect(reading.current == 1)
        #expect(reading.updates == 1)
        #expect(reading.reveals == reveals)

        let below = Participant(0)
        find.register(below)
        find.unregister(reading)
        #expect(reading.cleared)
        #expect(below.current == 0)
        #expect(below.reveals == 0)
        find.sync(active: true, query: "entry", stepToken: 2, forward: true)
        #expect(below.current == 1)
        #expect(below.reveals == 1)
    }
}
