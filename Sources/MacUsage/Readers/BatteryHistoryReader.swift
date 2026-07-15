import Foundation

// ─────────────────────────────────────────────────────────────────
// Builds the "battery level over the last 24 hours" chart data and
// tracks how long the Mac has been running on battery.
//
// Two sources, merged:
//   1. A one-time seed from `pmset -g log`, whose sleep/wake/charge
//     entries carry "Using Batt(Charge: NN%)" / "Using AC(Charge:"
//     markers — level history AND power-source history from before
//     the app was even running (~2s, done once, off the main thread).
//   2. Live samples recorded on every refresh tick while the app runs.
//
// Readings collapse into 24 hourly buckets (latest reading wins per
// hour). Hours with no reading at all stay nil and render as gaps.
// "Time on battery" = time since the newest sample that was on AC.
// ─────────────────────────────────────────────────────────────────

final class BatteryHistoryReader {

    struct Sample {
        let levelPercent: Double
        let isOnBattery: Bool
    }

    /// timestamp → sample. Protected by `lock`: the seed and the tick
    /// samples arrive on different background tasks.
    private var samples: [Date: Sample] = [:]
    private var hasSeeded = false
    private let lock = NSLock()

    /// Records a live reading; returns the last 24 hourly buckets and
    /// the minutes spent on battery since the last AC power reading
    /// (nil when on AC now, or when no AC reading is in the window).
    func recordAndBucket(
        levelPercent: Double,
        isOnBattery: Bool,
        now: Date = Date()
    ) -> (points: [BatteryHistoryPoint], timeOnBatteryMinutes: Int?) {
        seedFromPowerLogIfNeeded()

        lock.lock()
        defer { lock.unlock() }

        samples[now] = Sample(levelPercent: levelPercent, isOnBattery: isOnBattery)
        pruneOldSamples(olderThan: now.addingTimeInterval(-25 * 3600))

        return (bucketsForLast24Hours(endingAt: now), timeOnBattery(now: now))
    }

    // MARK: Time on battery

    private func timeOnBattery(now: Date) -> Int? {
        guard let newest = samples.max(by: { $0.key < $1.key }),
              newest.value.isOnBattery else { return nil }
        guard let lastOnAC = samples.filter({ !$0.value.isOnBattery }).keys.max() else {
            return nil // no AC reading in the window — unknown
        }
        return Int(now.timeIntervalSince(lastOnAC) / 60)
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
        for (date, sample) in parsed {
            samples[date] = sample
        }
        lock.unlock()
    }

    /// Lines look like either of:
    ///   "2026-07-15 22:56:21 +0600 Sleep  ... Using Batt (Charge:87%) ..."
    ///   "2026-07-15 23:22:20 +0600 Assertions ... Using AC(Charge: 84)"
    static func parsePowerLog(_ output: String) -> [(Date, Sample)] {
        let linePattern =
            #/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}).*Using (AC|Batt|BATT)\s*\(Charge:\s*(\d+)%?\)/#
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var readings: [(Date, Sample)] = []
        for line in output.split(separator: "\n") {
            guard let match = line.prefixMatch(of: linePattern),
                  let date = dateFormatter.date(from: String(match.1)),
                  let level = Double(match.3)
            else { continue }
            readings.append((date, Sample(
                levelPercent: level,
                isOnBattery: match.2 != "AC"
            )))
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
        for (date, sample) in samples {
            guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { continue }
            if let existing = latestPerHour[hour], existing.0 > date { continue }
            latestPerHour[hour] = (date, sample.levelPercent)
        }

        return (0..<24).reversed().map { hoursAgo in
            let hour = currentHour.addingTimeInterval(TimeInterval(-hoursAgo * 3600))
            return BatteryHistoryPoint(id: hour, levelPercent: latestPerHour[hour]?.1)
        }
    }
}
