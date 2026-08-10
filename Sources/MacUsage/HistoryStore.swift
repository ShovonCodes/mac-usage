import Foundation

// ─────────────────────────────────────────────────────────────────
// The 24 hour record, kept on disk.
//
// Two tiers, because the live charts and the trend charts want
// different things:
//
//  • In memory, StatsStore keeps every sample at full rate (2 s) for
//    the last few minutes. That is what the panel's live charts draw.
//    It is deliberately not persisted: 2 s resolution over a day is
//    43,200 samples per series, and nothing reads it at that detail.
//
//  • Here, one row per minute for the last 24 hours. 1,440 rows,
//    which is small enough to rewrite whole once a minute and answers
//    the question the live charts cannot: what happened while I was
//    away.
//
// 24 hours is not arbitrary. Battery history already seeded a day
// from `pmset -g log`, so every series in the app now shares one
// horizon.
//
// Writes are atomic (write a sibling file, then rename), so a crash
// or a power cut during a save leaves the previous good file in place
// rather than a half-written one. A file that fails to parse is
// discarded rather than repaired: losing a day of graphs is a much
// smaller cost than refusing to launch.
// ─────────────────────────────────────────────────────────────────

/// One minute of averages. Written once per minute, so field names
/// stay short: they are repeated 1,440 times in the file.
struct HistoryMinute: Codable, Identifiable {
    /// Whole minutes since 1970. Compact, sorts correctly, and avoids
    /// storing 1,440 ISO date strings.
    let m: Int
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var memoryPressure: Double = 0
    var networkUp: Double = 0
    var networkDown: Double = 0
    /// Absent when no CPU temperature sensor has reported yet.
    var cpuTemperature: Double?
    /// Absent when no GPU reported during the minute. Optional for the
    /// same reason as the temperature, and additionally so that files
    /// written before this series existed still decode: a missing key
    /// is a valid nil, where a non-optional would fail the whole file
    /// and throw away the user's day of history.
    var gpuUtilization: Double?
    /// Total system power in watts. Optional for the same three
    /// reasons as `gpuUtilization`: Macs that publish no SMC power rail
    /// have no reading, a zero would be a lie, and files written before
    /// this series existed must still decode.
    var systemPowerWatts: Double?

    var id: Int { m }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(m) * 60) }
    var cpuBusy: Double { cpuUser + cpuSystem }
}

@MainActor
final class HistoryStore {

    /// 24 hours at one row per minute.
    private static let retainedMinutes = 1_440

    /// Completed minutes, oldest first.
    private(set) var minutes: [HistoryMinute] = []

    /// Samples for the minute currently in progress. Averaged and
    /// moved into `minutes` when the clock rolls over, so a minute is
    /// only ever published once it is complete.
    private var pendingMinute: Int?
    private var pending: [HistoryMinute] = []

    private let fileURL: URL?

    init(fileURL: URL? = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Recording

    /// Fold one live sample in. Called on every fast tick; the cost is
    /// an append plus, once a minute, an average and a file write.
    /// `now` is injected so the rollover logic is testable.
    func record(cpuUser: Double,
                cpuSystem: Double,
                memoryPressure: Double,
                networkUp: Double,
                networkDown: Double,
                cpuTemperature: Double?,
                gpuUtilization: Double?,
                systemPowerWatts: Double?,
                now: Date = Date()) {
        let minute = Int(now.timeIntervalSince1970 / 60)

        if let pendingMinute, pendingMinute != minute {
            flush(minute: pendingMinute)
        }
        self.pendingMinute = minute
        pending.append(HistoryMinute(
            m: minute,
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            memoryPressure: memoryPressure,
            networkUp: networkUp,
            networkDown: networkDown,
            cpuTemperature: cpuTemperature,
            gpuUtilization: gpuUtilization,
            systemPowerWatts: systemPowerWatts
        ))
    }

    /// Average the pending samples into one row and persist.
    private func flush(minute: Int) {
        defer { pending.removeAll(keepingCapacity: true) }
        guard !pending.isEmpty else { return }

        let count = Double(pending.count)
        let row = HistoryMinute(
            m: minute,
            cpuUser: pending.reduce(0) { $0 + $1.cpuUser } / count,
            cpuSystem: pending.reduce(0) { $0 + $1.cpuSystem } / count,
            memoryPressure: pending.reduce(0) { $0 + $1.memoryPressure } / count,
            networkUp: pending.reduce(0) { $0 + $1.networkUp } / count,
            networkDown: pending.reduce(0) { $0 + $1.networkDown } / count,
            cpuTemperature: averageOfPresent(\.cpuTemperature),
            gpuUtilization: averageOfPresent(\.gpuUtilization),
            systemPowerWatts: averageOfPresent(\.systemPowerWatts)
        )

        minutes.append(row)
        prune(now: row.date)
        save()
    }

    /// Average the samples that actually carried a value, or nil when
    /// none did. The distinction matters: a minute with no temperature
    /// sensor and a minute at 0 degrees are not the same reading, and
    /// averaging absences in as zeroes would drag a real series down.
    private func averageOfPresent(_ field: KeyPath<HistoryMinute, Double?>) -> Double? {
        let values = pending.compactMap { $0[keyPath: field] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Force the in-progress minute out to disk. Used on quit, where
    /// waiting for the rollover would lose up to a minute.
    func flushPending() {
        if let pendingMinute {
            flush(minute: pendingMinute)
            self.pendingMinute = nil
        }
    }

    private func prune(now: Date) {
        let oldest = Int(now.timeIntervalSince1970 / 60) - Self.retainedMinutes
        minutes.removeAll { $0.m < oldest }
        if minutes.count > Self.retainedMinutes {
            minutes.removeFirst(minutes.count - Self.retainedMinutes)
        }
    }

    // MARK: Queries

    /// Rows from the last `hours`, oldest first.
    func recent(hours: Double, now: Date = Date()) -> [HistoryMinute] {
        let cutoff = Int(now.timeIntervalSince1970 / 60) - Int(hours * 60)
        return minutes.filter { $0.m >= cutoff }
    }

    // MARK: Persistence

    nonisolated static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("MacUsage", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("history.json")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([HistoryMinute].self, from: data) else {
            // Unreadable or from an incompatible version. Start over
            // rather than fail: graphs are not worth blocking launch.
            return
        }
        minutes = decoded.sorted { $0.m < $1.m }
        prune(now: Date())
    }

    func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(minutes) else { return }
        // Write beside the target, then rename. Rename is atomic, so a
        // reader never sees a partial file and a crash mid-write
        // cannot destroy the previous good one.
        let temporaryURL = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
