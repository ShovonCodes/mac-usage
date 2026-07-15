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

        return MemoryUsageSnapshot(
            usedBytes: usedBytes,
            totalBytes: totalPhysicalMemoryBytes
        )
    }
}
