import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// The dropdown panel that appears when you click the menu bar icon.
// Visual style loosely follows iStat Menus: grouped card sections
// with small uppercase headers, gauges, and clean rows.
// ─────────────────────────────────────────────────────────────────

/// Stat cards that can expand a detail column when hovered.
/// Raw values are what the persisted card-order string stores, and
/// the case order here is the default card order on a fresh install.
enum ExpandableSection: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case battery
    case network
    case disk
    case temperature
    case fans

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .network: return "Network"
        case .disk: return "Disk"
        case .temperature: return "Temperature"
        case .fans: return "Fans"
        }
    }

    /// Icon for this card in the Settings list.
    ///
    /// Names are the SF Symbols 4 spellings, which is the newest set
    /// macOS 13 ships. `battery.100` and `fanblades` are older names
    /// that no longer resolve, and `fan` only arrived in SF Symbols 5,
    /// so fans fall back to `wind` on macOS 13. A missing symbol draws
    /// nothing rather than failing, so getting these wrong shows up as
    /// a blank gap in the list.
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .battery: return "battery.100percent"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .temperature: return "thermometer.medium"
        case .fans: return if #available(macOS 14, *) { "fan" } else { "wind" }
        }
    }

    /// Parse the persisted "cpu,memory,..." order string.
    ///
    /// Unknown entries are dropped and missing cards appended, so the
    /// result always covers every card exactly once no matter what the
    /// stored string says. That is what makes a card added in a later
    /// version appear for people who already have an order saved.
    static func order(from raw: String) -> [ExpandableSection] {
        var order = raw.split(separator: ",")
            .compactMap { ExpandableSection(rawValue: String($0)) }
        var seen = Set<ExpandableSection>()
        order = order.filter { seen.insert($0).inserted }
        order.append(contentsOf: allCases.filter { !seen.contains($0) })
        return order
    }

    /// The inverse of `order(from:)`, for writing the setting back.
    static func rawValue(for order: [ExpandableSection]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}


