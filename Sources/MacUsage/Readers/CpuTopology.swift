import Foundation

// ─────────────────────────────────────────────────────────────────
// Which cores are the fast ones.
//
// Apple Silicon splits its cores into "performance" and "efficiency"
// clusters, and knowing which is which changes what a busy graph
// means: four pegged efficiency cores is a machine ticking over,
// four pegged performance cores is a machine working hard.
//
// sysctl describes the clusters:
//
//     hw.nperflevels            2
//     hw.perflevel0.name        Performance
//     hw.perflevel0.logicalcpu  4
//     hw.perflevel1.name        Efficiency
//     hw.perflevel1.logicalcpu  4
//
// The trap is the ordering. sysctl numbers level 0 as the *fastest*,
// but `host_processor_info` reports cores in the opposite order:
// slowest cluster first. Measured on an M1 by pinning four
// userInteractive threads, which macOS schedules on performance
// cores: indices 4-7 sat at 98% while 0-3 stayed idle. So the
// efficiency cores are 0-3 and the performance cores are 4-7, and
// mapping perflevel 0 onto the first cores would label every core
// backwards.
//
// Intel Macs have no perflevels at all, so every core comes back
// unlabelled and the UI simply omits the grouping.
// ─────────────────────────────────────────────────────────────────

enum CpuTopology {

    /// Cluster name per core index, in `host_processor_info` order.
    /// Empty when the machine does not advertise perflevels.
    static let clusterNames: [String] = readClusterNames()

    /// Convenience for callers that know how many cores they read.
    /// Returns an empty array if the counts disagree, so a mismatch
    /// shows up as "no labels" rather than as wrong labels.
    static func clusterNames(coreCount: Int) -> [String] {
        clusterNames.count == coreCount ? clusterNames : []
    }

    private static func readClusterNames() -> [String] {
        let levelCount = sysctlInt("hw.nperflevels") ?? 0
        guard levelCount > 0 else { return [] }

        // Walk the levels backwards: the kernel lists cores slowest
        // cluster first, while sysctl numbers the fastest as level 0.
        var names: [String] = []
        for level in stride(from: levelCount - 1, through: 0, by: -1) {
            guard let count = sysctlInt("hw.perflevel\(level).logicalcpu"),
                  count > 0,
                  let name = sysctlString("hw.perflevel\(level).name")
            else { continue }
            names.append(contentsOf: Array(repeating: name, count: count))
        }
        return names
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
