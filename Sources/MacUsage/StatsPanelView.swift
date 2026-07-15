import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// The dropdown panel that appears when you click the menu bar icon.
// Visual style loosely follows iStat Menus: grouped card sections
// with small uppercase headers, gauges, and clean rows.
// ─────────────────────────────────────────────────────────────────

/// Stat cards that can expand a detail column when hovered.
enum ExpandableSection {
    case cpu
    case memory
    case battery
    case network
    case fans
    case temperature
}


struct StatsPanelView: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Which card's detail panel is currently expanded, if any.
    @State private var expandedSection: ExpandableSection?
    /// The NSView hosting this SwiftUI view — how the detail panel
    /// controller finds the menu bar panel's window to sit beside.
    @State private var hostView: NSView?
    @State private var detailPanelController = DetailPanelController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !statsStore.activeAlerts.isEmpty {
                alertBanner
            }
            cpuSection
                .onHover { if $0 { expandedSection = .cpu } }
            memorySection
                .onHover { if $0 { expandedSection = .memory } }
            if statsStore.battery.isPresent {
                batterySection
                    .onHover { if $0 { expandedSection = .battery } }
            }
            networkSection
                .onHover { if $0 { expandedSection = .network } }
            temperaturesSection
                .onHover { if $0 { expandedSection = .temperature } }
            fansSection
                .onHover { if $0 { expandedSection = .fans } }
            bottomBar
        }
        .padding(12)
        .frame(width: 300)
        .background(HostingViewAccessor(view: $hostView))
        .onChange(of: expandedSection) { section in
            guard let section else {
                detailPanelController.hide()
                return
            }
            // The detail closes only when the pointer leaves both the
            // main panel and the detail panel — the controller watches
            // for that, so leaving an individual card never dismisses it.
            detailPanelController.onPointerLeftPanels = { expandedSection = nil }
            showDetail(for: section)
        }
        // The hosting view stays alive between panel opens, so
        // onDisappear never fires — the delegate tells us instead.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.panelWillHide)) { _ in
            expandedSection = nil
        }
    }

    /// Red banner at the top listing every firing threshold alert —
    /// the panel-side counterpart of the menu bar badge.
    private var alertBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(statsStore.activeAlerts) { alert in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(alert.message)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.15))
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
        StatSectionCard(title: "CPU") {
            HStack {
                Spacer()
                SegmentedCircularGauge(
                    segments: cpuGaugeSegments(statsStore.cpuUsage),
                    label: "\(Int(statsStore.cpuUsage.totalBusyPercent))%",
                    caption: "CPU",
                    size: 72
                )
                Spacer()
            }
        }
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
                        color: .pink,
                        fraction: statsStore.battery.healthPercent / 100
                    )],
                    label: "\(Int(statsStore.battery.healthPercent))%",
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
            HStack {
                Spacer()
                VStack(spacing: 2) {
                    Text(speedText(statsStore.networkSpeed.uploadBytesPerSecond))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    Text("↑ Upload")
                        .font(.caption2)
                        .foregroundStyle(networkUploadColor)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(speedText(statsStore.networkSpeed.downloadBytesPerSecond))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    Text("↓ Download")
                        .font(.caption2)
                        .foregroundStyle(networkDownloadColor)
                }
                Spacer()
            }
        }
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
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
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

/// The colored arcs for the CPU ring: user + system over the gray
/// idle track. Same colors as the hover breakdown's dots.
private let cpuUserColor: Color = .blue
private let cpuSystemColor: Color = .orange

private func cpuGaugeSegments(_ cpu: CpuUsageSnapshot) -> [GaugeSegment] {
    [
        GaugeSegment(color: cpuUserColor, fraction: cpu.userPercent / 100),
        GaugeSegment(color: cpuSystemColor, fraction: cpu.systemPercent / 100),
    ]
}

/// The colored arcs for the memory ring: App / Wired / Compressed,
/// each as its share of total RAM. Free stays the gray base track.
private func memoryGaugeSegments(_ memory: MemoryUsageSnapshot) -> [GaugeSegment] {
    let totalBytes = Double(memory.totalBytes)
    guard totalBytes > 0 else { return [] }
    return [
        GaugeSegment(color: .blue, fraction: Double(memory.breakdown.appBytes) / totalBytes),
        GaugeSegment(color: .pink, fraction: Double(memory.breakdown.wiredBytes) / totalBytes),
        GaugeSegment(color: .yellow, fraction: Double(memory.breakdown.compressedBytes) / totalBytes),
    ]
}

/// Green when relaxed, orange when strained, red when critical —
/// same thresholds the plain gauges use.
private func pressureColor(_ percent: Double) -> Color {
    if percent < 50 { return .green }
    if percent < 80 { return .orange }
    return .red
}

/// Upload/download accent colors (match the iStat-style chart).
private let networkUploadColor: Color = .pink
private let networkDownloadColor: Color = .blue

/// "33.8 MB/s"-style throughput formatting.
private func speedText(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    return formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
}

