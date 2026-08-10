import Foundation

// ─────────────────────────────────────────────────────────────────
// Reads how many watts the machine is drawing, from the SMC's power
// rails.
//
// Why the SMC and not the battery: `AppleSmartBattery` also publishes
// a power figure (`PowerTelemetryData` → `BatteryPower`, and
// `Amperage` × `Voltage`), but the whole registry entry only refreshes
// about once a minute - measured here, the numbers sat frozen through
// a 40-second all-core load and only moved afterwards. A live watt
// meter cannot be built on that. The SMC rails move within a second or
// two, cost ~1 ms each, and need no root.
//
// The three rails this reads, verified on an M1 by loading all cores
// (idle → busy → idle):
//
//   PSTR  system total   6.5 →  18 →  6.9 W
//   PPBR  battery rail   8.0 →  19 →  8.5 W
//   PDTR  DC-in (mains)  0 throughout - the machine was unplugged
//
// `PPBR` is the rail to trust for "how fast is the battery draining":
// sampled against `AppleSmartBattery`'s own `BatteryPower` at the
// moment that refreshed, the two agreed to within 2% (11.09 vs
// 11.27 W). `PSTR` tracks it about a second behind and slightly lower.
//
// What is deliberately *not* done here: deriving one rail from the
// others. Plugged-in behaviour could not be measured on the machine
// this was written on, so it is not known whether `PSTR` includes the
// power going into the battery while it charges. Each rail is
// therefore reported as itself and labelled as itself, which is true
// in every power state; a computed "real" system draw would be a guess
// in the one state that was never observed.
//
// Rails are looked up once. A Mac that does not publish one (older
// Intel models expose a different subset) simply reports nil for it,
// and a Mac that publishes none hides the card the way a desktop hides
// the battery card.
// ─────────────────────────────────────────────────────────────────

final class PowerReader {

    private let smc = SmcConnection()

    /// Which rail keys this Mac actually answers for, decided on the
    /// first read. `false` for a rail means "asked once, not there" -
    /// distinct from a rail that is present and reading 0 W, which is
    /// exactly what the mains rail does on battery.
    private var hasProbedRails = false
    private var availableKeys: [PowerRail: String] = [:]

    private enum PowerRail: CaseIterable {
        case system, battery, adapter

        /// Candidates in preference order. The first key that answers
        /// with a plausible reading wins.
        var candidateKeys: [String] {
            switch self {
            case .system: return ["PSTR"]
            // `Pb0f` reads within 0.1 W of `PPBR` on Apple Silicon, so
            // it serves as the fallback rather than a second row.
            case .battery: return ["PPBR", "Pb0f"]
            case .adapter: return ["PDTR"]
            }
        }
    }

    func readSnapshot() -> PowerSnapshot {
        smc.open()
        guard smc.isOpen else { return PowerSnapshot() }
        probeRailsIfNeeded()

        return PowerSnapshot(
            systemWatts: watts(for: .system),
            batteryWatts: watts(for: .battery),
            adapterWatts: watts(for: .adapter)
        )
    }

    private func watts(for rail: PowerRail) -> Double? {
        guard let key = availableKeys[rail] else { return nil }
        return Self.plausibleWatts(smc.readNumericValue(forKey: key))
    }

    /// Probing costs one read per candidate key, once per launch.
    ///
    /// A rail is only accepted if it reads plausibly *now*, which is
    /// why the mains rail has to be probed on its literal zero: it is
    /// unplugged half the time, and requiring a nonzero first reading
    /// would make the row appear and disappear with the charger.
    private func probeRailsIfNeeded() {
        guard !hasProbedRails else { return }
        hasProbedRails = true

        for rail in PowerRail.allCases {
            for key in rail.candidateKeys {
                guard Self.plausibleWatts(smc.readNumericValue(forKey: key)) != nil else { continue }
                availableKeys[rail] = key
                break
            }
        }
    }

    /// Reject what cannot be a wattage. Some SMC keys in the "P" group
    /// answer with -1 or with values orders of magnitude out (seen
    /// while scanning: `PP7b` = -1.0), and a rail that does that once
    /// can do it again after probing, so the filter applies to every
    /// read and not only to discovery. 500 W is comfortably above the
    /// largest Mac power supply.
    static func plausibleWatts(_ value: Double?) -> Double? {
        guard let value, value >= 0, value <= 500 else { return nil }
        return value
    }
}
