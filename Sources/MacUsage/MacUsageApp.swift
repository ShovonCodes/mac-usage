import SwiftUI
import AppKit
import Combine

// ─────────────────────────────────────────────────────────────────
// App entry point.
//
// The app owns its NSStatusItem and stats panel directly instead of
// using SwiftUI's MenuBarExtra: MenuBarExtra places its window
// edge-aligned to the icon on every open and only lets us correct
// it after the wrong frame is on screen (a visible flicker). With
// our own panel, the centered frame is computed before the panel is
// ever shown.
// ─────────────────────────────────────────────────────────────────

@main
struct MacUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All real UI lives in the status item panel the delegate owns.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Posted just before the panel hides so views can clean up
    /// (collapse hover details) — they never see onDisappear because
    /// the hosting view stays alive between opens.
    static let panelWillHide = Notification.Name("MacUsagePanelWillHide")

    private let statsStore = StatsStore()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>!
    private var clickOutsideMonitor: Any?
    private var alertSubscription: AnyCancellable?

    /// Gap between the menu bar and the top of the panel.
    private let menuBarGap: CGFloat = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the Dock icon — this app lives only in the menu bar.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.toolTip = "Mac Usage"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        hostingView = NSHostingView(
            rootView: AnyView(StatsPanelView().environmentObject(statsStore))
        )
        panel = FloatingPanel.make(wrapping: hostingView)

        // Swap the icon to the red-badged attention glyph whenever any
        // threshold alert is firing; the tooltip names the reasons.
        alertSubscription = statsStore.$activeAlerts
            .removeDuplicates()
            .sink { [weak self] alerts in
                self?.statusItem.button?.image = MenuBarIcon.make(alerting: !alerts.isEmpty)
                self?.statusItem.button?.toolTip = alerts.isEmpty
                    ? "Mac Usage"
                    : "Mac Usage — " + alerts.map(\.message).joined(separator: ", ")
            }
    }

    // MARK: Status item clicks

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        if panel.isVisible {
            hidePanel()
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open", action: #selector(openPanelFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitFromMenu), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attach the menu only for this click: with a permanent menu,
        // left clicks would open it too instead of toggling the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanelFromMenu() {
        if !panel.isVisible {
            showPanel()
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // Size to the current content, center under the icon, clamp
        // to the screen — all before the panel becomes visible.
        let size = hostingView.fittingSize
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let margin: CGFloat = 8
        var x = iconFrame.midX - size.width / 2
        x = max(screen.visibleFrame.minX + margin,
                min(x, screen.visibleFrame.maxX - size.width - margin))
        let y = iconFrame.minY - menuBarGap - size.height

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                       display: false)
        panel.orderFront(nil)
        statsStore.panelDidOpen()

        // Any click outside our windows closes the panel, menu-style.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func hidePanel() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        NotificationCenter.default.post(name: Self.panelWillHide, object: nil)
        panel.orderOut(nil)
        statsStore.panelDidClose()
    }
}
