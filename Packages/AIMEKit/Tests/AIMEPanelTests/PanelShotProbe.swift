import AppKit
import Testing
@testable import AIMECore
@testable import AIMEPanel

@MainActor
@Suite(.serialized)
struct PanelShotProbe {
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)]) func shot(translucent: Bool, dark: Bool) async throws {
        guard ProcessInfo.processInfo.environment["AIME_PANEL_SHOTS"] != nil else { return }
        let out = ProcessInfo.processInfo.environment["AIME_PANEL_SHOTS"]!
        let panel = CandidatePanel()
        var theme = PanelTheme(frontend: PanelTests.frontend, dark: dark)
        theme.translucency = translucent
        panel.theme = theme
        let screen = NSScreen.main!.frame
        let cursor = NSRect(x: 300, y: screen.height - 300, width: 1, height: 18)
        panel.show(.sample, at: cursor)
        try await Task.sleep(for: .milliseconds(150))
        panel.show(PanelState(candidates: [.init(label: "1", text: "你好"), .init(label: "2", text: "拟好")]), at: cursor)
        try await Task.sleep(for: .milliseconds(400))
        let name = "\(out)/panel-\(translucent ? "blur" : "solid")-\(dark ? "dark" : "light")"
        for (suffix, state) in [("short", PanelState?.none), ("long", PanelState.sample)] {
            if let state { panel.show(state, at: cursor); try await Task.sleep(for: .milliseconds(400)) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "270,260,560,110", "\(name)-\(suffix).png"]
            try p.run(); p.waitUntilExit()
        }
        panel.hide()
    }
}
