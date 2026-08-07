import Foundation

// ─────────────────────────────────────────────────────────────────
// Reads overall CPU usage from the macOS kernel.
//
// How it works:
// The kernel keeps a running counter of "ticks" each CPU core spent
// in user / system / idle states since boot. Usage percentage is the
// *difference* between two samples, so the first call returns 0 and
// every later call returns the usage since the previous call.
// ─────────────────────────────────────────────────────────────────

final class CpuUsageReader {

    /// Per-core tick counters from the previous sample, in the order
    /// the kernel reports cores. Machine-wide totals are summed from
    /// these rather than tracked separately.
    private var previousCoreTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    /// Tick counters from the previous sample, so we can compute a delta.
    private var previousUserTicks: UInt64 = 0
    private var previousSystemTicks: UInt64 = 0
    private var previousIdleTicks: UInt64 = 0
    private var previousNiceTicks: UInt64 = 0
    private var hasPreviousSample = false

    /// Ask the kernel for per-core tick counters, sum them across all cores,
    /// and turn the change since last time into percentages.
    func readCurrentUsage() -> CpuUsageSnapshot {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let info = processorInfo else {
            return CpuUsageSnapshot()
        }

        // Read every core's counters, then sum them for the
        // machine-wide numbers. The per-core values used to be summed
        // away here; they are kept now so the CPU detail panel can
        // show each core, which costs nothing extra to collect.
        var coreTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        coreTicks.reserveCapacity(Int(processorCount))

        var totalUserTicks: UInt64 = 0
        var totalSystemTicks: UInt64 = 0
        var totalIdleTicks: UInt64 = 0
        var totalNiceTicks: UInt64 = 0

        let ticksPerCore = Int(CPU_STATE_MAX) // 4 values per core: user, system, idle, nice
        for coreIndex in 0..<Int(processorCount) {
            let baseIndex = coreIndex * ticksPerCore
            // The kernel counters are unsigned 32-bit, but Swift sees the array
            // as Int32, so reinterpret the bits: large values would otherwise trap.
            let user = UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_NICE)]))
            coreTicks.append((user, system, idle, nice))
            totalUserTicks += user
            totalSystemTicks += system
            totalIdleTicks += idle
            totalNiceTicks += nice
        }

        // Give the kernel its memory back.
        let infoByteSize = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), infoByteSize)

        var snapshot = CpuUsageSnapshot()

        if hasPreviousSample {
            // How many ticks happened since the last sample?
            let userDelta = Double(totalUserTicks &- previousUserTicks)
            let systemDelta = Double(totalSystemTicks &- previousSystemTicks)
            let idleDelta = Double(totalIdleTicks &- previousIdleTicks)
            let niceDelta = Double(totalNiceTicks &- previousNiceTicks)
            let totalDelta = userDelta + systemDelta + idleDelta + niceDelta

            if totalDelta > 0 {
                // "nice" is user work at lowered priority, so count it as user.
                snapshot.userPercent = (userDelta + niceDelta) / totalDelta * 100.0
                snapshot.systemPercent = systemDelta / totalDelta * 100.0
            }
        }

        if previousCoreTicks.count == coreTicks.count {
            let names = CpuTopology.clusterNames(coreCount: coreTicks.count)
            snapshot.cores = coreTicks.indices.map { index in
                let now = coreTicks[index], before = previousCoreTicks[index]
                let user = Double(now.user &- before.user)
                let system = Double(now.system &- before.system)
                let idle = Double(now.idle &- before.idle)
                let nice = Double(now.nice &- before.nice)
                let total = user + system + idle + nice
                return CoreUsage(
                    id: index,
                    busyPercent: total > 0 ? (user + system + nice) / total * 100 : 0,
                    clusterName: names.indices.contains(index) ? names[index] : nil
                )
            }
        }

        // Remember this sample for next time.
        previousCoreTicks = coreTicks
        previousUserTicks = totalUserTicks
        previousSystemTicks = totalSystemTicks
        previousIdleTicks = totalIdleTicks
        previousNiceTicks = totalNiceTicks
        hasPreviousSample = true

        return snapshot
    }
}
