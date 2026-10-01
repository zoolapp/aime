import AppKit
import InputMethodKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputEngine.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RimeKitShutdown.finalize()
    }
}

import RimeKit

enum RimeKitShutdown {
    @MainActor static func finalize() {
        RimeEngine.shared.cleanupAllSessions()
        RimeEngine.shared.finalize()
    }
}
