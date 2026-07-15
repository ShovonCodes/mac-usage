import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// App entry point.
//
// MenuBarExtra puts the app in the macOS menu bar (no Dock icon,
// no regular window). Clicking the icon opens StatsPanelView.
// ─────────────────────────────────────────────────────────────────

@main
struct MacUsageApp: App {

    /// Owns all stats and the refresh timer; shared with every view.
    @StateObject private var statsStore = StatsStore()

    init() {
        // Hide the Dock icon — this app lives only in the menu bar.
        // (Needed because we run as a plain binary without an app
        // bundle's Info.plist where LSUIElement would normally go.)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Mac Usage", systemImage: "gauge.medium") {
            StatsPanelView()
                .environmentObject(statsStore)
        }
        // .window style = a rich SwiftUI panel (like iStat Menus),
        // instead of a plain text menu.
        .menuBarExtraStyle(.window)
    }
}
