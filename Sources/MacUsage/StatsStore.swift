import Foundation
import SwiftUI
import Combine

// ─────────────────────────────────────────────────────────────────
// The single place that owns all readers and the refresh timer.
//
// Refresh strategy (as requested):
//   • Panel open   → refresh every 2 seconds  (feels live)
//   • Panel closed → refresh every 15 seconds (keeps data warm for
//     the next open, at almost no energy cost)
//
// The SwiftUI views watch this object via @Published properties and
// re-render automatically whenever new values arrive.
//
// ── How to extend ────────────────────────────────────────────────
// To add a new stat (network, disk, battery, ...):
//   1. Create a new reader class in Readers/ (see existing ones).
//   2. Add a @Published property here for its snapshot.
//   3. Call the reader inside refreshAllStats().
//   4. Add a section for it in StatsPanelView.
// ─────────────────────────────────────────────────────────────────

@MainActor
final class StatsStore: ObservableObject {

    // Latest values the UI displays.
    @Published var cpuUsage = CpuUsageSnapshot()
    @Published var cpuHistory: [CpuHistoryPoint] = []
    @Published var cpuDetails = CpuDetails()
    @Published var memoryUsage = MemoryUsageSnapshot()
    @Published var memoryDetails = MemoryDetails()
    @Published var networkSpeed = NetworkSpeedSnapshot()
    @Published var networkHistory: [NetworkHistoryPoint] = []
    @Published var networkDetails = NetworkDetails()
    @Published var disk = DiskSnapshot()
    @Published var diskHistory: [DiskHistoryPoint] = []
    @Published var battery = BatterySnapshot()
    @Published var batteryHistory: [BatteryHistoryPoint] = []
    /// Minutes since the Mac was last on AC power (nil while plugged in).
    @Published var timeOnBatteryMinutes: Int?
    @Published var fans: [FanReading] = []
    @Published var fanDetails: [FanDetailReading] = []
    @Published var averageTemperatures: [TemperatureCategory: Double] = [:]
    @Published var temperatures: [TemperatureReading] = []
    /// Threshold alerts currently firing (drives the menu bar badge
    /// and the red banner at the top of the panel).
    @Published var activeAlerts: [StatAlert] = []
    /// The 24 hour record, restored from disk at launch. Drives the
    /// trend charts and survives relaunches.
    let history = HistoryStore()

    // The readers that actually collect the data.
    private let cpuReader = CpuUsageReader()
    private let cpuDetailsReader = CpuDetailsReader()
    private let memoryReader = MemoryUsageReader()
    private let memoryDetailsReader = MemoryDetailsReader()
    private let diskReader = DiskReader()
    private let batteryReader = BatteryReader()
    private let batteryHistoryReader = BatteryHistoryReader()
    private let networkSpeedReader = NetworkSpeedReader()
    private let networkInfoReader = NetworkInfoReader()
    private let sensorReader = FanAndTemperatureReader()

    // Refresh timing, split into two lanes.
    //
    // The fast lane is only ever three in-process syscalls
    // (host_processor_info, sysctlbyname, NET_RT_IFLIST2), so it can
    // run often for almost nothing. The slow lane is everything that
    // talks to the SMC or spawns a subprocess, and must not.
    //
    // Today both lanes use the same cadence, so this is a pure
    // restructuring. It exists so the menu bar strip can later keep
    // the fast lane at 2s while the panel is closed, without dragging
    // the SMC along with it.
    private let fastIntervalWhenPanelOpen: TimeInterval = 2
    /// With the strip on, the menu bar is showing these numbers even
    /// when the panel is shut, so the fast lane keeps its pace.
    private let fastIntervalWhenStripVisible: TimeInterval = 2
    private let fastIntervalWhenIdle: TimeInterval = 15
    private let slowIntervalWhenPanelOpen: TimeInterval = 2
    private let slowIntervalWhenIdle: TimeInterval = 15
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var isPanelOpen = false
    private var isStripVisible = MenuBarSettings.isStripEnabled
    private var defaultsSubscription: AnyCancellable?

    /// Bumped at the end of every fast tick. The AppDelegate watches
    /// this to redraw the menu bar strip: subscribing to the
    /// individual @Published values instead would fire several times
    /// per tick, and would depend on which one happens to be assigned
    /// last inside refreshFastStats.
    @Published private(set) var menuBarTick: UInt64 = 0

    // The process list samples with `top`, which costs ~0.5s of CPU
    // per run — too heavy for every 2s tick, so it gets its own pace.
    private let memoryDetailsSampleInterval: TimeInterval = 6
    private var lastMemoryDetailsSample = Date.distantPast

    // Network info spawns ipconfig and makes a (cached) public-IP
    // request — slow cadence is plenty.
    private let networkInfoSampleInterval: TimeInterval = 10
    private var lastNetworkInfoSample = Date.distantPast
    /// CPU usage history for the chart (last 60 ticks).
    private let historyCapacity = 60
    /// Network samples are timestamped and the chart shows a fixed
    /// five-minute window — keep enough for that even at the fast
    /// 2-second cadence (200 × 2 s ≈ 6.7 min).
    private let networkHistoryCapacity = 200
    /// Disk throughput is sampled on the slow lane, so far fewer
    /// points cover the same span as the network chart.
    private let diskHistoryCapacity = 60

