import AppKit
import Foundation
import Testing
@testable import Knopo
import KnopoCore

/// Where a large page's editing time goes. Not an assertion — it prints a table,
/// and is skipped unless `KNOPO_BENCH` is set, so the ordinary suite stays quiet:
///
///     KNOPO_BENCH=1 ./scripts/test.sh -c release --filter EditCostBenchmark
///
/// Run it in *release*: half the index cost is Swift (`RefExtractor`), which a
/// debug build inflates several-fold. Worth re-running on any macOS version that
/// feels slower — the TextKit rows (render/measure) are framework-bound, and are
/// the numbers that move between OS releases.
@MainActor
@Suite struct EditCostBenchmark {

    @discardableResult
    private func time(_ label: String, _ body: () -> Void) -> Double {
        let start = Date()
        body()
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "  %-34@ %8.2f ms", label as NSString, ms))
        return ms
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil))
    func costByPageSize() throws {
        for count in [200, 1_000, 3_000] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("knopo-bench-\(count)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try GraphStore(root: root)
            let name = "Bench"
            var doc = try store.createPage(named: name)
            doc.blocks = (0..<count).map {
                Block(content: "Block \($0) — some text with a [[Link]] and a #tag in it")
            }
            store.updatePage(doc)
            try store.savePage(named: name)

            print("\n=== \(count) blocks ===")
            let app = AppState(store: store)
            defer { app.shutdown() }

            // Per keystroke.
            time("keystroke: doc + edit + commit") {
                var edited = app.document(for: name)
                guard let path = edited.blocks.path(to: edited.blocks[0].id) else { return }
                edited.blocks.update(at: path) { $0.content += "x" }
                app.commit(edited)
            }
            // Once per pause in typing (the 300 ms save debounce), on the main thread.
            let serialize = time("serialize whole page") {
                _ = PageSerializer.serialize(preamble: doc.preamble, blocks: doc.blocks)
            }
            let save = time("savePage (serialize+write+index)") {
                try? store.savePage(named: name)
            }
            print(String(format: "  %-34@ %8.2f ms",
                         "  …of which: write + index" as NSString, save - serialize))
            let blocks = doc.blocks
            time("  …of which: RefExtractor") {
                for block in blocks { _ = RefExtractor.extract(from: block.content) }
            }
            // Once per full rebuild: opening the page, and every width change.
            time("render every block") {
                for block in blocks {
                    _ = BlockRenderer.render(content: block.content,
                                             context: BlockRenderer.Context(
                                                journalDateFormat: .default))
                }
            }
            let rendered = blocks.map {
                BlockRenderer.render(
                    content: $0.content,
                    context: BlockRenderer.Context(journalDateFormat: .default))
            }
            time("measure every row height") {
                for attributed in rendered {
                    _ = OutlineRowCell.height(for: attributed, contentWidth: 700)
                }
            }
        }
    }

    /// Why the index opens as a WAL pool: with one serialized connection a UI
    /// read waits out a running page reindex. This measures that wait directly —
    /// reads issued from the caller's thread while a background writer reindexes
    /// a 3000-block page.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil))
    func readLatencyDuringBackgroundIndexWrite() throws {
        for allowWAL in [true, false] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("knopo-readlat-\(allowWAL)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try CacheDB(
                url: root.appendingPathComponent("cache.db"), allowWAL: allowWAL)
            var page = PageDocument(
                name: "Bench",
                blocks: (0..<3_000).map {
                    Block(content: "Block \($0) — text with a [[Link]] and a #tag in it")
                },
                isJournal: false, fileExists: true)
            try cache.indexPage(page, stamp: nil)

            // A second version to write, so the reindex has real work to do.
            page.blocks[0].content += " edited"
            let writer = DispatchQueue(label: "bench.index-write", qos: .utility)
            let finished = DispatchSemaphore(value: 0)
            var writeMS = 0.0
            let started = Date()
            writer.async {
                try? cache.indexPage(page, stamp: nil)
                writeMS = Date().timeIntervalSince(started) * 1000
                finished.signal()
            }
            var latencies: [Double] = []
            while finished.wait(timeout: .now()) == .timedOut {
                let mark = Date()
                _ = try? cache.searchBlocks("Block", limit: 5)
                latencies.append(Date().timeIntervalSince(mark) * 1000)
            }
            let worst = latencies.max() ?? 0
            let median = latencies.sorted()[latencies.count / 2]
            print(String(
                format: "  WAL=%@  write %6.1f ms   reads %4d   worst read %7.2f ms   median %5.2f ms",
                allowWAL ? "yes" : "no ", writeMS, latencies.count, worst, median))
        }
    }
}
