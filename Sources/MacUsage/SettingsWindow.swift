import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// Settings, as a real window.
//
// Two things this deliberately does not use:
//
//  • SwiftUI's `Settings` scene. Opening it from code needs a private
//    selector (`showPreferencesWindow:`, renamed `showSettingsWindow:`
//    in macOS 14) and on macOS 26 neither is handled - the gear button
//    silently did nothing. We own an ordinary NSWindow instead.
//
//  • The ⌘, shortcut those selectors pair with. An `.accessory` app
//    has no menu bar, so there is no Settings menu item for a shortcut
//    to hang off. The panel's gear button is the only way in.
//
// Why a window at all, when this used to live inside the stats panel:
// that panel is a borderless, non-activating NSPanel, so it can never
// become key. System controls render in their inactive state (which
// is why a hand-drawn `SettingSwitch` existed), system drag sessions
// do not work (which is why card reordering was a hand-rolled
// DragGesture), and - the part with no workaround - it cannot take
// keyboard focus at all, so a text field is inert. Editable alert
// thresholds need one.
// ─────────────────────────────────────────────────────────────────

@MainActor
final class SettingsWindowController {

    /// The panel's gear button posts this; the AppDelegate hides the
    /// panel and shows the window. It goes through the delegate rather
    /// than opening directly because dismissing the panel is the
    /// delegate's job, and the click-outside monitor it owns does not
    /// fire for clicks landing in our own windows.
    static let openRequested = Notification.Name("MacUsageOpenSettingsRequested")

    /// Sized to the tallest pane (Menu Bar), so no pane inherits
    /// another's empty space and none of them clip. The window is
    /// resizable as a safety valve: a pane that grows past this is
    /// recoverable by dragging rather than stuck.
    private static let contentSize = NSSize(width: 460, height: 384)

    /// Kept alive between opens so reopening restores the same window
    /// and its selected tab rather than building a new one.
    private var window: NSWindow?

    func show() {
        // An .accessory app is never frontmost on its own, so the
        // window would otherwise open behind whatever has focus.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let newWindow = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Mac Usage Settings"
        newWindow.contentView = NSHostingView(rootView: SettingsView())
        // Closing must not deallocate it, or reopening lands on a
        // dangling reference.
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }
}

/// Escape and ⌘W both close the window.
///
/// Neither comes for free here. Escape only closes a window AppKit
/// considers cancellable, and ⌘W is normally supplied by the File menu
/// - which an `.accessory` app does not have. Without these the only
/// way out is the traffic light, which is a lot of mousing for a
/// window you open to flip one switch.
private final class SettingsPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsView()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            CardsSettingsView()
                .tabItem { Label("Cards", systemImage: "rectangle.stack") }
        }
        .padding(.top, 8)
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
                SettingRow(
                    title: "Launch at login",
                    detail: "Start Mac Usage automatically after you log in.",
                    isOn: launchAtLoginBinding
                )
            }
            Section {
                SettingRow(
                    title: "Fetch public IP",
                    detail: "Shows your public address in the Network card. "
                          + "This is the only network request Mac Usage makes; "
                          + "every other reading comes from the kernel, IOKit "
                          + "and the SMC on this Mac.",
                    isOn: $fetchesPublicIP
                )
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

/// A switch with the sentence that explains what it does underneath.
/// The detail line is what lets this pane fill its height honestly
/// rather than sitting in a void, and it earns the space: "Fetch
/// public IP" does not tell you it is the app's only network request.
private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: Menu Bar

private struct MenuBarSettingsView: View {
    @AppStorage(MenuBarSettings.stripEnabledKey) private var showsStrip = true
    @AppStorage("menuBarShowCpu") private var showsCpu = true
    @AppStorage("menuBarShowMemory") private var showsMemory = true
    @AppStorage("menuBarShowNetwork") private var showsNetwork = true
    @AppStorage("menuBarShowTemperature") private var showsTemperature = false

    var body: some View {
        Form {
            Section {
                SettingRow(
                    title: "Show readings in the menu bar",
                    detail: "Live numbers next to the gauge icon. With this off, "
                          + "the menu bar shows the icon alone and every reading "
                          + "lives in the panel.",
                    isOn: $showsStrip
                )
            }
            Section {
                ForEach(MenuBarSegment.allCases) { segment in
                    Toggle(segment.displayName, isOn: binding(for: segment))
                }
                .disabled(!showsStrip)
            } header: {
                Text("Readings")
            } footer: {
                Text("Each reading takes menu bar width, so turning one off "
                     + "gives that space back. Battery is not offered: macOS "
                     + "already shows it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for segment: MenuBarSegment) -> Binding<Bool> {
        switch segment {
        case .cpu: return $showsCpu
        case .memory: return $showsMemory
        case .network: return $showsNetwork
        case .temperature: return $showsTemperature
        }
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
        VStack(alignment: .leading, spacing: 0) {
            Text("The panel shows these cards in this order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            List {
                ForEach(ExpandableSection.order(from: cardOrderRaw)) { section in
                    // The checkbox keeps its label hidden and the name
                    // is drawn separately, so the row keeps inert area
                    // to grab. A plain `Toggle("CPU", …)` would make
                    // the whole row the control's hit target and
                    // swallow the drag `.onMove` needs.
                    HStack(spacing: 10) {
                        Toggle("", isOn: visibilityBinding(for: section))
                            .labelsHidden()
                        Image(systemName: section.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(section.displayName)
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .onMove(perform: move)
            }
            .scrollDisabled(true)

            Text("Drag a row to reorder. Hidden cards keep their place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
        .padding(.vertical, 16)
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