struct StatsPanelView: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Which card's detail panel is currently expanded, if any.
    @State private var expandedSection: ExpandableSection?
    /// The NSView hosting this SwiftUI view - how the detail panel
    /// controller finds the menu bar panel's window to sit beside.
    @State private var hostView: NSView?
    @State private var detailPanelController = DetailPanelController()

    // Which cards the user wants to see - persisted so hidden cards
    // stay hidden across launches.
    @AppStorage("showCpuCard") private var showsCpuCard = true
    @AppStorage("showMemoryCard") private var showsMemoryCard = true
    @AppStorage("showBatteryCard") private var showsBatteryCard = true
    @AppStorage("showNetworkCard") private var showsNetworkCard = true
    @AppStorage("showDiskCard") private var showsDiskCard = true
    @AppStorage("showTemperatureCard") private var showsTemperatureCard = true
    @AppStorage("showFansCard") private var showsFansCard = true

    /// Card order, stored as comma-separated raw values
    /// ("cpu,memory,..."). Cards missing from the string (added in an
    /// app update) are appended in default position - see `cardOrder`.
    @AppStorage("cardOrder") private var cardOrderRaw = ""


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statsContent
        }
        .padding(12)
        .frame(width: 300)
        .background(HostingViewAccessor(view: $hostView))
        // Cards toggling on/off (and the settings page itself) change
        // the content height - tell the delegate to resize the panel.
        .modifier(SizeReporter { size in
            NotificationCenter.default.post(
                name: AppDelegate.panelContentSizeChanged,
                object: nil,
                userInfo: ["size": NSValue(size: size)]
            )
        })
        .onChange(of: expandedSection) { section in
            guard let section else {
                detailPanelController.hide()
                return
            }
            // The detail closes only when the pointer leaves both the
            // main panel and the detail panel - the controller watches
            // for that, so leaving an individual card never dismisses it.
            detailPanelController.onPointerLeftPanels = { expandedSection = nil }
            showDetail(for: section)
        }
        // The hosting view stays alive between panel opens, so
        // onDisappear never fires - the delegate tells us instead.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.panelWillHide)) { _ in
            expandedSection = nil
        }
    }

    @ViewBuilder
    private var statsContent: some View {
        if !statsStore.activeAlerts.isEmpty {
            alertBanner
        }
        ForEach(cardOrder) { section in
            if isCardVisible(section) {
                card(for: section)
                    .onHover { if $0 { expandedSection = section } }
            }
        }
        bottomBar
    }

    private var cardOrder: [ExpandableSection] {
        ExpandableSection.order(from: cardOrderRaw)
    }

    private func isCardVisible(_ section: ExpandableSection) -> Bool {
        switch section {
        case .cpu: return showsCpuCard
        case .memory: return showsMemoryCard
        case .battery: return showsBatteryCard && statsStore.battery.isPresent
        case .network: return showsNetworkCard
        case .disk: return showsDiskCard
        case .temperature: return showsTemperatureCard
        case .fans: return showsFansCard
        }
    }

    @ViewBuilder
    private func card(for section: ExpandableSection) -> some View {
        switch section {
        case .cpu: cpuSection
        case .memory: memorySection
        case .battery: batterySection
        case .network: networkSection
        case .disk: diskSection
        case .temperature: temperaturesSection
        case .fans: fansSection
        }
    }


    /// Red banner at the top listing every firing threshold alert -
    /// the panel-side counterpart of the menu bar badge.
    private var alertBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(statsStore.activeAlerts) { alert in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.red)
                    Text(alert.message)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.red.opacity(Theme.tintAlpha))
        )
    }

    private func showDetail(for section: ExpandableSection) {
        switch section {
        case .cpu:
            detailPanelController.show(content: cpuDetailContent,
                                       besideWindowContaining: hostView)
        case .memory:
            detailPanelController.show(content: memoryDetailContent,
                                       besideWindowContaining: hostView)
        case .battery:
            detailPanelController.show(content: batteryDetailContent,
                                       besideWindowContaining: hostView)
        case .network:
            detailPanelController.show(content: networkDetailContent,
                                       besideWindowContaining: hostView)
        case .disk:
            detailPanelController.show(content: diskDetailContent,
                                       besideWindowContaining: hostView)
        case .fans:
            detailPanelController.show(content: fanDetailContent,
                                       besideWindowContaining: hostView)
        case .temperature:
            detailPanelController.show(content: temperatureDetailContent,
                                       besideWindowContaining: hostView)
        }
    }

    private var memoryDetailContent: some View {
        MemoryDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
    }

    private var cpuDetailContent: some View {
        CpuDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
    }

    private var batteryDetailContent: some View {
        BatteryDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
    }

    private var networkDetailContent: some View {
        NetworkDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
            .modifier(SizeReporter { detailPanelController.updateContentSize($0) })
    }

    private var diskDetailContent: some View {
        DiskDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
    }

    private var fanDetailContent: some View {
        FanDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
    }

    private var temperatureDetailContent: some View {
        TemperatureDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
            .modifier(SizeReporter { detailPanelController.updateContentSize($0) })
    }

    // MARK: CPU

    private var cpuSection: some View {
        StatSectionCard(title: "CPU", titleTrailing: cpuTitleTrailing) {
            VStack(spacing: 6) {
                CpuHistoryChart(points: statsStore.cpuHistory)
                HStack(spacing: 4) {
                    Circle().fill(cpuUserColor).frame(width: 6, height: 6)
                    Text("User")
                    Text(String(format: "%.0f%%", statsStore.cpuUsage.userPercent))
                        .foregroundStyle(.primary)
                    Spacer()
                    Circle().fill(cpuSystemColor).frame(width: 6, height: 6)
                    Text("System")
                    Text(String(format: "%.0f%%", statsStore.cpuUsage.systemPercent))
                        .foregroundStyle(.primary)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// "22% · 52°" - current total CPU + CPU temperature. (Clock speed,
    /// iStat-style, isn't readable without root on Apple Silicon.)
    private var cpuTitleTrailing: String {
        var parts = ["\(Int(statsStore.cpuUsage.totalBusyPercent))%"]
        if let cpuTemperature = statsStore.averageTemperatures[.cpu] {
            parts.append(String(format: "%.0f°", cpuTemperature))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Memory

    private var memorySection: some View {
        StatSectionCard(title: "Memory") {
            HStack {
                Spacer()
                SegmentedCircularGauge(
                    segments: [GaugeSegment(
                        color: pressureColor(statsStore.memoryUsage.pressurePercent),
                        fraction: statsStore.memoryUsage.pressurePercent / 100
                    )],
                    label: "\(Int(statsStore.memoryUsage.pressurePercent))%",
                    caption: "PRESSURE",
                    size: 72
                )
                Spacer()
                SegmentedCircularGauge(
                    segments: memoryGaugeSegments(statsStore.memoryUsage),
                    label: "\(Int(statsStore.memoryUsage.usedPercent))%",
                    caption: "MEMORY",
                    size: 72
                )
                Spacer()
            }
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        StatSectionCard(title: "Battery") {
            HStack {
                Spacer()
                SegmentedCircularGauge(
                    segments: [GaugeSegment(
                        color: batteryLevelColor(statsStore.battery),
                        fraction: statsStore.battery.levelPercent / 100
                    )],
                    label: "\(Int(statsStore.battery.levelPercent))%",
                    caption: batteryTimeText(statsStore.battery),
                    size: 72
                )
                Spacer()
                SegmentedCircularGauge(
                    segments: [GaugeSegment(
                        color: Theme.pink,
                        fraction: statsStore.battery.healthPercent / 100
                    )],
                    // %.0f rounds like the detail row does - Int()
                    // truncation made the two disagree (93 vs 94).
                    label: String(format: "%.0f%%", statsStore.battery.healthPercent),
                    caption: "HEALTH",
                    size: 72
                )
                Spacer()
            }
        }
    }

    // MARK: Network

    private var networkSection: some View {
        StatSectionCard(title: "Network") {
            VStack(spacing: 6) {
                NetworkSparkline(points: statsStore.networkHistory)
                networkSpeeds
            }
        }
    }

    private var networkSpeeds: some View {
        HStack {
                Spacer()
                VStack(spacing: 2) {
                    Text(speedText(statsStore.networkSpeed.uploadBytesPerSecond))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    DirectionLabel(color: networkUploadColor, text: "↑ Upload")
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(speedText(statsStore.networkSpeed.downloadBytesPerSecond))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    DirectionLabel(color: networkDownloadColor, text: "↓ Download")
                }
                Spacer()
        }
    }

    // MARK: Disk

    private var diskSection: some View {
        StatSectionCard(title: "Disk", titleTrailing: diskTitleTrailing) {
            VStack(spacing: 8) {
                CapacityBar(usedFraction: statsStore.disk.usedPercent / 100)
                HStack(spacing: 4) {
                    Circle().fill(diskReadColor).frame(width: 6, height: 6)
                    Text("Read")
                    Text(speedText(statsStore.disk.readBytesPerSecond))
                        .foregroundStyle(.primary)
                    Spacer()
                    Circle().fill(diskWriteColor).frame(width: 6, height: 6)
                    Text("Write")
                    Text(speedText(statsStore.disk.writeBytesPerSecond))
                        .foregroundStyle(.primary)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// "35% · 24 GB free", mirroring the CPU card's trailing summary.
    private var diskTitleTrailing: String {
        let disk = statsStore.disk
        guard disk.totalBytes > 0 else { return "" }
        return "\(Int(disk.usedPercent))% · \(formatBytes(disk.freeBytes)) free"
    }

    // MARK: Fans

    private var fansSection: some View {
        StatSectionCard(title: "Fans") {
            if statsStore.fans.isEmpty {
                Text("No fans detected (fanless Mac, or sensors unavailable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(statsStore.fans) { fan in
                        LabeledValueRow(
                            label: statsStore.fans.count == 1 ? "Fan" : "Fan \(fan.id + 1)",
                            value: fan.speedRpm < 1
                                ? "Off"
                                : "\(Int(fan.speedRpm)) RPM"
                        )
                    }
                }
            }
        }
    }

    // MARK: Temperatures

    private var temperaturesSection: some View {
        StatSectionCard(title: "Temperature") {
            if statsStore.averageTemperatures.isEmpty {
                Text("No temperature sensors available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // Fixed display order so rows don't jump around.
                    let displayOrder: [TemperatureCategory] = [.cpu, .gpu, .battery, .other]
                    ForEach(displayOrder, id: \.self) { category in
                        if let celsius = statsStore.averageTemperatures[category] {
                            LabeledValueRow(
                                label: category.rawValue,
                                value: String(format: "%.0f°", celsius)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Text("Mac Usage")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NotificationCenter.default.post(
                    name: SettingsWindowController.openRequested, object: nil
                )
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
        .padding(.top, 2)
    }

}

/// "14.4 GB"-style formatting shared by the main panel and the
/// memory detail column.
private func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

/// User/system accent colors, shared by the CPU chart, its legend,
/// and the hover breakdown's dots.
private let cpuUserColor: Color = Theme.blue
private let cpuSystemColor: Color = Theme.pink

/// Stacked bar history: user (blue) below, system (pink) above, on a
/// fixed 0–100% scale. One bar per refresh tick, newest on the right.
struct CpuHistoryChart: View {
    let points: [CpuHistoryPoint]

    /// Fixed two-minute window, one slot per two seconds. Bars are
    /// placed by timestamp, not by position in the buffer, so a
    /// stretch sampled slowly (panel closed, strip off) draws as the
    /// gap it really was instead of being stretched to fill the
    /// chart. The buffer can hold up to 15 minutes of slow samples;
    /// anything older than the window simply falls outside it.
    private static let windowSeconds: TimeInterval = 120
    private static let slotCount = 60
    private static let chartHeight: CGFloat = 40

    var body: some View {
        let slots = TimeBuckets.slots(
            points, timestamp: \.id,
            window: Self.windowSeconds, slotCount: Self.slotCount, now: Date()
        )
        let user = TimeBuckets.averaged(slots) { $0.userPercent }
        let system = TimeBuckets.averaged(slots) { $0.systemPercent }

        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                // A single reference line at 50%. Without it a spike
                // has no scale: the bars could be 30% or 90% and look
                // identical.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
                .frame(height: Self.chartHeight / 2)

                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<Self.slotCount, id: \.self) { index in
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(cpuSystemColor)
                                .frame(height: barHeight(system[index]))
                            Rectangle()
                                .fill(cpuUserColor)
                                .frame(height: barHeight(user[index]))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.chartHeight, alignment: .bottom)
            }
            .frame(height: Self.chartHeight)

            HStack {
                Text("2 min ago")
                Spacer()
                Text("50% line")
                Spacer()
                Text("now")
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
        }
    }

    private func barHeight(_ percent: Double?) -> CGFloat {
        guard let percent, percent > 0 else { return 0.5 }
        return max(1, Self.chartHeight * min(percent, 100) / 100)
    }
}

/// The colored arcs for the memory ring: App / Wired / Compressed,
/// each as its share of total RAM. Free stays the gray base track.
private func memoryGaugeSegments(_ memory: MemoryUsageSnapshot) -> [GaugeSegment] {
    let totalBytes = Double(memory.totalBytes)
    guard totalBytes > 0 else { return [] }
    return [
        GaugeSegment(color: Theme.blue, fraction: Double(memory.breakdown.appBytes) / totalBytes),
        GaugeSegment(color: Theme.pink, fraction: Double(memory.breakdown.wiredBytes) / totalBytes),
        GaugeSegment(color: Theme.yellow, fraction: Double(memory.breakdown.compressedBytes) / totalBytes),
    ]
}

/// Green when relaxed, orange when strained, red when critical -
/// same thresholds the plain gauges use.
private func pressureColor(_ percent: Double) -> Color {
    if percent < 50 { return Theme.green }
    if percent < 80 { return Theme.orange }
    return Theme.red
}

/// Read/write accent colors. Read shares the blue that already means
/// "incoming" on the network card; write shares its pink.
private let diskReadColor: Color = Theme.blue
private let diskWriteColor: Color = Theme.pink

/// Upload/download accent colors (match the iStat-style chart).
private let networkUploadColor: Color = Theme.pink
private let networkDownloadColor: Color = Theme.blue

/// "● ↑ Upload" under a network speed.
///
/// The label used to be drawn *in* its direction's color, but at
/// caption2 size on a translucent panel that measured 2.7:1. Same
/// shape as the CPU chart's legend now: the hue moves into a dot,
/// which only has to clear the 3:1 bar for a graphical mark, and the
/// words fall back to `.secondary`.
private struct DirectionLabel: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// "33.8 MB/s"-style throughput formatting.
private func speedText(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    return formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
}

/// Blue while charging, then green/orange/red as the level drops.
private func batteryLevelColor(_ battery: BatterySnapshot) -> Color {
    if battery.isCharging { return Theme.blue }
    if battery.levelPercent > 50 { return Theme.green }
    if battery.levelPercent > 20 { return Theme.orange }
    return Theme.red
}

/// "2:22"-style time remaining (to empty, or to full while charging).
private func batteryTimeText(_ battery: BatterySnapshot) -> String {
    if let minutes = battery.timeRemainingMinutes {
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
    if battery.isPluggedIn && !battery.isCharging { return "AC" }
    return "…" // macOS is still estimating
}

private func batteryStatusText(_ battery: BatterySnapshot) -> String {
    if battery.isCharging { return "Charging" }
    if battery.isPluggedIn { return "On AC power" }
    return "Discharging"
}

/// 312 → "5:12".
private func minutesText(_ minutes: Int) -> String {
    String(format: "%d:%02d", minutes / 60, minutes % 60)
}

// ─────────────────────────────────────────────────────────────────
// Memory hover detail: breakdown + top processes
// ─────────────────────────────────────────────────────────────────

struct MemoryDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Memory Details")
            StatSectionCard(title: "Pressure, last 24 h") {
                TrendChart(
                    points: statsStore.history.recent(hours: 24),
                    value: { $0.memoryPressure },
                    scale: .fixed(0...100),
                    color: { pressureColor($0) },
                    format: { String(format: "%.0f%%", $0) }
                )
            }
            StatSectionCard(title: "Breakdown") {
                VStack(alignment: .leading, spacing: 4) {
                    BreakdownRow(color: Theme.blue, label: "App",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.appBytes))
                    BreakdownRow(color: Theme.pink, label: "Wired",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.wiredBytes))
                    BreakdownRow(color: Theme.yellow, label: "Compressed",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.compressedBytes))
                    BreakdownRow(color: .gray, label: "Free",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.freeBytes))
                }
            }
            StatSectionCard(title: "Processes") {
                if statsStore.memoryDetails.topProcesses.isEmpty {
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(statsStore.memoryDetails.topProcesses) { process in
                            ProcessRow(
                                name: process.name,
                                executablePath: process.executablePath,
                                value: formatBytes(process.memoryBytes)
                            )
                        }
                    }
                }
            }
        }
    }

}

/// The small uppercase title at the top of every hover detail column.
struct DetailColumnHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

// ─────────────────────────────────────────────────────────────────
// Network hover detail: activity chart + connection + top processes
// ─────────────────────────────────────────────────────────────────

struct NetworkDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Mirrors the Settings privacy switch: when off, no lookup ever
    /// runs, so the row would only show "…" - hide it instead.
    @AppStorage("fetchPublicIP") private var fetchesPublicIP = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Network Details")
            StatSectionCard(title: "Activity", titleTrailing: "last 5 min") {
                NetworkHistoryChart(points: statsStore.networkHistory)
            }
            StatSectionCard(title: "Connection") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "Wi-Fi",
                        value: statsStore.networkDetails.info.wifiName ?? "-"
                    )
                    if fetchesPublicIP {
                        LabeledValueRow(
                            label: "Public IP",
                            value: statsStore.networkDetails.info.publicIP ?? "…"
                        )
                    }
                    ForEach(statsStore.networkDetails.info.localIPv4, id: \.self) { address in
                        LabeledValueRow(label: "IP", value: address)
                    }
                    ForEach(statsStore.networkDetails.info.localIPv6, id: \.self) { address in
                        HStack {
                            Text("IPv6")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(address)
                                .font(.system(size: 10).monospacedDigit())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }
}

/// Mirrored bar chart: upload grows upward (pink), download grows
/// downward (blue). Each direction is normalized to its own peak -
/// download usually dwarfs upload, and a shared scale would flatten
/// the upload half into invisibility.
///
/// The x-axis is real time, not ticks: 60 buckets of 5 seconds - a
/// fixed five-minute window no matter how often samples arrive (every
/// 2 s while the panel is open, every 15 s in the background). Buckets
/// with no sample render as hairline stubs.
private struct NetworkHistoryChart: View {
    let points: [NetworkHistoryPoint]

    private static let bucketCount = 60
    private static let bucketSeconds: TimeInterval = 5
    private static let halfHeight: CGFloat = 28

    var body: some View {
        let windowStart = Date()
            .addingTimeInterval(-Double(Self.bucketCount) * Self.bucketSeconds)
        let recent = points.filter { $0.id >= windowStart }
        let buckets = Self.bucketed(recent, since: windowStart)
        let peakUpload = max(recent.map(\.uploadBytesPerSecond).max() ?? 0, 1)
        let peakDownload = max(recent.map(\.downloadBytesPerSecond).max() ?? 0, 1)

        VStack(spacing: 4) {
            VStack(spacing: 1) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                        Capsule()
                            .fill(networkUploadColor)
                            .frame(height: barHeight(bucket?.upload, peak: peakUpload))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: Self.halfHeight, alignment: .bottom)
                HStack(alignment: .top, spacing: 1) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                        Capsule()
                            .fill(networkDownloadColor)
                            .frame(height: barHeight(bucket?.download, peak: peakDownload))
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(height: Self.halfHeight, alignment: .top)
            }
            HStack(spacing: 4) {
                Circle().fill(networkUploadColor).frame(width: 6, height: 6)
                Text("Peak ↑ \(speedText(peakUpload))")
                Spacer()
                Circle().fill(networkDownloadColor).frame(width: 6, height: 6)
                Text("Peak ↓ \(speedText(peakDownload))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func barHeight(_ value: Double?, peak: Double) -> CGFloat {
        guard let value, value > 0 else { return 1 }
        return max(2, Self.halfHeight * value / peak)
    }

    /// Samples averaged into fixed 5-second slots; empty slots stay nil.
    private static func bucketed(
        _ points: [NetworkHistoryPoint], since windowStart: Date
    ) -> [(upload: Double, download: Double)?] {
        var slots: [[NetworkHistoryPoint]] = Array(repeating: [], count: bucketCount)
        for point in points {
            let offset = point.id.timeIntervalSince(windowStart)
            guard offset >= 0 else { continue }
            slots[min(bucketCount - 1, Int(offset / bucketSeconds))].append(point)
        }
        return slots.map { samples in
            guard !samples.isEmpty else { return nil }
            return (
                upload: samples.map(\.uploadBytesPerSecond).reduce(0, +) / Double(samples.count),
                download: samples.map(\.downloadBytesPerSecond).reduce(0, +) / Double(samples.count)
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Battery hover detail: 24h level chart + health facts
// ─────────────────────────────────────────────────────────────────

struct BatteryDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Battery Details")
            StatSectionCard(title: "Last 24 Hours") {
                if statsStore.batteryHistory.allSatisfy({ $0.levelPercent == nil }) {
                    Text("Collecting history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    BatteryHistoryChart(points: statsStore.batteryHistory)
                }
            }
            StatSectionCard(title: "Charge") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "Remaining charge",
                        value: "\(Int(statsStore.battery.levelPercent))%"
                    )
                    LabeledValueRow(
                        label: "Time remaining",
                        value: batteryTimeText(statsStore.battery)
                    )
                    LabeledValueRow(
                        label: "Time on battery",
                        value: statsStore.timeOnBatteryMinutes.map(minutesText) ?? "-"
                    )
                }
            }
            StatSectionCard(title: "Health") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "Status",
                        value: batteryStatusText(statsStore.battery)
                    )
                    LabeledValueRow(
                        label: "Max capacity",
                        value: String(format: "%.0f%%", statsStore.battery.healthPercent)
                    )
                    LabeledValueRow(
                        label: "Cycle count",
                        value: "\(statsStore.battery.cycleCount)"
                    )
                }
            }
        }
    }
}

/// One bar per hour, oldest on the left. Bar height = battery level;
/// hours without any reading render as faint stubs. Hovering a bar
/// brightens it and swaps the footer for that hour's level - system
/// tooltips are too slow (and flaky in a non-activating panel).
private struct BatteryHistoryChart: View {
    let points: [BatteryHistoryPoint]

    @State private var hoveredPoint: BatteryHistoryPoint?

    private static let barAreaHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(points) { point in
                    // The clear backdrop stretches each bar's hover
                    // target to the chart's full height - the visible
                    // capsule alone is a tiny, fiddly target.
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let level = point.levelPercent {
                            Capsule()
                                .fill(barColor(level))
                                .frame(height: max(4, Self.barAreaHeight * level / 100))
                                .brightness(hoveredPoint?.id == point.id ? 0.2 : 0)
                        } else {
                            Capsule()
                                .fill(Color.gray.opacity(hoveredPoint?.id == point.id ? 0.5 : 0.25))
                                .frame(height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.barAreaHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            hoveredPoint = point
                        } else if hoveredPoint?.id == point.id {
                            hoveredPoint = nil
                        }
                    }
                }
            }
            .frame(height: Self.barAreaHeight, alignment: .bottom)
            HStack {
                if let hoveredPoint {
                    Text(Self.hourLabel(hoveredPoint.id))
                    Spacer()
                    Text(hoveredPoint.levelPercent.map { String(format: "%.0f%%", $0) } ?? "no data")
                } else {
                    if let first = points.first {
                        Text(Self.hourLabel(first.id))
                    }
                    Spacer()
                    Text("now")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(hoveredPoint == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        }
    }

    private func barColor(_ level: Double) -> Color {
        if level > 50 { return Theme.green }
        if level > 20 { return Theme.orange }
        return Theme.red
    }

    private static func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// ─────────────────────────────────────────────────────────────────
// Fans hover detail: one card per fan with a speed ring + min/max
// ─────────────────────────────────────────────────────────────────

struct FanDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Fan Details")
            if statsStore.fanDetails.isEmpty {
                StatSectionCard(title: "Fans") {
                    Text("No fans detected (fanless Mac, or sensors unavailable)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(statsStore.fanDetails) { fan in
                    StatSectionCard(
                        title: statsStore.fanDetails.count == 1 ? "Fan" : "Fan \(fan.id + 1)"
                    ) {
                        HStack(spacing: 14) {
                            SegmentedCircularGauge(
                                segments: [GaugeSegment(
                                    color: fanColor(fan),
                                    fraction: fanSpeedFraction(fan)
                                )],
                                label: fan.currentRpm < 1 ? "Off" : "\(Int(fan.currentRpm))",
                                caption: "RPM",
                                size: 64
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledValueRow(label: "Min", value: rpmText(fan.minRpm))
                                LabeledValueRow(label: "Max", value: rpmText(fan.maxRpm))
                            }
                        }
                    }
                }
            }
        }
    }
}

private func rpmText(_ rpm: Double) -> String {
    rpm < 1 ? "-" : "\(Int(rpm)) RPM"
}

/// Current speed as a share of the fan's maximum (0 when unknown).
private func fanSpeedFraction(_ fan: FanDetailReading) -> Double {
    guard fan.maxRpm > 0 else { return 0 }
    return min(fan.currentRpm / fan.maxRpm, 1)
}

private func fanColor(_ fan: FanDetailReading) -> Color {
    let fraction = fanSpeedFraction(fan)
    if fraction < 0.6 { return Theme.green }
    if fraction < 0.85 { return Theme.orange }
    return Theme.red
}

// ─────────────────────────────────────────────────────────────────
// Temperature hover detail: every sensor, grouped by category
// ─────────────────────────────────────────────────────────────────

struct TemperatureDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Grid of chips vs. named sensor rows - remembered across opens.
    @AppStorage("showsTemperatureSensorNames") private var showsSensorNames = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DetailColumnHeader(title: "Temperature Details")
            StatSectionCard(title: "CPU, last 24 h") {
                TrendChart(
                    points: statsStore.history.recent(hours: 24),
                    value: { $0.cpuTemperature },
                    scale: .padded,
                    color: { temperatureColor($0) },
                    format: { String(format: "%.0f°", $0) }
                )
            }
                Spacer()
                Button {
                    showsSensorNames.toggle()
                } label: {
                    Image(systemName: showsSensorNames ? "square.grid.3x2" : "list.bullet")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsSensorNames ? "Show compact grid" : "Show sensor names")
            }
            if statsStore.temperatures.isEmpty {
                StatSectionCard(title: "Sensors") {
                    Text("No temperature sensors available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                let displayOrder: [TemperatureCategory] = [.cpu, .gpu, .battery, .other]
                ForEach(displayOrder, id: \.self) { category in
                    let readings = statsStore.temperatures
                        .filter { $0.category == category }
                        .sorted { $0.celsius > $1.celsius }
                    if !readings.isEmpty {
                        TemperatureCategoryCard(
                            category: category,
                            readings: readings,
                            showsSensorNames: showsSensorNames
                        )
                    }
                }
            }
        }
    }
}

