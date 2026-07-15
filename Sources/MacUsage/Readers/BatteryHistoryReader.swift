import Foundation

// ─────────────────────────────────────────────────────────────────
// Builds the "battery level over the last 24 hours" chart data.
//
// Two sources, merged:
//   1. A one-time seed from `pmset -g log`, whose sleep/wake/charge
//     entries carry "(Charge: NN%)" markers — this gives history
//     from before the app was even running (~2s, done once, off the
//     main thread).
//   2. Live samples recorded on every refresh tick while the app runs.
//
// Readings collapse into 24 hourly buckets (latest reading wins per
// hour). Hours with no reading at all stay nil and render as gaps.
// ─────────────────────────────────────────────────────────────────

final class BatteryHistoryReader {

    /// timestamp → battery percent. Protected by `lock`: the seed and
    /// the tick samples arrive on different background tasks.
    private var samples: [Date: Double] = [:]
    private var hasSeeded = false
    private let lock = NSLock()

    /// Records a live reading and returns the last 24 hourly buckets.
    func recordAndBucket(levelPercent: Double, now: Date = Date()) -> [BatteryHistoryPoint] {
        seedFromPowerLogIfNeeded()

        lock.lock()
        defer { lock.unlock() }

        samples[now] = levelPercent
        pruneOldSamples(olderThan: now.addingTimeInterval(-25 * 3600))
        return bucketsForLast24Hours(endingAt: now)
    }

    // MARK: pmset seed

    private func seedFromPowerLogIfNeeded() {
        lock.lock()
        let alreadySeeded = hasSeeded
        hasSeeded = true
        lock.unlock()
        guard !alreadySeeded else { return }

        // Filter in the shell — the full log can be tens of MB.
        let output = Subprocess.run("/bin/sh", ["-c", "pmset -g log | grep '(Charge:'"])
        let parsed = Self.parsePowerLog(output)

        lock.lock()
        for (date, level) in parsed {
            samples[date] = level
        }
        lock.unlock()
    }

    /// Lines look like either of:
    ///   "2026-07-15 22:56:21 +0600 Sleep  ... Using Batt (Charge:87%) ..."
    ///   "2026-07-15 23:22:20 +0600 Assertions ... Using Batt(Charge: 84)"
    static func parsePowerLog(_ output: String) -> [(Date, Double)] {
        let linePattern = #/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}).*\(Charge:\s*(\d+)%?\)/#
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var readings: [(Date, Double)] = []
        for line in output.split(separator: "\n") {
            guard let match = line.prefixMatch(of: linePattern),
                  let date = dateFormatter.date(from: String(match.1)),
                  let level = Double(match.2)
            else { continue }
            readings.append((date, level))
        }
        return readings
    }

    // MARK: Bucketing

    private func pruneOldSamples(olderThan cutoff: Date) {
        samples = samples.filter { $0.key >= cutoff }
    }

    private func bucketsForLast24Hours(endingAt now: Date) -> [BatteryHistoryPoint] {
        let calendar = Calendar.current
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }

        // Latest sample per hour bucket.
        var latestPerHour: [Date: (Date, Double)] = [:]
        for (date, level) in samples {
            guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { continue }
            if let existing = latestPerHour[hour], existing.0 > date { continue }
            latestPerHour[hour] = (date, level)
        }

        return (0..<24).reversed().map { hoursAgo in
            let hour = currentHour.addingTimeInterval(TimeInterval(-hoursAgo * 3600))
            return BatteryHistoryPoint(id: hour, levelPercent: latestPerHour[hour]?.1)
        }
    }
}
