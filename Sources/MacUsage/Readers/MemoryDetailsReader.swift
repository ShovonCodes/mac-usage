import Foundation

// ─────────────────────────────────────────────────────────────────
// Collects the process list shown when hovering the Memory card.
// (The App/Wired/Compressed/Free breakdown lives in the regular
// MemoryUsageReader — same kernel call as the used/total numbers.)
//
// The list comes from `ps axm` (every process, pre-sorted by memory,
// no root needed) — the kernel exposes each process's resident size
// to everyone, which is how we can report system processes like
// WindowServer too.
// ─────────────────────────────────────────────────────────────────

final class MemoryDetailsReader {

    func readCurrentDetails() -> MemoryDetails {
        MemoryDetails(topProcesses: readTopProcesses(limit: 5))
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
