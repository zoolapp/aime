import AppKit
import QuartzCore
import Testing
@testable import AIMECore
@testable import AIMEPanel

/// Main-thread cost of one keystroke's panel update (layout + layers + commit),
/// with motion on and off. Prints percentiles; the budget is loose for debug builds.
@MainActor
@Suite(.serialized)
struct PanelPerformanceTests {
    @Test(arguments: [false, true]) func keystrokeUpdateIsCheap(animated: Bool) async {
        let panel = CandidatePanel()
        panel.animationsEnabled = animated
        var theme = PanelTheme(frontend: PanelTests.frontend, dark: false)
        theme.translucency = true
        panel.theme = theme
        let words = ["你", "你好", "你好世界", "你好世界啊", "拟好", "你好是", "你好世界上最好的"]
        let cursor = NSRect(x: 400, y: 600, width: 1, height: 18)
        var samples: [Double] = []
        for i in 0..<200 {
            let count = 3 + (i % 5)
            let candidates = (0..<count).map { PanelState.Candidate(label: "\($0 + 1)", text: words[($0 + i) % words.count]) }
            let start = CACurrentMediaTime()
            panel.show(PanelState(candidates: candidates, highlightedIndex: i % count), at: cursor)
            CATransaction.flush()
            samples.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(12))
        }
        panel.hide()
        samples.sort()
        let p50 = samples[samples.count / 2], p90 = samples[samples.count * 9 / 10]
        print("panel update animated=\(animated) p50=\(String(format: "%.2f", p50))ms p90=\(String(format: "%.2f", p90))ms max=\(String(format: "%.2f", samples.last!))ms")
        #expect(p50 < 8)
    }
}
