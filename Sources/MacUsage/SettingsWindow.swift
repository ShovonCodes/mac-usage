import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// Settings, as a real window.
//
// This used to be a page *inside* the stats panel. That panel is a
// borderless, non-activating NSPanel, which means AppKit never treats
// it as the active window, and that had two costs:
//
//   • System controls render in their inactive state, so a checked
//     Toggle looked the same as an unchecked one. The workaround was
//     a hand-drawn `SettingSwitch`.
//   • The window can never become key, so system drag sessions do not
//     work. Reordering cards needed a hand-rolled DragGesture with
//     row offsets, hysteresis and a deferred order commit.
//
// Both workarounds are deleted now: in a normal window `Toggle` and
// `List`'s `.onMove` just work. The bigger reason for the move is
// that a non-key window also cannot take *keyboard focus*, so a text
// field is impossible there. Editable alert thresholds need one.
//
// The scene itself is SwiftUI's `Settings`, which gives us the
// standard ⌘, behaviour for free. Because the app runs as
// `.accessory` (no Dock icon), opening it has to activate the app
// explicitly. See `SettingsWindow.open()`.
// ─────────────────────────────────────────────────────────────────

/// Opens the Settings scene from anywhere in the app.
enum SettingsWindow {
    /// The panel's gear button posts this; the AppDelegate hides the
    /// panel and calls `open()`. It goes through the delegate rather
    /// than opening directly because dismissing the panel is the
    /// delegate's job, and the click-outside monitor it owns does not
    /// fire for clicks landing in our own windows.
    static let openRequested = Notification.Name("MacUsageOpenSettingsRequested")

    @MainActor
    static func open() {
        // An .accessory app is never frontmost on its own, so the
        // window would otherwise open behind whatever has focus.
        NSApp.activate(ignoringOtherApps: true)

        // The selector was renamed in macOS 14. Both are private, but
        // this is the only way to open a SwiftUI Settings scene
        // programmatically.
        let selector = if #available(macOS 14, *) {
            Selector(("showSettingsWindow:"))
        } else {
            Selector(("showPreferencesWindow:"))
        }
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CardsSettingsView()
                .tabItem { Label("Cards", systemImage: "rectangle.stack") }
        }
        .frame(width: 460)
    }
}

// MARK: General

private struct GeneralSettingsView: View {
    @AppStorage("fetchPublicIP") private var fetchesPublicIP = true

    /// Mirrors SMAppService's registration state. The system owns this,
    /// not us, so it is re-read every time the pane appears rather than
    /// being stored.
    @State private var launchesAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }
            Section {
                Toggle("Fetch public IP", isOn: $fetchesPublicIP)
            } footer: {
                Text("The public-IP lookup is the only network request "
                     + "Mac Usage ever makes. Everything else is read "
                     + "locally from the kernel, IOKit and the SMC.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchesAtLogin = LoginItemManager.isEnabled }
    }

    /// Talks to SMAppService immediately on toggle; the switch only
    /// moves if macOS accepted the change (it refuses when the binary
    /// runs outside an app bundle during development).
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { enabled in
                if LoginItemManager.setEnabled(enabled) {
                    launchesAtLogin = enabled
                }
            }
        )
    }
}

// MARK: Cards

private struct CardsSettingsView: View {
    @AppStorage("cardOrder") private var cardOrderRaw = ""
    @AppStorage("showCpuCard") private var showsCpuCard = true
    @AppStorage("showMemoryCard") private var showsMemoryCard = true
    @AppStorage("showBatteryCard") private var showsBatteryCard = true
    @AppStorage("showNetworkCard") private var showsNetworkCard = true
    @AppStorage("showTemperatureCard") private var showsTemperatureCard = true
    @AppStorage("showFansCard") private var showsFansCard = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to reorder. Turn off the cards you do not need.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(ExpandableSection.order(from: cardOrderRaw)) { section in
                    // The checkbox keeps its label hidden and the name
                    // is drawn separately, so the row has inert area to
                    // grab. A plain `Toggle("CPU", …)` makes the whole
                    // row the control's hit target, which swallows the
                    // drag `.onMove` needs.
                    HStack(spacing: 8) {
                        Toggle("", isOn: visibilityBinding(for: section))
                            .labelsHidden()
                        Text(section.displayName)
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .onMove(perform: move)
            }
            .frame(height: 190)
        }
        .padding(20)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var order = ExpandableSection.order(from: cardOrderRaw)
        order.move(fromOffsets: source, toOffset: destination)
        cardOrderRaw = ExpandableSection.rawValue(for: order)
    }

    private func visibilityBinding(for section: ExpandableSection) -> Binding<Bool> {
        switch section {
        case .cpu: return $showsCpuCard
        case .memory: return $showsMemoryCard
        case .battery: return $showsBatteryCard
        case .network: return $showsNetworkCard
        case .temperature: return $showsTemperatureCard
        case .fans: return $showsFansCard
        }
    }
}