    /// When any stat crosses these, an alert fires.
    private struct AlertThresholds {
        var cpuBusyPercent: Double
        var memoryPressurePercent: Double
        var cpuTemperatureCelsius: Double
        var batteryLowPercent: Double
    }

    private let alertThresholds = AlertThresholds(
        cpuBusyPercent: 90,
        memoryPressurePercent: 80,
        cpuTemperatureCelsius: 90,
        batteryLowPercent: 10
    )

    init() {
        // Take a first sample right away so the first panel open isn't empty.
        // (CPU % needs two samples to show a real number; this is sample #1.)
        seedLiveChartsFromHistory()
        refreshFastStats()
        refreshSlowStats()
        restartTimers()

        // Toggling the strip changes how often the fast lane has to
        // run, so the timers follow the setting.
        defaultsSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyStripVisibilityChange() }
            }
    }

    /// Refill the live CPU and network charts from the persisted
    /// record so they are not blank for two minutes after a relaunch.
    /// Only one point per minute exists at this resolution, so the
    /// charts come back sparse rather than solid. That is honest:
    /// time-bucketed charts draw those as the isolated samples they
    /// are instead of implying continuous data.
    private func seedLiveChartsFromHistory() {
        for row in history.recent(hours: 0.25) {
            cpuHistory.append(CpuHistoryPoint(
                id: row.date, userPercent: row.cpuUser, systemPercent: row.cpuSystem
            ))
            networkHistory.append(NetworkHistoryPoint(
                id: row.date,
                uploadBytesPerSecond: row.networkUp,
                downloadBytesPerSecond: row.networkDown
            ))
        }
    }

    /// UserDefaults posts on any change, so restart only when the one
    /// setting that affects timing actually flipped.
    private func applyStripVisibilityChange() {
        let isVisible = MenuBarSettings.isStripEnabled
        guard isVisible != isStripVisible else { return }
        isStripVisible = isVisible
        restartTimers()
    }

    // MARK: Panel open/close — called by the view

    func panelDidOpen() {
        isPanelOpen = true
        // Show fresh numbers immediately.
        refreshFastStats()
        refreshSlowStats()
        restartTimers()
    }

    func panelDidClose() {
        isPanelOpen = false
        restartTimers()
    }

    // MARK: Refreshing

    private var fastInterval: TimeInterval {
        if isPanelOpen { return fastIntervalWhenPanelOpen }
        return isStripVisible ? fastIntervalWhenStripVisible : fastIntervalWhenIdle
    }

    private func restartTimers() {
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(
            withTimeInterval: fastInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFastStats() }
        }

        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(
            withTimeInterval: isPanelOpen ? slowIntervalWhenPanelOpen : slowIntervalWhenIdle,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSlowStats() }
        }
    }

    /// The fast lane: three syscalls plus their history buffers.
    /// Cheap enough for the main thread, and the only thing the menu
    /// bar strip will need.
    private func refreshFastStats() {
        cpuUsage = cpuReader.readCurrentUsage()
        memoryUsage = memoryReader.readCurrentUsage()

        cpuHistory.append(CpuHistoryPoint(
            id: Date(),
            userPercent: cpuUsage.userPercent,
            systemPercent: cpuUsage.systemPercent
        ))
        if cpuHistory.count > historyCapacity {
            cpuHistory.removeFirst(cpuHistory.count - historyCapacity)
        }

        networkSpeed = networkSpeedReader.readCurrentSpeed()
        networkHistory.append(NetworkHistoryPoint(
            id: Date(),
            uploadBytesPerSecond: networkSpeed.uploadBytesPerSecond,
            downloadBytesPerSecond: networkSpeed.downloadBytesPerSecond
        ))
        if networkHistory.count > networkHistoryCapacity {
            networkHistory.removeFirst(networkHistory.count - networkHistoryCapacity)
        }

        evaluateAlerts()

        // Fold this sample into the 24 hour record. Costs an append,
        // and once a minute an average and a file write.
        history.record(
            cpuUser: cpuUsage.userPercent,
            cpuSystem: cpuUsage.systemPercent,
            memoryPressure: memoryUsage.pressurePercent,
            networkUp: networkSpeed.uploadBytesPerSecond,
            networkDown: networkSpeed.downloadBytesPerSecond,
            cpuTemperature: averageTemperatures[.cpu]
        )

        menuBarTick &+= 1
    }

    /// Called from applicationWillTerminate: the minute in progress
    /// would otherwise be lost.
    func persistBeforeQuit() {
        history.flushPending()
        history.save()
    }

    /// The slow lane: anything touching the SMC, a subprocess, or the
    /// network. Several of these carry their own extra gating on top
    /// of the timer (see the sample-interval properties above).
    private func refreshSlowStats() {
        battery = batteryReader.readSnapshot()

        // IO registry walk: cheap, but not fast-lane cheap, and disk
        // rates do not need two-second resolution to be useful.
        disk = diskReader.readSnapshot()
        diskHistory.append(DiskHistoryPoint(
            id: Date(),
            readBytesPerSecond: disk.readBytesPerSecond,
            writeBytesPerSecond: disk.writeBytesPerSecond
        ))
        if diskHistory.count > diskHistoryCapacity {
            diskHistory.removeFirst(diskHistory.count - diskHistoryCapacity)
        }

        // History needs the fresh level; its first call also seeds
        // 24h of readings from the power log (~2s), so keep it off
        // the main thread. The same task refreshes the powerd health
        // number (system_profiler, ~0.2s) — a no-op except hourly.
        if battery.isPresent {
            let batteryReader = self.batteryReader
            let batteryHistoryReader = self.batteryHistoryReader
            let level = battery.levelPercent
            let isOnBattery = !battery.isPluggedIn
            Task.detached(priority: .utility) {
                batteryReader.refreshHealthFromPowerdIfStale()
                let result = batteryHistoryReader.recordAndBucket(
                    levelPercent: level,
                    isOnBattery: isOnBattery
                )
                await MainActor.run { [weak self] in
                    self?.batteryHistory = result.points
                    self?.timeOnBatteryMinutes = result.timeOnBatteryMinutes
                }
            }
        }

        // SMC calls talk to a kernel driver; run them off the main thread
        // so the UI never stutters, then publish results back on main.
        let sensorReader = self.sensorReader
        Task.detached(priority: .utility) {
            let fanDetails = sensorReader.readFanDetails()
            let temperatureReadings = sensorReader.readTemperatures()
            let averages = FanAndTemperatureReader.averageTemperatures(from: temperatureReadings)
            await MainActor.run { [weak self] in
                self?.fanDetails = fanDetails
                self?.fans = fanDetails.map { FanReading(id: $0.id, speedRpm: $0.currentRpm) }
                self?.temperatures = temperatureReadings
                self?.averageTemperatures = averages
                self?.evaluateAlerts() // temps arrive late — re-check
            }
        }
        evaluateAlerts()

        // CPU process list is one cheap `ps` call — refresh it on every
        // tick while the panel is open, off the main thread.
        if isPanelOpen {
            let cpuDetailsReader = self.cpuDetailsReader
            Task.detached(priority: .utility) {
                let details = cpuDetailsReader.readCurrentDetails()
                await MainActor.run { [weak self] in
                    self?.cpuDetails = details
                }
            }
        }

        // Network info stays off the main thread and only runs while
        // the panel is open, on a slow cadence.
        if isPanelOpen,
           Date().timeIntervalSince(lastNetworkInfoSample) >= networkInfoSampleInterval {
            lastNetworkInfoSample = Date()
            let networkInfoReader = self.networkInfoReader
            Task.detached(priority: .utility) {
                let info = networkInfoReader.readInfo()
                await MainActor.run { [weak self] in
                    self?.networkDetails = NetworkDetails(info: info)
                }
            }
        }

        // Memory details spawn a `top` sample — only worth doing while
        // someone can see the panel, never on the main thread, and at
        // most every few seconds (see memoryDetailsSampleInterval).
        if isPanelOpen,
           Date().timeIntervalSince(lastMemoryDetailsSample) >= memoryDetailsSampleInterval {
            lastMemoryDetailsSample = Date()
            let memoryDetailsReader = self.memoryDetailsReader
            Task.detached(priority: .utility) {
                let details = memoryDetailsReader.readCurrentDetails()
                await MainActor.run { [weak self] in
                    self?.memoryDetails = details
                }
            }
        }
    }

    // MARK: Threshold alerts

    private func evaluateAlerts() {
        var alerts: [StatAlert] = []

        if cpuUsage.totalBusyPercent > alertThresholds.cpuBusyPercent {
            alerts.append(StatAlert(
                id: "cpu",
                message: String(format: "CPU at %.0f%%", cpuUsage.totalBusyPercent)
            ))
        }
        if memoryUsage.pressurePercent > alertThresholds.memoryPressurePercent {
            alerts.append(StatAlert(
                id: "memory",
                message: String(format: "Memory pressure at %.0f%%", memoryUsage.pressurePercent)
            ))
        }
        if let cpuTemperature = averageTemperatures[.cpu],
           cpuTemperature > alertThresholds.cpuTemperatureCelsius {
            alerts.append(StatAlert(
                id: "temperature",
                message: String(format: "CPU temperature at %.0f°", cpuTemperature)
            ))
        }
        if battery.isPresent, !battery.isPluggedIn,
           battery.levelPercent < alertThresholds.batteryLowPercent {
            alerts.append(StatAlert(
                id: "battery",
                message: String(format: "Battery at %.0f%%", battery.levelPercent)
            ))
        }

        // Publish only on change — the menu bar icon redraws on this.
        if alerts != activeAlerts {
            activeAlerts = alerts
        }
    }
}
