import Foundation

// ─────────────────────────────────────────────────────────────────
// Threshold alerts: which ones are firing, and which are worth
// interrupting someone about.
//
// The thresholds used to be four constants. They are now editable,
// which is what makes hysteresis necessary rather than merely nice:
// the whole point of a custom threshold is putting it near where your
// machine actually sits, and a bare comparison at that boundary
// flaps. A CPU hovering at 90% would fire, clear, fire, clear on
// every tick, and each flap would be a notification.
//
// So a rule arms and disarms at different points. It fires when the
// value passes the threshold, and does not fire again until the value
// has come back past the threshold *plus a margin*. Between those two
// points nothing changes.
//
// Notifications carry a second guard on top. Re-arming is honest (the
// value really did recover and climb again), but a machine that
// crosses the line every few minutes should not produce a
// notification every few minutes, so each rule stays quiet for a
// while after speaking.
//
// The engine takes `now` and its settings as parameters and holds no
// global state, so all of this is testable without waiting in real
// time or writing to UserDefaults.
// ─────────────────────────────────────────────────────────────────

/// The four things worth watching, and which direction is bad.
enum AlertRule: String, CaseIterable, Identifiable {
    case cpu
    case memoryPressure
    case cpuTemperature
    case batteryLow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU usage above"
        case .memoryPressure: return "Memory pressure above"
        case .cpuTemperature: return "CPU temperature above"
        case .batteryLow: return "Battery below"
        }
    }

    var unit: String {
        switch self {
        case .cpuTemperature: return "°C"
        default: return "%"
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .cpu: return 90
        case .memoryPressure: return 80
        case .cpuTemperature: return 90
        case .batteryLow: return 10
        }
    }

    /// Battery is the odd one out: it fires when the value drops
    /// *below* the threshold rather than rising above it.
    var firesWhenBelow: Bool { self == .batteryLow }

    var thresholdKey: String { "alert_\(rawValue)_threshold" }
    var enabledKey: String { "alert_\(rawValue)_enabled" }

    /// Sensible bounds for the Settings field, so a typo cannot set a
    /// threshold that could never fire or would fire constantly.
    var allowedRange: ClosedRange<Double> {
        switch self {
        case .cpuTemperature: return 40...110
        case .batteryLow: return 1...50
        default: return 10...100
        }
    }

    func message(for value: Double) -> String {
        switch self {
        case .cpu: return String(format: "CPU at %.0f%%", value)
        case .memoryPressure: return String(format: "Memory pressure at %.0f%%", value)
        case .cpuTemperature: return String(format: "CPU temperature at %.0f°", value)
        case .batteryLow: return String(format: "Battery at %.0f%%", value)
        }
    }
}

/// Thresholds and on/off state, read from defaults but passed in so
/// the engine stays pure.
struct AlertSettings {
    var enabled: [AlertRule: Bool] = [:]
    var thresholds: [AlertRule: Double] = [:]
    var notificationsEnabled = true

    func isEnabled(_ rule: AlertRule) -> Bool { enabled[rule] ?? true }

    func threshold(for rule: AlertRule) -> Double {
        let value = thresholds[rule] ?? rule.defaultThreshold
        return min(max(value, rule.allowedRange.lowerBound), rule.allowedRange.upperBound)
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> AlertSettings {
        var settings = AlertSettings()
        for rule in AlertRule.allCases {
            // Unset means on, so check for absence rather than reading
            // the bool: bool(forKey:) returns false for a missing key.
            settings.enabled[rule] =
                defaults.object(forKey: rule.enabledKey) as? Bool ?? true
            settings.thresholds[rule] =
                defaults.object(forKey: rule.thresholdKey) as? Double ?? rule.defaultThreshold
        }
        settings.notificationsEnabled =
            defaults.object(forKey: "alertNotificationsEnabled") as? Bool ?? true
        return settings
    }
}

/// What the engine observed this tick.
struct AlertReading {
    var cpuBusyPercent: Double = 0
    var memoryPressurePercent: Double = 0
    var cpuTemperatureCelsius: Double?
    var batteryPercent: Double = 0
    var batteryIsPresent = false
    var batteryIsDischarging = false
}

@MainActor
final class AlertEngine {

    /// How far a value must recover past the threshold before its rule
    /// can fire again. Five points is enough to absorb the jitter of a
    /// value parked on the line without hiding a real recovery.
    private static let rearmMargin: Double = 5

    /// Minimum gap between notifications for the same rule.
    private static let notificationCooldown: TimeInterval = 10 * 60

    private var firing: Set<AlertRule> = []
    private var lastNotified: [AlertRule: Date] = [:]

    /// Evaluate every rule. Returns the alerts currently firing (for
    /// the badge and the panel banner) and the subset that should
    /// also interrupt the user.
    func evaluate(_ reading: AlertReading,
                  settings: AlertSettings,
                  now: Date = Date()) -> (firing: [StatAlert], toNotify: [StatAlert]) {
        var active: [StatAlert] = []
        var notify: [StatAlert] = []

        for rule in AlertRule.allCases {
            guard settings.isEnabled(rule), let value = value(of: rule, in: reading) else {
                firing.remove(rule)
                continue
            }

            let threshold = settings.threshold(for: rule)
            let wasFiring = firing.contains(rule)
            let isFiring = shouldFire(rule: rule, value: value,
                                      threshold: threshold, wasFiring: wasFiring)

            if isFiring {
                let alert = StatAlert(id: rule.rawValue, message: rule.message(for: value))
                active.append(alert)

                // Notify on the transition into firing, never while it
                // stays firing, and not again within the cooldown.
                if !wasFiring, settings.notificationsEnabled {
                    let last = lastNotified[rule]
                    if last == nil || now.timeIntervalSince(last!) >= Self.notificationCooldown {
                        lastNotified[rule] = now
                        notify.append(alert)
                    }
                }
            }
            if isFiring { firing.insert(rule) } else { firing.remove(rule) }
        }
        return (active, notify)
    }

    /// Arms at the threshold, disarms only past threshold ± margin.
    private func shouldFire(rule: AlertRule,
                            value: Double,
                            threshold: Double,
                            wasFiring: Bool) -> Bool {
        if rule.firesWhenBelow {
            return wasFiring ? value < threshold + Self.rearmMargin : value < threshold
        }
        return wasFiring ? value > threshold - Self.rearmMargin : value > threshold
    }

    /// nil means "cannot judge this rule right now", which is not the
    /// same as "fine": a Mac with no battery, or no temperature sensor
    /// yet, must not report a low battery or a cold CPU.
    private func value(of rule: AlertRule, in reading: AlertReading) -> Double? {
        switch rule {
        case .cpu: return reading.cpuBusyPercent
        case .memoryPressure: return reading.memoryPressurePercent
        case .cpuTemperature: return reading.cpuTemperatureCelsius
        case .batteryLow:
            guard reading.batteryIsPresent, reading.batteryIsDischarging else { return nil }
            return reading.batteryPercent
        }
    }
}
