import Foundation

// ─────────────────────────────────────────────────────────────────
// Load average and uptime - what `uptime(1)` prints.
//
// Why load average when the panel already shows a CPU percentage: the
// percentage saturates. A Mac 100% busy running eight threads and a
// Mac 100% busy with sixty threads queued behind them both read
// "100%", and only the load average separates them, because it counts
// runnable threads rather than the time the cores were occupied. Its
// reference point is the core count: a load of 8 on an eight-core Mac
// is fully committed, 16 is twice as much work as there are cores to
// run it. That is why the card states the core count beside it - the
// number is meaningless without it.
//
// `getloadavg(3)` is the documented libc call and needs no root. It
// returns exactly what uptime(1) prints (verified here: 7.32 5.58 5.30
// from both) and costs 0.46 µs, so it sits on the fast lane beside the
// other syscalls.
//
// Uptime comes from `kern.boottime`, which is a wall-clock instant, so
// the span it yields includes time the Mac spent asleep. That is
// deliberate: it matches uptime(1), and it is what someone asking "have
// I rebooted since that update?" means. Boot time cannot change while
// the app runs, so it is read once at startup rather than every tick.
// ─────────────────────────────────────────────────────────────────

final class SystemLoadReader {

    private let bootDate: Date?
    private let coreCount: Int

    init() {
        bootDate = Self.readBootDate()
        // Logical cores, which is what host_processor_info reports one
        // entry per, so the load average and the core grid in the same
        // hover panel share a scale.
        coreCount = ProcessInfo.processInfo.processorCount
    }

    func readSnapshot() -> SystemLoadSnapshot {
        var averages = [Double](repeating: 0, count: 3)
        // Returns how many averages it filled in, or -1 on failure.
        // Anything it did not fill stays absent rather than reading 0.
        let filled = getloadavg(&averages, 3)
        return SystemLoadSnapshot(
            oneMinute: filled > 0 ? averages[0] : nil,
            fiveMinutes: filled > 1 ? averages[1] : nil,
            fifteenMinutes: filled > 2 ? averages[2] : nil,
            coreCount: coreCount,
            bootDate: bootDate
        )
    }

    private static func readBootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              boot.tv_sec > 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
}
