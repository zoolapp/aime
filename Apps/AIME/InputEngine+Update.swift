import AIMECore
import AppKit
@preconcurrency import UserNotifications

/// Daily update check from the input method. Only the public manifest
/// (get.zool.app/aime/latest.json) is requested; it runs off the keystroke path and
/// never carries anything typed. A new version is announced once with a quiet
/// (provisional) notification and an entry in the input menu; installing happens in
/// AIME Settings.
extension InputEngine {
    func checkForAppUpdate() {
        let state = AppUpdateState.load(paths)
        guard state.isDue(), AppVersion.isDistributionBuild() else { return }
        let paths = paths
        let current = AppVersion.current()
        Task.detached(priority: .utility) {
            let announced = AppUpdateState.load(paths).available?.appVersion.description
            guard let release = try? await AppUpdateChecker().check(paths: paths, current: current) else { return }
            guard release.appVersion.description != announced else { return }
            await MainActor.run { InputEngine.shared.announceUpdate(release) }
        }
    }

    /// The release to offer in the input menu, if any.
    var pendingUpdate: AppRelease? {
        AppVersion.isDistributionBuild() ? AppUpdateState.load(paths).pending(current: .current()) : nil
    }

    private func announceUpdate(_ release: AppRelease) {
        guard AppUpdateState.load(paths).pending(current: .current()) == release else { return }
        logger.info("update available: \(release.appVersion.description, privacy: .public)")
        let center = UNUserNotificationCenter.current()
        center.delegate = UpdateNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "艾么输入法有新版本")
            content.body = String(localized: "\(release.version) 已发布，打开设置即可更新。")
            center.add(UNNotificationRequest(identifier: "app.zool.aime.update", content: content, trigger: nil))
        }
    }
}

/// Opens the update card in Settings when the notification is clicked.
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = UpdateNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AIMEInputController.openSettings(pane: "overview") }
    }
}
