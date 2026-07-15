import Foundation

// ─────────────────────────────────────────────────────────────────
// Simple data holders ("models") for everything the panel displays.
// Each reader fills one of these in, and the UI just renders them.
// ─────────────────────────────────────────────────────────────────

/// A snapshot of overall CPU usage, in percentages that add up with idle to 100.
struct CpuUsageSnapshot {
    var userPercent: Double = 0
    var systemPercent: Double = 0

    /// Total busy percentage (what most people think of as "CPU usage").
    var totalBusyPercent: Double {
        return userPercent + systemPercent
    }

    var idlePercent: Double {
        return max(0, 100 - totalBusyPercent)
    }
}

/// One row of the "top CPU processes" list.
struct ProcessCpuUsage: Identifiable {
    let id: Int32              // pid
    let name: String
    let executablePath: String // used to look up the app icon
    let cpuPercent: Double
}

/// Everything the expanded CPU hover panel displays that isn't
/// already part of the regular CPU snapshot.
struct CpuDetails {
    var topProcesses: [ProcessCpuUsage] = []
}

/// A snapshot of how much RAM is being used.
struct MemoryUsageSnapshot {
    var usedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    /// Where the used memory goes (drives the segmented gauge colors).
    var breakdown = MemoryBreakdown()
    /// 0–100; how starved the system is for memory (100 - the kernel's
    /// "available memory" level). Low is healthy.
    var pressurePercent: Double = 0

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100.0
    }
}

/// One fan inside the machine (some Macs have 0, 1 or 2 fans).
struct FanReading: Identifiable {
    let id: Int              // fan index: 0, 1, ...
    var speedRpm: Double = 0 // current rotations per minute
}

/// Everything the SMC knows about one fan (for the hover panel).
/// Values the SMC doesn't expose stay 0 and render as "—".
struct FanDetailReading: Identifiable {
    let id: Int              // fan index: 0, 1, ...
    var currentRpm: Double = 0
    var minRpm: Double = 0
    var maxRpm: Double = 0
    var targetRpm: Double = 0
}

/// One temperature sensor grouped into a friendly category.
struct TemperatureReading: Identifiable {
    let id: String           // the raw 4-character SMC key, e.g. "Tp01"
    let category: TemperatureCategory
    var celsius: Double = 0
}

/// Friendly groups so the panel can show "CPU" instead of raw sensor codes.
enum TemperatureCategory: String {
    case cpu = "CPU"
    case gpu = "GPU"
    case battery = "Battery"
    case other = "Other"
}

/// Activity-Monitor-style split of where the RAM is going.
struct MemoryBreakdown {
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
}

/// One row of the "top memory processes" list.
struct ProcessMemoryUsage: Identifiable {
    let id: Int32              // pid
    let name: String           // "Slack", "WindowServer", ...
    let executablePath: String // used to look up the app icon
    let memoryBytes: UInt64
}

/// Everything the expanded Memory hover panel displays that isn't
/// already part of the regular memory snapshot.
struct MemoryDetails {
    var topProcesses: [ProcessMemoryUsage] = []
}
