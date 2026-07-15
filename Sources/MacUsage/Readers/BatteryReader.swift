import Foundation
import IOKit.ps

// ─────────────────────────────────────────────────────────────────
// Reads the battery's current state.
//
// Level / charging / time-remaining come from the power-sources API
// (what the system battery menu uses). Health and cycle count come
// from the AppleSmartBattery service in the IO registry:
//   health = NominalChargeCapacity / DesignCapacity
// which matches System Settings' "Maximum Capacity". Desktops have
// no battery — isPresent stays false and the card is hidden.
// ─────────────────────────────────────────────────────────────────

final class BatteryReader {

    func readSnapshot() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        readPowerSource(into: &snapshot)
        if snapshot.isPresent {
            readHealth(into: &snapshot)
        }
        return snapshot
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

        // NominalChargeCapacity on Apple Silicon; older Intel batteries
        // expose the raw value instead. (Plain "MaxCapacity" here is a
        // percentage on Apple Silicon — useless against DesignCapacity.)
        let designCapacity = intProperty("DesignCapacity") ?? 0
        let maxCapacity = intProperty("NominalChargeCapacity")
            ?? intProperty("AppleRawMaxCapacity")
            ?? 0
        if designCapacity > 0, maxCapacity > 0 {
            snapshot.healthPercent = min(100, Double(maxCapacity) / Double(designCapacity) * 100)
        }
        snapshot.cycleCount = intProperty("CycleCount") ?? 0
    }
}
