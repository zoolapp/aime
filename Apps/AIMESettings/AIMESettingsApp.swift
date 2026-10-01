import AIMEAI
import AppKit
import SwiftUI

@main
struct AIMESettingsApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var appDelegate
    @State private var model = SettingsModel()

    init() {
        Self.migrateLegacyDefaults()
        // The API key used to live in the login Keychain, which made macOS ask for the
        // password when the input method read it. It now lives in an owner-only file.
        CredentialStore(account: "openai-compatible").migrateFromKeychain()
        switch LaunchOptions.argument("--appearance") {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    var body: some Scene {
        Window("艾么输入法设置", id: "main") {
            // The settings layout needs 900 × 620; onboarding sizes the window per step.
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 720)
        // A settings app must always open its window: never restore a "closed" state.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("部署") {
                Button("重新部署") { Task { await model.deploy() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

extension AIMESettingsApp {
    /// Preferences written under the previous bundle id (dev.luolei.aime.settings) are
    /// copied once into app.zool.aime.settings.
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLegacyBundleID"),
              let legacy = UserDefaults(suiteName: "dev.luolei.aime.settings")?.persistentDomain(forName: "dev.luolei.aime.settings")
        else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromLegacyBundleID")
    }
}

/// Reopens the settings window when the Dock icon is clicked with no window open,
/// and quits when the last window closes (it is a single-window utility).
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
