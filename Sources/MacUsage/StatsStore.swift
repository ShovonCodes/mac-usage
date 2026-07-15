import Foundation
import SwiftUI

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
    @Published var cpuDetails = CpuDetails()
    @Published var memoryUsage = MemoryUsageSnapshot()
    @Published var memoryDetails = MemoryDetails()
    @Published var fans: [FanReading] = []
    @Published var fanDetails: [FanDetailReading] = []
    @Published var averageTemperatures: [TemperatureCategory: Double] = [:]
    @Published var temperatures: [TemperatureReading] = []

    // The readers that actually collect the data.
    private let cpuReader = CpuUsageReader()
    private let cpuDetailsReader = CpuDetailsReader()
    private let memoryReader = MemoryUsageReader()
    private let memoryDetailsReader = MemoryDetailsReader()
    private let sensorReader = FanAndTemperatureReader()

    // Refresh timing.
    private let refreshIntervalWhenPanelOpen: TimeInterval = 2
    private let refreshIntervalWhenIdle: TimeInterval = 15
    private var refreshTimer: Timer?
    private var isPanelOpen = false

    // The process list samples with `top`, which costs ~0.5s of CPU
    // per run — too heavy for every 2s tick, so it gets its own pace.
    private let memoryDetailsSampleInterval: TimeInterval = 6
    private var lastMemoryDetailsSample = Date.distantPast

    init() {
        // Take a first sample right away so the first panel open isn't empty.
        // (CPU % needs two samples to show a real number; this is sample #1.)
        refreshAllStats()
        startTimer(interval: refreshIntervalWhenIdle)
    }

    // MARK: Panel open/close — called by the view

    func panelDidOpen() {
        isPanelOpen = true
        refreshAllStats() // show fresh numbers immediately
        startTimer(interval: refreshIntervalWhenPanelOpen)
    }

    func panelDidClose() {
        isPanelOpen = false
        startTimer(interval: refreshIntervalWhenIdle)
    }

    // MARK: Refreshing

    private func startTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllStats()
            }
        }
    }

    private func refreshAllStats() {
        // CPU and memory are cheap — read them on the main thread.
        cpuUsage = cpuReader.readCurrentUsage()
        memoryUsage = memoryReader.readCurrentUsage()

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
            }
        }

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
}