/// Blue while charging, then green/orange/red as the level drops.
private func batteryLevelColor(_ battery: BatterySnapshot) -> Color {
    if battery.isCharging { return .blue }
    if battery.levelPercent > 50 { return .green }
    if battery.levelPercent > 20 { return .orange }
    return .red
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
            StatSectionCard(title: "Breakdown") {
                VStack(alignment: .leading, spacing: 4) {
                    BreakdownRow(color: .blue, label: "App",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.appBytes))
                    BreakdownRow(color: .pink, label: "Wired",
                                 value: formatBytes(statsStore.memoryUsage.breakdown.wiredBytes))
                    BreakdownRow(color: .yellow, label: "Compressed",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "Network Details")
            StatSectionCard(title: "Activity") {
                NetworkHistoryChart(points: statsStore.networkHistory)
            }
            StatSectionCard(title: "Connection") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "Wi-Fi",
                        value: statsStore.networkDetails.info.wifiName ?? "—"
                    )
                    LabeledValueRow(
                        label: "Public IP",
                        value: statsStore.networkDetails.info.publicIP ?? "…"
                    )
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
/// downward (blue). Each direction is normalized to its own peak —
/// download usually dwarfs upload, and a shared scale would flatten
/// the upload half into invisibility.
private struct NetworkHistoryChart: View {
    let points: [NetworkHistoryPoint]

    private static let capacity = 60
    private static let halfHeight: CGFloat = 28

    var body: some View {
        let padded = Self.paddedPoints(points)
        let peakUpload = max(points.map(\.uploadBytesPerSecond).max() ?? 0, 1)
        let peakDownload = max(points.map(\.downloadBytesPerSecond).max() ?? 0, 1)

        VStack(spacing: 4) {
            VStack(spacing: 1) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(padded.enumerated()), id: \.offset) { _, point in
                        Capsule()
                            .fill(networkUploadColor)
                            .frame(height: barHeight(point?.uploadBytesPerSecond, peak: peakUpload))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: Self.halfHeight, alignment: .bottom)
                HStack(alignment: .top, spacing: 1) {
                    ForEach(Array(padded.enumerated()), id: \.offset) { _, point in
                        Capsule()
                            .fill(networkDownloadColor)
                            .frame(height: barHeight(point?.downloadBytesPerSecond, peak: peakDownload))
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

    /// Right-align recent samples: pad the left with nils until full.
    private static func paddedPoints(_ points: [NetworkHistoryPoint]) -> [NetworkHistoryPoint?] {
        let missing = max(0, capacity - points.count)
        return Array(repeating: nil, count: missing) + points.suffix(capacity).map { $0 }
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
                        value: statsStore.timeOnBatteryMinutes.map(minutesText) ?? "—"
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
/// hours without any reading render as faint stubs.
private struct BatteryHistoryChart: View {
    let points: [BatteryHistoryPoint]

    private static let barAreaHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(points) { point in
                    if let level = point.levelPercent {
                        Capsule()
                            .fill(barColor(level))
                            .frame(height: max(4, Self.barAreaHeight * level / 100))
                            .frame(maxWidth: .infinity)
                            .help(String(format: "%@ — %.0f%%", Self.hourLabel(point.id), level))
                    } else {
                        Capsule()
                            .fill(Color.gray.opacity(0.25))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: Self.barAreaHeight, alignment: .bottom)
            HStack {
                if let first = points.first {
                    Text(Self.hourLabel(first.id))
                }
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func barColor(_ level: Double) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .orange }
        return .red
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
                                LabeledValueRow(label: "Target", value: rpmText(fan.targetRpm))
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
    rpm < 1 ? "—" : "\(Int(rpm)) RPM"
}

/// Current speed as a share of the fan's maximum (0 when unknown).
private func fanSpeedFraction(_ fan: FanDetailReading) -> Double {
    guard fan.maxRpm > 0 else { return 0 }
    return min(fan.currentRpm / fan.maxRpm, 1)
}

private func fanColor(_ fan: FanDetailReading) -> Color {
    let fraction = fanSpeedFraction(fan)
    if fraction < 0.6 { return .green }
    if fraction < 0.85 { return .orange }
    return .red
}

// ─────────────────────────────────────────────────────────────────
// Temperature hover detail: every sensor, grouped by category
// ─────────────────────────────────────────────────────────────────

struct TemperatureDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Grid of chips vs. named sensor rows — remembered across opens.
    @AppStorage("showsTemperatureSensorNames") private var showsSensorNames = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DetailColumnHeader(title: "Temperature Details")
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
/// labeled with its SMC key — the hardware's real sensor identity.
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

private struct TemperatureChip: View {
    let celsius: Double

    var body: some View {
        Text(String(format: "%.0f°", celsius))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(temperatureColor(celsius))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(temperatureColor(celsius).opacity(0.18))
            )
    }
}

/// Cool → hot color scale shared by all heat chips.
private func temperatureColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<35: return .teal
    case ..<50: return .green
    case ..<65: return .yellow
    case ..<80: return .orange
    default:    return .red
    }
}

// ─────────────────────────────────────────────────────────────────
// CPU hover detail: breakdown + top processes
// ─────────────────────────────────────────────────────────────────

struct CpuDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailColumnHeader(title: "CPU Details")
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

// ─────────────────────────────────────────────────────────────────
// Small reusable pieces
// ─────────────────────────────────────────────────────────────────

/// A rounded card with an uppercase section title — one per stat group.
struct StatSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.12))
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

