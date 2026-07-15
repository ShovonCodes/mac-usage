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

        // Sum the tick counters of every CPU core into machine-wide totals.
        var totalUserTicks: UInt64 = 0
        var totalSystemTicks: UInt64 = 0
        var totalIdleTicks: UInt64 = 0
        var totalNiceTicks: UInt64 = 0

        let ticksPerCore = Int(CPU_STATE_MAX) // 4 values per core: user, system, idle, nice
        for coreIndex in 0..<Int(processorCount) {
            let baseIndex = coreIndex * ticksPerCore
            // The kernel counters are unsigned 32-bit, but Swift sees the array
            // as Int32 — reinterpret the bits so large values don't crash us.
            totalUserTicks += UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_USER)]))
            totalSystemTicks += UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_SYSTEM)]))
            totalIdleTicks += UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_IDLE)]))
            totalNiceTicks += UInt64(UInt32(bitPattern: info[baseIndex + Int(CPU_STATE_NICE)]))
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

        // Remember this sample for next time.
        previousUserTicks = totalUserTicks
        previousSystemTicks = totalSystemTicks
        previousIdleTicks = totalIdleTicks
        previousNiceTicks = totalNiceTicks
        hasPreviousSample = true

        return snapshot
    }
}
