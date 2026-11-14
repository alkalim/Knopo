import AppKit
import Foundation
import Testing
@testable import Knopo
import KnopoCore

/// Opt-in measurements of the focused editor, including its controller callbacks.
@MainActor
@Suite struct TypingCostBenchmark {
    private func median(_ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil),
          arguments: ["", "]]", "]("])
    func longBracketTyping(suffix: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-typing-bench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Typing Bench")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.initialLayoutWidth = 760
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
        scroll.documentView = controller.tableView
        controller.tableView.frame.size = scroll.bounds.size
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.title = "Knopo Typing Benchmark"
        window.contentView = scroll
        defer { window.contentView = nil }
        defer { controller.endEditing() }
        let detached = BlockEditorTextView.create()
        var typingTimes: [Double] = []
        for count in [2_048, 4_096, 8_192] {
            let source = String(repeating: "[", count: count) + suffix
            let parse = median { _ = InlineParser.parseSpans(source) }
            let highlighting = median { detached.setContent(source) }
            let measure = median { _ = BlockEditorTextView.measureHeight(for: source, width: 700) }

            controller.endEditing()
            page.blocks = [Block(content: source)]
            store.updatePage(page)
            controller.present(pageName: page.name, zoom: nil)
            window.layoutIfNeeded()
            controller.focusBlock(page.blocks[0].id,
                                  selection: NSRange(location: source.utf16.count, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "x",
                charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
            let typing = median {
                editor.keyDown(with: event)
                window.layoutIfNeeded()
            }
            #expect(editor.string == source + String(repeating: "x", count: 6))
            #expect(app.document(for: page.name).blocks[0].content == editor.string)
            typingTimes.append(typing)
            print(String(format: "TYPING BENCH [%@ %d: parse %.3f ms, highlight %.3f ms, measure %.3f ms, keyDown %.3f ms",
                         suffix, count, parse, highlighting, measure, typing))
        }
        let growth = typingTimes[2] / max(typingTimes[1], 0.001)
        print(String(format: "TYPING BENCH [%@: final doubling %.2fx", suffix, growth))
        #expect(growth < 3.5, "Typing into malformed brackets should not approach quadratic growth")
    }
}
