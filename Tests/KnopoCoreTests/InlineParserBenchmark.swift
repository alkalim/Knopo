import Foundation
import Testing
@testable import KnopoCore

/// Opt-in scaling checks. Run in release with `scripts/benchmark.sh`, or:
/// KNOPO_BENCH=1 ./scripts/test.sh -c release --filter InlineParserBenchmark
@Suite struct InlineParserBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil))
    func autolinkScaling() {
        let inputs: [(label: String, make: (Int) -> String, spanCount: Int)] = [
            ("ordinary prose", { String(repeating: "world ", count: $0) }, 1),
            ("h-word prose", { String(repeating: "hello ", count: $0) }, 1),
            // Larger tails keep the final timing samples above submillisecond noise.
            ("URL parentheses", { "https://example.com/a_(b)" + String(repeating: ")", count: $0 * 8) }, 2),
        ]
        for input in inputs {
            var timings: [Double] = []
            for count in [512, 1_024, 2_048, 4_096] {
                let source = input.make(count)
                expectEqual(InlineParser.parseSpans(source).count, input.spanCount)
                var samples: [Double] = []
                var spanCount = 0
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    spanCount = InlineParser.parseSpans(source).count
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                expectEqual(spanCount, input.spanCount)
                let median = samples.sorted()[samples.count / 2]
                timings.append(median)
                print(String(format: "PARSER BENCH %@: %d characters, median %.3f ms",
                             input.label, source.count, median))
            }
            // Use the largest inputs to reduce timer and fixed-cost noise.
            let growth = timings[3] / max(timings[2], 0.001)
            print(String(format: "PARSER BENCH %@: final doubling %.2fx", input.label, growth))
            expectTrue(growth < 3.5, "\(input.label) should not approach quadratic growth")
        }
    }
}
