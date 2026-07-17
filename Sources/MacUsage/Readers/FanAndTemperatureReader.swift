import Foundation

// ─────────────────────────────────────────────────────────────────
// Turns raw SMC access (SmcConnection) into friendly fan speeds and
// temperatures.
//
// Because sensor key names differ between Intel and Apple Silicon
// Macs (and even between chip generations), we don't hard-code a
// list. Instead, on first use we scan every key the SMC exposes and
// remember the ones that look like temperature sensors. Fans are
// simpler: "FNum" tells us how many exist, then "F0Ac", "F1Ac", ...
// give the actual speed of each.
// ─────────────────────────────────────────────────────────────────

final class FanAndTemperatureReader {

    private let smc = SmcConnection()

    /// Temperature sensor keys discovered on this Mac, found once at startup.
    private var discoveredTemperatureKeys: [(keyName: String, category: TemperatureCategory)] = []
    private var hasDiscoveredSensors = false

    // MARK: Fans

    func readFans() -> [FanReading] {
        smc.open()
        guard smc.isOpen else { return [] }

        guard let fanCount = smc.readNumericValue(forKey: "FNum"), fanCount > 0 else {
            return [] // e.g. MacBook Air — it has no fan at all
        }

        var fans: [FanReading] = []
        for fanIndex in 0..<Int(fanCount) {
            let actualSpeedKey = "F\(fanIndex)Ac"
            if let speedRpm = smc.readNumericValue(forKey: actualSpeedKey) {
                fans.append(FanReading(id: fanIndex, speedRpm: speedRpm))
            }
        }
        return fans
    }

    /// Full per-fan detail for the hover panel. "Ac" is the actual
    /// speed; "Mn"/"Mx" are the SMC's min/max speeds.
    func readFanDetails() -> [FanDetailReading] {
        smc.open()
        guard smc.isOpen else { return [] }

        guard let fanCount = smc.readNumericValue(forKey: "FNum"), fanCount > 0 else {
            return []
        }

        var details: [FanDetailReading] = []
        for fanIndex in 0..<Int(fanCount) {
            guard let currentRpm = smc.readNumericValue(forKey: "F\(fanIndex)Ac") else { continue }
            details.append(FanDetailReading(
                id: fanIndex,
                currentRpm: currentRpm,
                minRpm: smc.readNumericValue(forKey: "F\(fanIndex)Mn") ?? 0,
                maxRpm: smc.readNumericValue(forKey: "F\(fanIndex)Mx") ?? 0
            ))
        }
        return details
    }

    // MARK: Temperatures

    func readTemperatures() -> [TemperatureReading] {
        smc.open()
        guard smc.isOpen else { return [] }

        discoverTemperatureSensorsIfNeeded()

        var readings: [TemperatureReading] = []
        for sensor in discoveredTemperatureKeys {
            guard let celsius = smc.readNumericValue(forKey: sensor.keyName) else { continue }
            // Ignore sensors reporting nonsense (unplugged / unused sensors
            // often report 0 or values far outside a plausible range).
            guard celsius > 1, celsius < 120 else { continue }
            readings.append(TemperatureReading(
                id: sensor.keyName,
                category: sensor.category,
                celsius: celsius
            ))
        }
        return readings
    }

    /// Average temperature per category — handy for a compact display.
    /// e.g. Apple Silicon Macs expose 10+ CPU sensors; showing the average
    /// of them matches what most monitoring apps display.
    func readAverageTemperaturesByCategory() -> [TemperatureCategory: Double] {
        return Self.averageTemperatures(from: readTemperatures())
    }

    /// Static so the store can average readings it already fetched
    /// without hitting the SMC a second time.
    static func averageTemperatures(from readings: [TemperatureReading]) -> [TemperatureCategory: Double] {
        var sumByCategory: [TemperatureCategory: Double] = [:]
        var countByCategory: [TemperatureCategory: Int] = [:]

        for reading in readings {
            sumByCategory[reading.category, default: 0] += reading.celsius
            countByCategory[reading.category, default: 0] += 1
        }

        var averages: [TemperatureCategory: Double] = [:]
        for (category, sum) in sumByCategory {
            averages[category] = sum / Double(countByCategory[category] ?? 1)
        }
        return averages
    }

    // MARK: Sensor discovery (runs once)

    private func discoverTemperatureSensorsIfNeeded() {
        guard !hasDiscoveredSensors else { return }
        hasDiscoveredSensors = true

        let totalKeyCount = smc.readTotalKeyCount()
        guard totalKeyCount > 0 else { return }

        for index in 0..<totalKeyCount {
            guard let keyName = smc.keyName(atIndex: index) else { continue }
            guard let category = Self.temperatureCategory(forKeyName: keyName) else { continue }
            discoveredTemperatureKeys.append((keyName: keyName, category: category))
        }
    }

    /// Decide whether an SMC key is a temperature sensor we care about,
    /// and which friendly group it belongs to. Returns nil for non-temperature keys.
    private static func temperatureCategory(forKeyName keyName: String) -> TemperatureCategory? {
        // All temperature keys start with "T".
        guard keyName.hasPrefix("T") else { return nil }

        // CPU sensors: "TC.." on Intel, "Tp.." on Apple Silicon.
        if keyName.hasPrefix("TC") || keyName.hasPrefix("Tp") {
            return .cpu
        }
        // GPU sensors: "TG.." on Intel, "Tg.." on Apple Silicon.
        if keyName.hasPrefix("TG") || keyName.hasPrefix("Tg") {
            return .gpu
        }
        // Battery sensors.
        if keyName.hasPrefix("TB") {
            return .battery
        }
        // Every other "T" key (SSD, airflow, palm rest, ...) — we skip these
        // for now to keep the panel minimal. To show them later, return
        // .other here instead of nil and render the extra section in the UI.
        return nil
    }
}
