import Foundation
import UserNotifications

// ─────────────────────────────────────────────────────────────────
// Posting threshold alerts as macOS notifications.
//
// Why bother, when the menu bar already grows a badge: fullscreen.
// The menu bar is hidden entirely in fullscreen apps, so the badge
// and the readout strip are both invisible at exactly the moment a
// thermal or memory problem is most likely and least visible. A
// notification is the only channel that still reaches the screen.
//
// One hazard worth knowing about. `UNUserNotificationCenter.current()`
// raises if the running binary has no bundle identifier, which is
// exactly the case in this project's own dev loop:
//
//     swift build -c release && .build/release/MacUsage &
//
// That runs the bare executable, not the .app. So every entry point
// here checks for a bundle identifier first and does nothing without
// one. Notifications simply do not exist in that mode, which is
// preferable to a crash on the first hot minute.
// ─────────────────────────────────────────────────────────────────

enum AlertNotifier {

    /// False when running as a bare binary rather than an app bundle.
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Ask for permission. Called when the user switches notifications
    /// on, so the prompt arrives right after they asked for them
    /// rather than ambushing them mid-task when a threshold trips.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                // Declining is a valid answer. The badge and the panel
                // banner still report everything.
            }
    }

    /// Post one notification per newly firing alert.
    static func post(_ alerts: [StatAlert]) {
        guard isAvailable, !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = "Mac Usage"
                content.body = alert.message
                content.sound = .default

                // The rule id as the request id means a rule that
                // fires again replaces its own older notification
                // instead of stacking a pile of near-identical ones.
                let request = UNNotificationRequest(
                    identifier: alert.id,
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }
        }
    }
}
