import Foundation

// ─────────────────────────────────────────────────────────────────
// Collects the process list shown when hovering the Memory card.
// (The App/Wired/Compressed/Free breakdown lives in the regular
// MemoryUsageReader — same kernel call as the used/total numbers.)
//
// The list comes from `top -o mem`, whose MEM column is the same
// "memory footprint" metric Activity Monitor ranks by (it includes
// each process's compressed pages). Plain `ps` rss can't be used:
// it only counts pages resident in RAM, so under memory pressure
// the biggest consumers — mostly compressed — rank near the bottom.
//
// top truncates command names to ~16 characters, so a follow-up
// `ps -p` fetches each pid's full executable path (also what the
// app-icon lookup needs).
// ─────────────────────────────────────────────────────────────────

final class MemoryDetailsReader {

    func readCurrentDetails() -> MemoryDetails {
        MemoryDetails(topProcesses: readTopProcesses(limit: 5))
    }

    // MARK: Top processes

    private func readTopProcesses(limit: Int) -> [ProcessMemoryUsage] {
        let topOutput = Subprocess.run(
            "/usr/bin/top",
            ["-l", "1", "-o", "mem", "-n", "\(limit)", "-stats", "pid,mem,command"]
        )
        let entries = Self.parseTopOutput(topOutput, limit: limit)
        guard !entries.isEmpty else { return [] }

        let pidList = entries.map { String($0.pid) }.joined(separator: ",")
        let psOutput = Subprocess.run("/bin/ps", ["-o", "pid=,comm=", "-p", pidList])
        let executablePaths = Self.parseExecutablePaths(psOutput)

        return entries.map { entry in
            let path = executablePaths[entry.pid] ?? ""
            return ProcessMemoryUsage(
                id: entry.pid,
                name: path.isEmpty ? entry.name : (path as NSString).lastPathComponent,
                executablePath: path,
                memoryBytes: entry.bytes
            )
        }
    }

    // MARK: Parsing (static + pure so it can be tested without spawning)

    /// top rows look like "42598  2238M+ Code Helper (Plu"; the size
    /// suffix is B/K/M/G and may carry a +/- delta marker. The global
    /// stats header above the rows never matches this shape.
    static func parseTopOutput(_ output: String, limit: Int) -> [(pid: Int32, bytes: UInt64, name: String)] {
        let rowPattern = #/^\s*(\d+)\s+(\d+)([BKMG])[+-]?\s+(.+)$/#
        var rows: [(pid: Int32, bytes: UInt64, name: String)] = []

        for line in output.split(separator: "\n") {
            guard rows.count < limit else { break }
            guard let match = line.wholeMatch(of: rowPattern),
                  let pid = Int32(match.1),
                  let value = UInt64(match.2),
                  value > 0
            else { continue }

            let multiplier: UInt64
            switch match.3 {
            case "K": multiplier = 1 << 10
            case "M": multiplier = 1 << 20
            case "G": multiplier = 1 << 30
            default:  multiplier = 1
            }

            rows.append((
                pid: pid,
                bytes: value * multiplier,
                name: String(match.4).trimmingCharacters(in: .whitespaces)
            ))
        }
        return rows
    }

    /// `ps -o pid=,comm=` rows: "42598 /Applications/.../Code Helper".
    static func parseExecutablePaths(_ psOutput: String) -> [Int32: String] {
        let rowPattern = #/^\s*(\d+)\s+(.+)$/#
        var paths: [Int32: String] = [:]
        for line in psOutput.split(separator: "\n") {
            guard let match = line.wholeMatch(of: rowPattern),
                  let pid = Int32(match.1) else { continue }
            paths[pid] = String(match.2).trimmingCharacters(in: .whitespaces)
        }
        return paths
    }
}
