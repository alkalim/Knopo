import AppKit

/// An outline that can participate in window-wide in-page find. The journal
/// home has several (one per day); a page has one.
@MainActor
protocol FindParticipant: AnyObject {
    /// Ordering key — larger is higher on screen (window coordinates).
    var findSortKey: CGFloat { get }
    /// Recompute local matches for `query`; return the match count, clear current.
    func findUpdate(query: String) -> Int
    /// Mark which local match (if any) is the window-global current one:
    /// highlight it and optionally scroll it into view.
    func findSetCurrent(_ localIndex: Int?, reveal: Bool)
    /// Drop all find highlighting.
    func findClear()
}

/// Per-window find coordinator (Cmd+F). Aggregates matches across every
/// registered outline so counting and next/previous span the whole view —
/// e.g. across all journal days — not just one outline.
@MainActor
final class FindCoordinator {
    weak var nav: Navigator?

    private final class Box { weak var value: FindParticipant?; init(_ v: FindParticipant) { value = v } }
    private var boxes: [Box] = []

    private var active = false
    private var query = ""
    private var ordered: [FindParticipant] = []   // sorted at last recompute
    private var counts: [Int] = []                // per `ordered`, same order
    private var globalIndex = 0
    private var lastStepToken = 0

    func register(_ p: FindParticipant) {
        boxes.removeAll { $0.value == nil }
        guard !boxes.contains(where: { $0.value === p }) else { return }
        boxes.append(Box(p))
        if active { updateParticipants() }
    }

    func unregister(_ p: FindParticipant) {
        boxes.removeAll { $0.value == nil || $0.value === p }
        p.findClear()
        if active { updateParticipants() }
    }

    /// Driven from the outline's updateNSView. Dedupes by query/step token, so
    /// it's safe that several outlines call it in one update cycle.
    func sync(active: Bool, query: String, stepToken: Int, forward: Bool) {
        if !active {
            if self.active { self.active = false; self.query = ""; clearAll() }
            lastStepToken = stepToken
            return
        }
        let queryChanged = !self.active || query != self.query
        self.active = true
        self.query = query
        if queryChanged {
            recompute()
        } else if stepToken != lastStepToken {
            step(forward: forward)
        }
        lastStepToken = stepToken
    }

    private func live() -> [FindParticipant] { boxes.compactMap { $0.value } }

    private func recompute() {
        ordered = live().sorted { $0.findSortKey > $1.findSortKey }
        counts = ordered.map { $0.findUpdate(query: query) }
        globalIndex = 0
        applyCurrent()
    }

    /// Scrolling changes membership without starting a new search or revealing a match.
    private func updateParticipants() {
        var current: FindParticipant?
        var local = globalIndex
        for (participant, count) in zip(ordered, counts) {
            if local < count { current = participant; break }
            local -= count
        }
        let oldCounts = Dictionary(uniqueKeysWithValues: zip(ordered.map(ObjectIdentifier.init), counts))
        ordered = live().sorted { $0.findSortKey > $1.findSortKey }
        counts = ordered.map { oldCounts[ObjectIdentifier($0)] ?? $0.findUpdate(query: query) }
        if let current, let index = ordered.firstIndex(where: { $0 === current }) {
            globalIndex = counts.prefix(index).reduce(0, +) + local
        } else {
            globalIndex = 0
        }
        applyCurrent(reveal: false)
    }

    private func step(forward: Bool) {
        let total = counts.reduce(0, +)
        guard total > 0 else { return }
        globalIndex = ((globalIndex + (forward ? 1 : -1)) % total + total) % total
        applyCurrent()
    }

    private func applyCurrent(reveal: Bool = true) {
        let total = counts.reduce(0, +)
        var remaining = globalIndex
        var ownerIdx = -1, local = -1
        if total > 0 {
            for (i, c) in counts.enumerated() {
                if remaining < c { ownerIdx = i; local = remaining; break }
                remaining -= c
            }
        }
        for (i, p) in ordered.enumerated() {
            p.findSetCurrent(i == ownerIdx ? local : nil, reveal: reveal)
        }
        report(count: total, ordinal: total == 0 ? 0 : globalIndex + 1)
    }

    private func clearAll() {
        for p in live() { p.findClear() }
        ordered = []; counts = []; globalIndex = 0
        report(count: 0, ordinal: 0)
    }

    /// @Published writes must not happen during a SwiftUI view update.
    private func report(count: Int, ordinal: Int) {
        DispatchQueue.main.async { [weak nav] in
            nav?.findMatchCount = count
            nav?.findOrdinal = ordinal
        }
    }
}