/// One category's sensors: a summary line plus either a grid of heat
/// chips (compact; color carries the story) or one row per sensor
/// labeled with its SMC key - the hardware's real sensor identity.
private struct TemperatureCategoryCard: View {
    let category: TemperatureCategory
    let readings: [TemperatureReading]
    let showsSensorNames: Bool

    var body: some View {
        StatSectionCard(title: category.rawValue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(readings.count == 1 ? "1 sensor" : "\(readings.count) sensors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "avg %.0f° · max %.0f°", average, readings[0].celsius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if showsSensorNames {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(readings) { reading in
                            HStack {
                                Text(reading.id)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.0f°", reading.celsius))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(temperatureColor(reading.celsius))
                            }
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5),
                        spacing: 4
                    ) {
                        ForEach(readings) { reading in
                            TemperatureChip(celsius: reading.celsius)
                        }
                    }
                }
            }
        }
    }

    private var average: Double {
        readings.reduce(0) { $0 + $1.celsius } / Double(readings.count)
    }
}

/// One cell of the sensor heat grid.
///
/// The heat hue used to be on the digits *and* the tint behind them,
/// which meant reading dark red text on a red wash - 1.66:1 for the
/// hottest sensors, the worst contrast anywhere in the app. Now the
/// tint alone carries the heat and the number is plain `.primary`
/// (5.4:1+). The grid reads better from a distance too: a filled
/// swatch is a far bigger color signal than three thin glyphs.
private struct TemperatureChip: View {
    let celsius: Double

