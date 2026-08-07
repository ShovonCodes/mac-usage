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
        // All real UI lives in the status item panel the delegate owns,
        // plus the Settings window it opens. SwiftUI still requires a
        // Scene here, so this stays an empty placeholder.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Posted just before the panel hides so views can clean up
    /// (collapse hover details) — they never see onDisappear because
    /// the hosting view stays alive between opens.
    static let panelWillHide = Notification.Name("MacUsagePanelWillHide")
    /// Posted by the panel content when its size changes (cards being
    /// toggled, the settings page) so the window can follow.
    static let panelContentSizeChanged = Notification.Name("MacUsagePanelContentSizeChanged")

    private let statsStore = StatsStore()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>!
    private var clickOutsideMonitor: Any?
    private var alertSubscription: AnyCancellable?
    private var contentSizeSubscription: AnyCancellable?
    private var openSettingsSubscription: AnyCancellable?
    private var menuBarSubscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private let settingsWindowController = SettingsWindowController()

    /// Gap between the menu bar and the top of the panel.
    private let menuBarGap: CGFloat = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Script mode: install.sh/uninstall.sh run the binary with
        // `--set-login on|off` to flip the start-at-login registration
        // (SMAppService only lets an app register its own bundle).
        // Apply the change and exit before any UI exists.
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--set-login"),
           flagIndex + 1 < arguments.count {
            exit(LoginItemManager.setEnabled(arguments[flagIndex + 1] == "on") ? 0 : 1)
        }

        // Hide the Dock icon — this app lives only in the menu bar.
        NSApp.setActivationPolicy(.accessory)

        // Variable, not square: the strip's width depends on which
        // segments are switched on, so turning one off gives the room
        // back to the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Mac Usage"
        refreshStatusItem()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        hostingView = NSHostingView(
            rootView: AnyView(StatsPanelView().environmentObject(statsStore))
        )
        panel = FloatingPanel.make(wrapping: hostingView)

        // Follow content-height changes (card toggles, settings page)
        // while the panel is open, keeping its top edge pinned.
        contentSizeSubscription = NotificationCenter.default
            .publisher(for: Self.panelContentSizeChanged)
            .sink { [weak self] notification in
                guard let value = notification.userInfo?["size"] as? NSValue else { return }
                Task { @MainActor in self?.resizePanel(to: value.sizeValue) }
            }

        // The panel's gear button asks for Settings. The panel has to
        // close first: opening a real window activates the app, and
        // the click-outside monitor never sees that click (it only
        // fires for events routed to *other* applications), so the
        // panel would otherwise hang around behind the window.
        openSettingsSubscription = NotificationCenter.default
            .publisher(for: SettingsWindowController.openRequested)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.hidePanel()
                    self?.settingsWindowController.show()
                }
            }

        // Redraw the strip once per fast tick. One signal rather than
        // one per published value, so a tick redraws exactly once.
        menuBarSubscription = statsStore.$menuBarTick
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }

        // Reflect the alert state immediately (the badge) and explain
        // it in the tooltip.
        alertSubscription = statsStore.$activeAlerts
            .removeDuplicates()
            .sink { [weak self] alerts in
                Task { @MainActor in
                    self?.refreshStatusItem()
                    self?.statusItem.button?.toolTip = alerts.isEmpty
                        ? "Mac Usage"
                        : "Mac Usage: " + alerts.map(\.message).joined(separator: ", ")
                }
            }

        // Segment toggles take effect on the next redraw rather than
        // the next tick, which at 15s idle would feel broken.
        defaultsSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
    }

    /// Rebuild the status item image from the store's current values.
    private func refreshStatusItem() {
        let readout = MenuBarReadout(
            cpuBusyPercent: statsStore.cpuUsage.totalBusyPercent,
            cpuHistory: statsStore.cpuHistory.map { $0.userPercent + $0.systemPercent },
            memoryUsedPercent: statsStore.memoryUsage.usedPercent,
            uploadBytesPerSecond: statsStore.networkSpeed.uploadBytesPerSecond,
            downloadBytesPerSecond: statsStore.networkSpeed.downloadBytesPerSecond,
            cpuTemperatureCelsius: statsStore.averageTemperatures[.cpu]
        )
        statusItem.button?.image = MenuBarStrip.make(
            readout: readout,
            segments: MenuBarSettings.visibleSegments,
            alerting: !statsStore.activeAlerts.isEmpty
        )
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

    private func resizePanel(to size: CGSize) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5
                || abs(frame.width - size.width) > 0.5 else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
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
