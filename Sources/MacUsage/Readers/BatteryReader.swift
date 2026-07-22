import Foundation
import IOKit.ps

// ─────────────────────────────────────────────────────────────────
// Reads the battery's current state.
//
// Level / charging / time-remaining come from the power-sources API
// (what the system battery menu uses). Cycle count comes from the
// AppleSmartBattery service in the IO registry.
//
// Health ("Maximum Capacity") is trickier: the number System Settings
// shows is computed by powerd's battery-health model and published in
// NO public API — every raw registry ratio reads several points
// higher (measured here: Nominal/Design 94%, Raw/Design 91.5%, while
// Settings said 87%). The only unprivileged way to read powerd's
// number is `system_profiler SPPowerDataType` (~0.2 s), so that value
// is fetched off the main thread, cached, and refreshed hourly; the
// registry ratio serves only as a fallback until the first fetch.
// Desktops have no battery — isPresent stays false, card hidden.
// ─────────────────────────────────────────────────────────────────

final class BatteryReader {

    // powerd health cache — written from a background task, read from
    // the main thread on every snapshot.
    private let healthLock = NSLock()
    private var cachedHealthPercent: Double = 0
    private var lastHealthFetch = Date.distantPast
    /// Battery health moves on the order of weeks; hourly is generous.
    private let healthRefreshInterval: TimeInterval = 3600

    func readSnapshot() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        readPowerSource(into: &snapshot)
        if snapshot.isPresent {
            readHealth(into: &snapshot)
            healthLock.lock()
            if cachedHealthPercent > 0 {
                snapshot.healthPercent = cachedHealthPercent
            }
            healthLock.unlock()
        }
        return snapshot
    }

    /// Slow path — spawns system_profiler, so call it off the main
    /// thread. No-ops unless the cached value has gone stale.
    func refreshHealthFromPowerdIfStale() {
        healthLock.lock()
        let isStale = Date().timeIntervalSince(lastHealthFetch) >= healthRefreshInterval
        if isStale { lastHealthFetch = Date() } // claim it before the slow call
        healthLock.unlock()
        guard isStale, let percent = Self.healthPercentFromPowerd() else { return }

        healthLock.lock()
        cachedHealthPercent = percent
        healthLock.unlock()
    }

    /// Parses `system_profiler SPPowerDataType -json` for
    /// sppower_battery_health_maximum_capacity ("87%").
    private static func healthPercentFromPowerd() -> Double? {
        let output = Subprocess.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }

        for entry in entries {
            guard let healthInfo = entry["sppower_battery_health_info"] as? [String: Any],
                  let capacityText = healthInfo["sppower_battery_health_maximum_capacity"] as? String
            else { continue }
            let digits = capacityText.filter { $0.isNumber || $0 == "." }
            if let percent = Double(digits), percent > 0 {
                return min(100, percent)
            }
        }
        return nil
    }

    // MARK: Level / charging / time remaining

    private func readPowerSource(into snapshot: inout BatterySnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            snapshot.isPresent = true

            let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int ?? 100
            if maxCapacity > 0 {
                snapshot.levelPercent = Double(currentCapacity) / Double(maxCapacity) * 100
            }

            snapshot.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.isPluggedIn =
                (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            let timeKey = snapshot.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = description[timeKey] as? Int, minutes > 0 {
                snapshot.timeRemainingMinutes = minutes
            }
            return
        }
    }

    // MARK: Health / cycle count

    private func readHealth(into snapshot: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func intProperty(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }

        // Fallback health only (powerd's number wins once fetched):
        // the raw measured capacity is closest to Apple's figure.
        // (Plain "MaxCapacity" here is a percentage on Apple Silicon —
        // useless against DesignCapacity.)
        let designCapacity = intProperty("DesignCapacity") ?? 0
        let maxCapacity = intProperty("AppleRawMaxCapacity")
            ?? intProperty("NominalChargeCapacity")
            ?? 0
        if designCapacity > 0, maxCapacity > 0 {
            snapshot.healthPercent = min(100, Double(maxCapacity) / Double(designCapacity) * 100)
        }
        snapshot.cycleCount = intProperty("CycleCount") ?? 0
    }
}