    var body: some View {
        Text(String(format: "%.0f°", celsius))
            .font(.caption.monospacedDigit().weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(temperatureColor(celsius).opacity(Theme.tintAlpha))
            )
    }
}

/// Cool → hot color scale shared by all heat chips.
private func temperatureColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<35: return Theme.teal
    case ..<50: return Theme.green
    case ..<65: return Theme.yellow
    case ..<80: return Theme.orange
    default:    return Theme.red
    }
}

// ─────────────────────────────────────────────────────────────────
// CPU hover detail: breakdown + top processes
// ─────────────────────────────────────────────────────────────────

struct CpuDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    @AppStorage("showsPerCoreUsage") private var showsPerCoreUsage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "CPU Details")
            if showsPerCoreUsage, !statsStore.cpuUsage.cores.isEmpty {
                StatSectionCard(title: "Cores") {
                    CoreUsageGrid(cores: statsStore.cpuUsage.cores)
                }
            }
            StatSectionCard(title: "Breakdown") {
                VStack(alignment: .leading, spacing: 4) {
                    BreakdownRow(color: cpuUserColor, label: "User",
                                 value: String(format: "%.1f%%", statsStore.cpuUsage.userPercent))
                    BreakdownRow(color: cpuSystemColor, label: "System",
                                 value: String(format: "%.1f%%", statsStore.cpuUsage.systemPercent))
                    BreakdownRow(color: .gray, label: "Idle",
                                 value: String(format: "%.1f%%", statsStore.cpuUsage.idlePercent))
                }
            }
            StatSectionCard(title: "Processes") {
                if statsStore.cpuDetails.topProcesses.isEmpty {
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(statsStore.cpuDetails.topProcesses) { process in
                            ProcessRow(
                                name: process.name,
                                executablePath: process.executablePath,
                                value: String(format: "%.1f%%", process.cpuPercent)
                            )
                        }
                    }
                }
            }
        }
    }
}

