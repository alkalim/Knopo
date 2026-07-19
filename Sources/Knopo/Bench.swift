import AppKit
import SwiftUI
import KnopoCore

/// Headless performance harness (dev tool, not user-facing):
///
///     KNOPO_BENCH=1 KNOPO_GRAPH=/path/to/graph swift run Knopo
///
/// Hosts the real `PageScreen` in an offscreen window, finds the live outline
/// controller inside it, and times the hot paths: page open, the height pass,
/// reference queries, and the Enter (split) pipeline end-to-end — wall time for
/// the synchronous part, process-CPU during a run-loop pump for the async
/// SwiftUI/AppKit settle work. `KNOPO_BENCH_PAGE` picks the page (default Hub).
@MainActor
enum Bench {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["KNOPO_BENCH"] == "1" else { return }
        run()
        exit(0)
    }

    // MARK: - Timing utilities

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    @discardableResult
    private static func time<T>(_ label: String, _ body: () -> T) -> T {
        let start = ContinuousClock.now
        let result = body()
        report(label, ms(ContinuousClock.now - start))
        return result
    }

    private static func timed(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        return ms(ContinuousClock.now - start)
    }

    private static func report(_ label: String, _ milliseconds: Double, suffix: String = "") {
        let padded = (label + ":").padding(toLength: 44, withPad: " ", startingAt: 0)
        print(padded + String(format: "%8.1f ms", milliseconds) + suffix)
    }

    /// Process CPU time (user + system), for measuring async work during pumps.
    private static func cpuMS() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
        let s = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
        return u + s
    }

    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// CPU consumed while pumping the run loop — the async fallout of the last
    /// action (SwiftUI re-render, deferred layout), with idle pumping ≈ 0.
    private static func cpuDuringPump(_ seconds: Double) -> Double {
        let before = cpuMS()
        pump(seconds)
        return cpuMS() - before
    }

    private static func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let v = root as? T { return v }
        for sub in root.subviews {
            if let found = findView(type, in: sub) { return found }
        }
        return nil
    }

    // MARK: - The run

    private static func run() {
        let pageName = ProcessInfo.processInfo.environment["KNOPO_BENCH_PAGE"] ?? "Hub"
        _ = NSApplication.shared
        let root = GraphManager.defaultRoot()
        print("bench: graph \(root.path), page \(pageName)")

        var store: GraphStore!
        time("GraphStore init + index sync") { store = try! GraphStore(root: root) }
        let app = AppState(store: store)
        let nav = Navigator(app: app)

        // Host the real PageScreen (outline + references) at a realistic size.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: AnyView(
            PageScreen(pageName: pageName)
                .environmentObject(app)
                .environmentObject(nav)))
        time("PageScreen first layout (open page)") {
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
        }
        report("  async settle after open (CPU)", cpuDuringPump(1.0))

        guard let table = findView(OutlineTableView.self, in: hosting),
              let controller = table.delegate as? OutlineEditorController else {
            print("bench: outline table/controller not found — aborting")
            return
        }
        let rowCount = table.numberOfRows
        print("rows: \(rowCount)")

        time("heightOfRow × all rows (warm cache)") {
            for i in 0..<rowCount { _ = controller.tableView(table, heightOfRow: i) }
        }
        time("reloadData alone") { table.reloadData() }
        time("  hosting layout after reloadData") { hosting.layoutSubtreeIfNeeded() }
        report("  async settle after reload (CPU)", cpuDuringPump(0.5))
        let materialized = (0..<rowCount).filter {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil
        }.count
        print("materialized cells: \(materialized) of \(rowCount)")

        // The debounced-save pipeline (serialize + write + reindex + dataVersion
        // bump) and the SwiftUI re-render it triggers, measured separately.
        let docBefore = app.document(for: pageName)
        app.commit(docBefore)
        time("flushPendingSaves (write + reindex page)") { app.flushPendingSaves() }
        report("  async settle after save (CPU)", cpuDuringPump(0.5))
        // Components of that save. The scan probe runs first (clean stamps →
        // pure scan cost); the nil-stamp indexPage probe invalidates Hub's
        // stamp, so an untimed scan afterwards restores consistency (it reloads
        // and reindexes Hub), and a dataVersion bump + pump lets the outline
        // rebuild its rows from the fresh parse (block ids re-mint).
        time("  PageSerializer.serialize") {
            _ = PageSerializer.serialize(preamble: docBefore.preamble, blocks: docBefore.blocks)
        }
        time("  handleExternalChanges (watcher scan)") {
            _ = try? store.handleExternalChanges()
        }
        time("  cache.indexPage (delete + reinsert)") {
            try? store.cache.indexPage(docBefore, stamp: nil)
        }
        _ = try? store.handleExternalChanges()
        app.dataVersion += 1
        pump(0.5)
        time("dataVersion bump → hosting relayout") {
            app.dataVersion += 1
            hosting.layoutSubtreeIfNeeded()
        }
        report("  async settle after bump (CPU)", cpuDuringPump(0.5))

        time("cache.backlinks") { _ = try? store.cache.backlinks(of: PageName.key(pageName)) }
        time("cache.hasUnlinkedReferences") {
            _ = try? store.cache.hasUnlinkedReferences(toPageNamed: pageName)
        }
        time("cache.unlinkedReferences (full scan)") {
            _ = try? store.cache.unlinkedReferences(toPageNamed: pageName)
        }

        // The Enter path, end to end, on the real controller: focus a mid-page
        // block, then split repeatedly. Wall time is the synchronous pipeline
        // (split op + rebuildRows + reloadData + attachEditor); the pump CPU is
        // the asynchronous SwiftUI/AppKit follow-up each split triggers.
        let doc = app.document(for: pageName)
        let all = doc.blocks.flattened
        guard all.count > 8 else { print("bench: page too small"); return }
        // A block near the top so its row is inside the materialized viewport —
        // the visual check below needs a live cell, like a user editing what
        // they see. Row index == flattened index (preorder, nothing collapsed).
        let targetRow = 5
        let target = all[targetRow]

        // Visual state of one row: (renderedView hidden?, its text) — nil when
        // the cell isn't materialized.
        func renderedState(atRow row: Int) -> (hidden: Bool, text: String)? {
            guard row < table.numberOfRows,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
                  let rendered = findView(RenderedTextView.self, in: cell) else { return nil }
            return (rendered.isHidden, rendered.textStorage?.string ?? "")
        }
        func describe(_ s: (hidden: Bool, text: String)?) -> String {
            guard let s else { return "no cell" }
            return "hidden=\(s.hidden) text=\"\(s.text.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))\""
        }

        let beforeFocus = renderedState(atRow: targetRow)
        print("target row before focus: " + describe(beforeFocus))
        time("focusBlock (attach editor)") {
            controller.focusBlock(target.id, selection: NSRange(location: 0, length: 0))
        }
        report("  async settle after focus (CPU)", cpuDuringPump(0.5))

        func cellPointer(atRow row: Int) -> String {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                return "nil"
            }
            return "\(Unmanaged.passUnretained(cell).toOpaque())"
        }
        print("cell ptrs before split: r5=\(cellPointer(atRow: targetRow))")
        controller.editorSplit(atUTF16Offset: 999_999)
        print("right after split (no pump): " + describe(renderedState(atRow: targetRow))
              + "  r5=\(cellPointer(atRow: targetRow)) r6=\(cellPointer(atRow: targetRow + 1))")
        pump(0.2)
        print("cell ptrs after pump: r5=\(cellPointer(atRow: targetRow)) r6=\(cellPointer(atRow: targetRow + 1))")
        // Regression check (text vanished on Enter): after splitting at the end
        // of the target block, its row must show the same rendered text it
        // showed before focusing.
        let afterSplit = renderedState(atRow: targetRow)
        print("target row after split:  " + describe(afterSplit))
        print("new row after split:     " + describe(renderedState(atRow: targetRow + 1)))
        let ok = afterSplit.map { !$0.hidden && $0.text == (beforeFocus?.text ?? "") } ?? false
        print("visual check after Enter-at-end: \(ok ? "PASS" : "FAIL")")

        // Second scenario: TYPE into the focused block, then Enter. The edited
        // row's render changes, so the diff reloads the very row hosting the
        // live editor — the reentrancy / focus-loss hazard the plain split
        // doesn't cover. (The editor now sits on the empty block from the
        // split above; give it content, then split again.)
        controller.editorTextDidChange("typed benchmark text")
        pump(0.1)
        controller.editorSplit(atUTF16Offset: 999_999)
        pump(0.2)
        let typedRow = renderedState(atRow: targetRow + 1)
        print("typed row after split:   " + describe(typedRow))
        let ok2 = typedRow.map { !$0.hidden && $0.text.contains("typed benchmark text") } ?? false
        print("visual check type-then-Enter: \(ok2 ? "PASS" : "FAIL")")

        var walls: [Double] = []
        var uiSettles: [Double] = []
        var saveSettles: [Double] = []
        for i in 1...15 {
            // A huge offset clamps to the end of the block's content — Enter
            // at end of line, the common case.
            let wall = timed { controller.editorSplit(atUTF16Offset: 999_999) }
            // Below the 0.3s save debounce: pure UI fallout of the split.
            let ui = cpuDuringPump(0.15)
            // Long enough for the debounced save + reindex + dataVersion
            // re-render to land.
            let save = cpuDuringPump(0.6)
            walls.append(wall)
            uiSettles.append(ui)
            saveSettles.append(save)
            report("editorSplit #\(String(format: "%02d", i))", wall,
                   suffix: String(format: "  (+%5.1f ui, +%5.1f save/re-render CPU)",
                                  ui, save))
        }
        report("editorSplit median wall", walls.sorted()[walls.count / 2])
        report("editorSplit median ui CPU", uiSettles.sorted()[uiSettles.count / 2])
        report("editorSplit median save CPU", saveSettles.sorted()[saveSettles.count / 2])
        print("bench: done")
    }
}
