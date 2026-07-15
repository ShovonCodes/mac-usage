import Foundation

// ─────────────────────────────────────────────────────────────────
// Collects the detailed memory view shown when hovering the Memory
// card: an Activity-Monitor-style breakdown plus the processes that
// use the most RAM.
//
// The breakdown comes from the same kernel VM statistics the basic
// reader uses. The process list comes from `ps axm` (every process,
// pre-sorted by memory, no root needed) — the kernel exposes each
// process's resident size to everyone, which is how we can report
// system processes like WindowServer too.
// ─────────────────────────────────────────────────────────────────

final class MemoryDetailsReader {

    func readCurrentDetails() -> MemoryDetails {
        MemoryDetails(
            breakdown: readBreakdown(),
            topProcesses: readTopProcesses(limit: 5)
        )
    }

    // MARK: Breakdown (App / Wired / Compressed / Free)

    private func readBreakdown() -> MemoryBreakdown {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &statistics) { statisticsPointer in
            statisticsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return MemoryBreakdown() }

        let pageSizeBytes = UInt64(vm_kernel_page_size)

        // "App" mirrors Activity Monitor: anonymous (internal) pages
        // minus the purgeable ones the system could reclaim instantly.
        let internalPages = UInt64(statistics.internal_page_count)
        let purgeablePages = UInt64(statistics.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0

        return MemoryBreakdown(
            appBytes: appPages * pageSizeBytes,
            wiredBytes: UInt64(statistics.wire_count) * pageSizeBytes,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageSizeBytes,
            freeBytes: UInt64(statistics.free_count) * pageSizeBytes
        )
    }

    // MARK: Top processes

    private func readTopProcesses(limit: Int) -> [ProcessMemoryUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // axm = all processes, sorted by memory. `=` after each column
        // suppresses the header line. rss is in KiB; comm is the full
        // executable path (it may contain spaces).
        process.arguments = ["axm", "-o", "pid=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // silence; a failure just yields []

        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseTopProcesses(fromPsOutput: output, limit: limit)
    }

    /// Parsing kept separate and static so it can be exercised without
    /// spawning ps.
    static func parseTopProcesses(fromPsOutput output: String, limit: Int) -> [ProcessMemoryUsage] {
        let linePattern = #/^\s*(\d+)\s+(\d+)\s+(.+)$/#
        var results: [ProcessMemoryUsage] = []

        for line in output.split(separator: "\n") {
            guard results.count < limit else { break }
            guard let match = line.wholeMatch(of: linePattern),
                  let pid = Int32(match.1),
                  let rssKiB = UInt64(match.2),
                  rssKiB > 0
            else { continue }

            let path = String(match.3).trimmingCharacters(in: .whitespaces)
            results.append(ProcessMemoryUsage(
                id: pid,
                name: (path as NSString).lastPathComponent,
                executablePath: path,
                memoryBytes: rssKiB * 1024
            ))
        }
        return results
    }
}
