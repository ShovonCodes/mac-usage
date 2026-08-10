import Foundation

// ─────────────────────────────────────────────────────────────────
// Simple data holders ("models") for everything the panel displays.
// Each reader fills one of these in, and the UI just renders them.
// ─────────────────────────────────────────────────────────────────

/// A snapshot of overall CPU usage, in percentages that add up with idle to 100.
struct CpuUsageSnapshot {
    var userPercent: Double = 0
    var systemPercent: Double = 0
    /// One entry per logical core, in kernel order. Collected on the
    /// same syscall as the totals above, so it costs nothing extra.
    var cores: [CoreUsage] = []

    /// Total busy percentage (what most people think of as "CPU usage").
    var totalBusyPercent: Double {
        return userPercent + systemPercent
    }

    var idlePercent: Double {
        return max(0, 100 - totalBusyPercent)
    }
}

/// One tick of CPU usage history (for the stacked bar chart).
struct CpuHistoryPoint: Identifiable {
    let id: Date
    let userPercent: Double
    let systemPercent: Double
}

/// One row of the "top CPU processes" list.
struct ProcessCpuUsage: Identifiable {
    let id: Int32              // pid
    let name: String
    let executablePath: String // used to look up the app icon
    let cpuPercent: Double
}

/// One logical core's share of the last sample.
struct CoreUsage: Identifiable {
    let id: Int                 // index as the kernel reports it
    var busyPercent: Double = 0
    /// "Performance" / "Efficiency" on Apple Silicon; nil on Intel,
    /// where every core is the same kind.
    var clusterName: String?
}

/// Everything the expanded CPU hover panel displays that isn't
/// already part of the regular CPU snapshot.
struct CpuDetails {
    var topProcesses: [ProcessCpuUsage] = []
}

/// One graphics processor as the IO registry describes it. Apple
/// Silicon Macs have exactly one; Intel models with a discrete card
/// report the integrated and the discrete GPU separately.
struct GpuDevice: Identifiable {
    /// The registry entry name ("AGXAcceleratorG13G_B0"). Stable
    /// across reads and unique per card, which is what a list row
    /// needs; the human-readable name is `name`.
    let id: String
    var name: String = ""
    /// Apple Silicon publishes its GPU core count; Intel drivers do not.
    var coreCount: Int?
    /// 0-100, averaged over the interval since the previous read.
    /// See GpuReader for why that interval is what it is.
    var utilizationPercent: Double = 0
    /// GPU memory currently in use: a slice of system RAM on unified
    /// memory, dedicated VRAM on a discrete card.
    var inUseMemoryBytes: UInt64 = 0
    /// Everything the driver has reserved, in use or not. Always the
    /// larger of the two, and the number that grows with what is open.
    var allocatedMemoryBytes: UInt64 = 0
}

/// Every GPU in the machine, plus the headline figures the card shows.
struct GpuSnapshot {
    var devices: [GpuDevice] = []

    var isPresent: Bool { !devices.isEmpty }

    /// The busiest GPU. On a machine that can switch between an
    /// integrated and a discrete card, the idle one would otherwise
    /// drag an average down and hide real work.
    var utilizationPercent: Double {
        devices.map(\.utilizationPercent).max() ?? 0
    }

    var inUseMemoryBytes: UInt64 {
        devices.reduce(0) { $0 + $1.inUseMemoryBytes }
    }

    /// Registry order, not the busiest, so the label does not flicker
    /// between two cards as load moves around.
    var name: String? { devices.first?.name }
}

/// One tick of GPU utilization history (for the card's bar chart).
struct GpuHistoryPoint: Identifiable {
    let id: Date
    let utilizationPercent: Double
}

/// A snapshot of the battery's current state.
struct BatterySnapshot {
    var isPresent = false
    var levelPercent: Double = 0
    var isCharging = false
    var isPluggedIn = false
    /// Minutes to empty (discharging) or to full (charging); nil while
    /// macOS is still estimating.
    var timeRemainingMinutes: Int?
    /// Maximum charge the battery can hold vs. its design capacity.
    var healthPercent: Double = 0
    var cycleCount: Int = 0
}

/// Current network throughput across physical interfaces.
struct NetworkSpeedSnapshot {
    var uploadBytesPerSecond: Double = 0
    var downloadBytesPerSecond: Double = 0
}

/// One tick of throughput history (for the mirrored bar chart).
struct NetworkHistoryPoint: Identifiable {
    let id: Date
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
}

/// Connection facts for the network hover panel.
struct NetworkInfo {
    var wifiName: String?
    var localIPv4: [String] = []
    var localIPv6: [String] = []
    var publicIP: String?
}

/// Everything the expanded Network hover panel displays.
struct NetworkDetails {
    var info = NetworkInfo()
}

/// One currently-firing threshold alert (CPU pegged, low battery, ...).
struct StatAlert: Identifiable, Equatable {
    let id: String       // stable per rule: "cpu", "memory", ...
    let message: String  // "CPU at 97%"
}

/// Battery level for one hour of the last day (for the hover chart).
struct BatteryHistoryPoint: Identifiable {
    let id: Date               // start of the hour bucket
    /// nil = no reading recorded during that hour (e.g. Mac was asleep
    /// the whole hour, or the app wasn't running yet).
    let levelPercent: Double?
}

/// Boot volume capacity plus how fast the physical disks are being
/// read and written right now.
struct DiskSnapshot {
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0

    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100.0
    }
}

/// One tick of disk throughput, for the hover chart.
struct DiskHistoryPoint: Identifiable {
    let id: Date
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
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
/// Values the SMC doesn't expose stay 0 and render as "-".
struct FanDetailReading: Identifiable {
    let id: Int              // fan index: 0, 1, ...
    var currentRpm: Double = 0
    var minRpm: Double = 0
    var maxRpm: Double = 0
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
