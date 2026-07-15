import Foundation

// ─────────────────────────────────────────────────────────────────
// Reads RAM usage from the macOS kernel.
//
// macOS reports memory in fixed-size "pages". We ask the kernel how
// many pages are in each state and multiply by the page size to get
// bytes. "Used" here mirrors Activity Monitor's definition:
//   used = active + wired + compressed
// ─────────────────────────────────────────────────────────────────

final class MemoryUsageReader {

    /// Total physical RAM installed in this Mac (constant, so read once).
    private let totalPhysicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    func readCurrentUsage() -> MemoryUsageSnapshot {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &statistics) { statisticsPointer in
            statisticsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryUsageSnapshot(usedBytes: 0, totalBytes: totalPhysicalMemoryBytes)
        }

        let pageSizeBytes = UInt64(vm_kernel_page_size)

        // Pages currently doing work for apps or the system.
        let activePages = UInt64(statistics.active_count)
        // Pages the kernel has pinned in RAM (cannot be paged out).
        let wiredPages = UInt64(statistics.wire_count)
        // Pages holding compressed data (macOS compresses instead of swapping).
        let compressedPages = UInt64(statistics.compressor_page_count)

        let usedBytes = (activePages + wiredPages + compressedPages) * pageSizeBytes

        // "App" mirrors Activity Monitor: anonymous (internal) pages
        // minus the purgeable ones the system could reclaim instantly.
        let internalPages = UInt64(statistics.internal_page_count)
        let purgeablePages = UInt64(statistics.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0

        let breakdown = MemoryBreakdown(
            appBytes: appPages * pageSizeBytes,
            wiredBytes: wiredPages * pageSizeBytes,
            compressedBytes: compressedPages * pageSizeBytes,
            freeBytes: UInt64(statistics.free_count) * pageSizeBytes
        )

        return MemoryUsageSnapshot(
            usedBytes: usedBytes,
            totalBytes: totalPhysicalMemoryBytes,
            breakdown: breakdown,
            pressurePercent: readPressurePercent()
        )
    }

    /// Memory pressure as 0–100. The kernel publishes an "available
    /// memory" level (kern.memorystatus_level, 0–100, the same number
    /// `memory_pressure` prints); pressure is its inverse.
    private func readPressurePercent() -> Double {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0,
              (0...100).contains(level)
        else { return 0 }
        return Double(100 - level)
    }
}
