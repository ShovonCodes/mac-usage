import Foundation
import ServiceManagement

// ─────────────────────────────────────────────────────────────────
// Start-at-login via SMAppService (the modern macOS 13+ login-item
// API — no AppleScript, no permission prompts, and the entry shows
// up in System Settings → General → Login Items like any other app).
//
// Everything goes through here: the Settings switch in the panel,
// and the install/uninstall scripts via the app's `--set-login`
// launch flag — SMAppService only lets an app register its own
// bundle, so scripts can't do it directly.
// ─────────────────────────────────────────────────────────────────

enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns false when macOS refuses the change (e.g. the binary is
    /// running outside an app bundle during development), so callers
    /// can leave their UI untouched.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            // Unregistering something that was never registered is a
            // success as far as the caller cares.
            return !enabled && SMAppService.mainApp.status == .notRegistered
        }
    }
}
