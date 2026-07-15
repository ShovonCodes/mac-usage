import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// The dropdown panel that appears when you click the menu bar icon.
// Visual style loosely follows iStat Menus: grouped card sections
// with small uppercase headers, gauges, and clean rows.
// ─────────────────────────────────────────────────────────────────

/// Stat cards that can expand a detail column when hovered.
enum ExpandableSection {
    case memory
}

struct StatsPanelView: View {
    @EnvironmentObject var statsStore: StatsStore

    /// Which card's detail panel is currently expanded, if any.
    @State private var expandedSection: ExpandableSection?
    /// Pending "collapse the detail panel" action; cancelled whenever
    /// the pointer re-enters the card or the detail panel itself.
    @State private var collapseWorkItem: DispatchWorkItem?
    /// The NSView hosting this SwiftUI view — how the detail panel
    /// controller finds the menu bar panel's window to sit beside.
    @State private var hostView: NSView?
    @State private var detailPanelController = DetailPanelController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cpuSection
            memorySection
                .onHover { hover(.memory, isInside: $0) }
            fansSection
            temperaturesSection
            bottomBar
        }
        .padding(12)
        .frame(width: 300)
        .background(HostingViewAccessor(view: $hostView))
        .onChange(of: expandedSection) { section in
            if section == .memory {
                detailPanelController.show(
                    content: memoryDetailContent,
                    besideWindowContaining: hostView
                )
            } else {
                detailPanelController.hide()
            }
        }
        // Tell the store when the panel opens/closes so it can switch
        // between the fast (2s) and idle (15s) refresh intervals.
        .onAppear { statsStore.panelDidOpen() }
        .onDisappear {
            detailPanelController.hide()
            expandedSection = nil
            statsStore.panelDidClose()
        }
    }

    private var memoryDetailContent: some View {
        MemoryDetailColumn()
            .environmentObject(statsStore)
            .frame(width: 240)
            .padding(12)
            .onHover { hover(.memory, isInside: $0) }
    }

    // MARK: Hover expansion

    /// Expands `section` while the pointer is over its card or its
    /// detail panel. Collapsing is slightly delayed so the pointer
    /// can cross the gap between the two without the panel vanishing.
    private func hover(_ section: ExpandableSection, isInside: Bool) {
        collapseWorkItem?.cancel()
        if isInside {
            expandedSection = section
        } else {
            let workItem = DispatchWorkItem { expandedSection = nil }
            collapseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        StatSectionCard(title: "CPU") {
            HStack(spacing: 14) {
                CircularGauge(
                    percent: statsStore.cpuUsage.totalBusyPercent,
                    label: "\(Int(statsStore.cpuUsage.totalBusyPercent))%"
                )
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "User",
                        value: String(format: "%.1f%%", statsStore.cpuUsage.userPercent)
                    )
                    LabeledValueRow(
                        label: "System",
                        value: String(format: "%.1f%%", statsStore.cpuUsage.systemPercent)
                    )
                }
            }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        StatSectionCard(title: "Memory") {
            HStack(spacing: 14) {
                SegmentedCircularGauge(
                    segments: [GaugeSegment(
                        color: pressureColor(statsStore.memoryUsage.pressurePercent),
                        fraction: statsStore.memoryUsage.pressurePercent / 100
                    )],
                    label: "\(Int(statsStore.memoryUsage.pressurePercent))%",
                    caption: "PRESSURE",
                    size: 56
                )
                SegmentedCircularGauge(
                    segments: memoryGaugeSegments(statsStore.memoryUsage),
                    label: "\(Int(statsStore.memoryUsage.usedPercent))%",
                    caption: "MEMORY",
                    size: 56
                )
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueRow(
                        label: "Used",
                        value: formatBytes(statsStore.memoryUsage.usedBytes)
                    )
                    LabeledValueRow(
                        label: "Total",
                        value: formatBytes(statsStore.memoryUsage.totalBytes)
                    )
                }
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

// ─────────────────────────────────────────────────────────────────
// Memory hover detail: breakdown + top processes
// ─────────────────────────────────────────────────────────────────

struct MemoryDetailColumn: View {
    @EnvironmentObject var statsStore: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            gaugesCard
            StatSectionCard(title: "Breakdown") {
                VStack(alignment: .leading, spacing: 4) {
                    BreakdownRow(color: .blue, label: "App",
                                 bytes: statsStore.memoryUsage.breakdown.appBytes)
                    BreakdownRow(color: .pink, label: "Wired",
                                 bytes: statsStore.memoryUsage.breakdown.wiredBytes)
                    BreakdownRow(color: .yellow, label: "Compressed",
                                 bytes: statsStore.memoryUsage.breakdown.compressedBytes)
                    BreakdownRow(color: .gray, label: "Free",
                                 bytes: statsStore.memoryUsage.breakdown.freeBytes)
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
                            ProcessMemoryRow(process: process)
                        }
                    }
                }
            }
        }
    }

    /// The two big rings on top: pressure (one color) and usage
    /// (segmented like the main card's gauge).
    private var gaugesCard: some View {
        HStack {
            Spacer()
            SegmentedCircularGauge(
                segments: [GaugeSegment(
                    color: pressureColor(statsStore.memoryUsage.pressurePercent),
                    fraction: statsStore.memoryUsage.pressurePercent / 100
                )],
                label: "\(Int(statsStore.memoryUsage.pressurePercent))%",
                caption: "PRESSURE",
                size: 64
            )
            Spacer()
            SegmentedCircularGauge(
                segments: memoryGaugeSegments(statsStore.memoryUsage),
                label: "\(Int(statsStore.memoryUsage.usedPercent))%",
                caption: "MEMORY",
                size: 64
            )
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
    }
}

private struct BreakdownRow: View {
    let color: Color
    let label: String
    let bytes: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes))
                .font(.callout.monospacedDigit())
        }
    }
}

private struct ProcessMemoryRow: View {
    let process: ProcessMemoryUsage

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon(forExecutablePath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(formatBytes(process.memoryBytes))
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

/// The circular progress ring used for CPU % and memory %.
struct CircularGauge: View {
    let percent: Double   // 0...100
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(
                    gaugeColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90)) // start filling from 12 o'clock
                .animation(.easeInOut(duration: 0.4), value: percent)
            Text(label)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .frame(width: 52, height: 52)
    }

    /// Green when relaxed, orange when busy, red when maxed out.
    private var gaugeColor: Color {
        if percent < 60 { return .green }
        if percent < 85 { return .orange }
        return .red
    }
}