/// One bar per logical core, grouped by cluster on Apple Silicon.
///
/// The grouping is the point: four pegged efficiency cores is a
/// machine ticking over, four pegged performance cores is a machine
/// working hard, and the aggregate percentage cannot tell those
/// apart. Intel Macs report no clusters, so they get one ungrouped
/// list instead of a fake heading.
private struct CoreUsageGrid: View {
    let cores: [CoreUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(clusters, id: \.name) { cluster in
                VStack(alignment: .leading, spacing: 3) {
                    if let name = cluster.name {
                        Text(name.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(cluster.cores) { core in
                        CoreUsageRow(core: core)
                    }
                }
            }
        }
    }

    /// Cores in kernel order, split where the cluster name changes.
    /// Keeping kernel order matters: it is what the indices mean.
    private var clusters: [(name: String?, cores: [CoreUsage])] {
        var result: [(name: String?, cores: [CoreUsage])] = []
        for core in cores {
            if let last = result.last, last.name == core.clusterName {
                result[result.count - 1].cores.append(core)
            } else {
                result.append((name: core.clusterName, cores: [core]))
            }
        }
        return result
    }
}

private struct CoreUsageRow: View {
    let core: CoreUsage

    var body: some View {
        HStack(spacing: 6) {
            Text("\(core.id)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor))
                    Capsule()
                        .fill(coreColor(core.busyPercent))
                        .frame(width: proxy.size.width * min(max(core.busyPercent, 0), 100) / 100)
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", core.busyPercent))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// Same thresholds as the other load gauges, so a busy core reads the
/// same as a busy anything else.
private func coreColor(_ percent: Double) -> Color {
    if percent < 50 { return Theme.green }
    if percent < 85 { return Theme.orange }
    return Theme.red
}

private struct BreakdownRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

/// Icon + name + value row shared by the CPU and memory process lists.
private struct ProcessRow: View {
    let name: String
    let executablePath: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon(forExecutablePath: executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .layoutPriority(1)
        }
    }

    /// The app icon for a process. Helpers live inside the main app's
    /// bundle (".../Slack.app/Contents/.../Slack Helper"), so use the
    /// outermost .app bundle; bare executables get the generic icon.
    private static func icon(forExecutablePath path: String) -> NSImage {
        guard !path.isEmpty else {
            return NSWorkspace.shared.icon(for: .unixExecutable)
        }
        if let appRange = path.range(of: ".app/") {
            return NSWorkspace.shared.icon(forFile: String(path[..<appRange.lowerBound]) + ".app")
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// A 24 hour trend from the persisted record: one bar per minute,
/// bucketed by real time so a stretch when the app was not running
/// draws as the gap it was rather than being closed up.
///
/// This is what persistence buys. "Memory pressure is 48% right now"
/// answers much less than "it peaked at 91% two hours ago".
struct TrendChart: View {
    let points: [HistoryMinute]
    let value: (HistoryMinute) -> Double?
    let scale: Scale
    let color: (Double) -> Color
    let format: (Double) -> String

    /// Percentages want a fixed 0-100 so heights stay comparable
    /// between glances. Temperatures have no natural full scale, so
    /// they get padded around the observed range instead.
    enum Scale {
        case fixed(ClosedRange<Double>)
        case padded
    }

    private static let chartHeight: CGFloat = 44
    private static let slotCount = 72   // 24 h in 20-minute slots

    var body: some View {
        let slots = TimeBuckets.slots(
            points, timestamp: \.date,
            window: 24 * 3600, slotCount: Self.slotCount, now: Date()
        )
        let averages: [Double?] = slots.map { rows in
            let values = rows.compactMap(value)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        let present = averages.compactMap { $0 }
        let range = bounds(for: present)

        VStack(alignment: .leading, spacing: 4) {
            if present.isEmpty {
                Text("Collecting. The first day builds up as the app runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.chartHeight, alignment: .center)
            } else {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<Self.slotCount, id: \.self) { index in
                        Rectangle()
                            .fill(averages[index].map(color) ?? Color.clear)
                            .frame(height: barHeight(averages[index], in: range))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: Self.chartHeight, alignment: .bottom)

                HStack {
                    Text("24 h ago")
                    Spacer()
                    if let peak = present.max() {
                        Text("peak \(format(peak))")
                    }
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func bounds(for values: [Double]) -> ClosedRange<Double> {
        switch scale {
        case .fixed(let range):
            return range
        case .padded:
            guard let low = values.min(), let high = values.max() else { return 0...1 }
            // A flat series would otherwise divide by zero and draw
            // either nothing or full height.
            guard high - low > 1 else { return (low - 5)...(high + 5) }
            let padding = (high - low) * 0.2
            return (low - padding)...(high + padding)
        }
    }

    private func barHeight(_ value: Double?, in range: ClosedRange<Double>) -> CGFloat {
        guard let value else { return 0 }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 1 }
        let fraction = (value - range.lowerBound) / span
        return max(1, Self.chartHeight * min(max(fraction, 0), 1))
    }
}

/// A compact mirrored throughput chart for the main Network card:
/// download above the centre line, upload below. The CPU card has
/// carried a live chart from the start while Network showed two bare
/// numbers, even though the history was already being collected.
struct NetworkSparkline: View {
    let points: [NetworkHistoryPoint]

    private static let windowSeconds: TimeInterval = 120
    private static let slotCount = 60
    private static let halfHeight: CGFloat = 13

    var body: some View {
        let slots = TimeBuckets.slots(
            points, timestamp: \.id,
            window: Self.windowSeconds, slotCount: Self.slotCount, now: Date()
        )
        let download = TimeBuckets.averaged(slots) { $0.downloadBytesPerSecond }
        let upload = TimeBuckets.averaged(slots) { $0.uploadBytesPerSecond }
        // Both directions share one scale, so the halves stay
        // comparable: a tall upload bar really is more traffic than a
        // short download one.
        let peak = max(
            download.compactMap { $0 }.max() ?? 0,
            upload.compactMap { $0 }.max() ?? 0,
            1
        )

        VStack(spacing: 1) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<Self.slotCount, id: \.self) { index in
                    Capsule()
                        .fill(networkDownloadColor)
                        .frame(height: barHeight(download[index], peak: peak))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: Self.halfHeight, alignment: .bottom)
            HStack(alignment: .top, spacing: 1) {
                ForEach(0..<Self.slotCount, id: \.self) { index in
                    Capsule()
                        .fill(networkUploadColor)
                        .frame(height: barHeight(upload[index], peak: peak))
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .frame(height: Self.halfHeight, alignment: .top)
        }
    }

    private func barHeight(_ value: Double?, peak: Double) -> CGFloat {
        guard let value, value > 0 else { return 1 }
        return max(1, Self.halfHeight * value / peak)
    }
}

/// A horizontal capacity bar: how full the boot volume is. The panel
/// uses rings where a value is a rate or a pressure; capacity is a
/// length, so it reads better as a bar you can compare against its
/// own track.
struct CapacityBar: View {
    let usedFraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor))
                Capsule()
                    .fill(capacityColor(usedFraction))
                    .frame(width: proxy.size.width * min(max(usedFraction, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

/// Green until the volume is uncomfortably full. The thresholds are
/// higher than the CPU/memory ones: a disk at 70% is fine, where
/// sustained 70% memory pressure is not.
private func capacityColor(_ fraction: Double) -> Color {
    if fraction < 0.75 { return Theme.green }
    if fraction < 0.90 { return Theme.orange }
    return Theme.red
}

// ─────────────────────────────────────────────────────────────────
// Disk hover detail: capacity figures + throughput history
// ─────────────────────────────────────────────────────────────────

struct DiskDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Disk Details")
            StatSectionCard(title: "Capacity") {
                VStack(alignment: .leading, spacing: 6) {
                    CapacityBar(usedFraction: statsStore.disk.usedPercent / 100)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledValueRow(label: "Used",
                                        value: formatBytes(statsStore.disk.usedBytes))
                        LabeledValueRow(label: "Free",
                                        value: formatBytes(statsStore.disk.freeBytes))
                        LabeledValueRow(label: "Total",
                                        value: formatBytes(statsStore.disk.totalBytes))
                    }
                }
            }
            StatSectionCard(title: "Activity") {
                VStack(alignment: .leading, spacing: 6) {
                    DiskActivityChart(points: statsStore.diskHistory)
                    BreakdownRow(color: diskReadColor, label: "Read",
                                 value: speedText(statsStore.disk.readBytesPerSecond))
                    BreakdownRow(color: diskWriteColor, label: "Write",
                                 value: speedText(statsStore.disk.writeBytesPerSecond))
                }
            }
        }
    }
}

/// Mirrored bars: reads above the centre line, writes below, scaled
/// to whichever direction peaked. Same shape as the network chart so
/// the two read alike.
private struct DiskActivityChart: View {
    let points: [DiskHistoryPoint]

    private static let halfHeight: CGFloat = 22

    var body: some View {
        let peak = max(
            points.map(\.readBytesPerSecond).max() ?? 0,
            points.map(\.writeBytesPerSecond).max() ?? 0,
            1
        )
        VStack(spacing: 1) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(points) { point in
                    Capsule()
                        .fill(diskReadColor)
                        .frame(height: barHeight(point.readBytesPerSecond, peak: peak))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: Self.halfHeight, alignment: .bottom)
            HStack(alignment: .top, spacing: 1) {
                ForEach(points) { point in
                    Capsule()
                        .fill(diskWriteColor)
                        .frame(height: barHeight(point.writeBytesPerSecond, peak: peak))
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .frame(height: Self.halfHeight, alignment: .top)
        }
    }

    private func barHeight(_ value: Double, peak: Double) -> CGFloat {
        guard value > 0 else { return 1 }
        return max(2, Self.halfHeight * value / peak)
    }
}

// ─────────────────────────────────────────────────────────────────
// Small reusable pieces
// ─────────────────────────────────────────────────────────────────

/// A rounded card with an uppercase section title - one per stat group.
/// `titleTrailing` puts a small live value at the title row's right
/// edge (e.g. the CPU card's "22% · 52°").
struct StatSectionCard<Content: View>: View {
    let title: String
    var titleTrailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.sectionTitle)
                Spacer()
                if let titleTrailing {
                    Text(titleTrailing)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.cardSurface)
        )
    }
}

/// "Label ............ value" row used everywhere in the panel.
struct LabeledValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

/// One colored arc of a SegmentedCircularGauge.
struct GaugeSegment {
    let color: Color
    let fraction: Double // 0...1 share of the full circle
}

/// A ring gauge whose fill is split into colored arcs (the iStat-style
/// memory ring). The unfilled remainder stays a neutral gray track.
/// One segment = a plain single-color gauge (used for pressure).
struct SegmentedCircularGauge: View {
    let segments: [GaugeSegment]
    let label: String
    var caption: String? = nil
    var size: CGFloat = 52

    private var lineWidth: CGFloat { max(5, size / 10) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: lineWidth)
            ForEach(arcs.indices, id: \.self) { index in
                let arc = arcs[index]
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90)) // start filling from 12 o'clock
            }
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: size * 0.25, weight: .semibold).monospacedDigit())
                if let caption {
                    Text(caption)
                        .font(.system(size: size * 0.12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Segments laid end to end around the ring, clamped to one lap.
    private var arcs: [(start: Double, end: Double, color: Color)] {
        var result: [(Double, Double, Color)] = []
        var cursor = 0.0
        for segment in segments {
            let end = min(cursor + max(segment.fraction, 0), 1)
            result.append((cursor, end, segment.color))
            cursor = end
        }
        return result
    }
}

