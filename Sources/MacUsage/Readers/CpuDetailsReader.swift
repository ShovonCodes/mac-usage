import Foundation

// ─────────────────────────────────────────────────────────────────
// Collects the process list shown when hovering the CPU card.
//
// `ps -Aro pid=,pcpu=,comm=` lists every process sorted by CPU.
// pcpu is the kernel's decaying-average CPU% — instant to read
// (unlike `top`, which needs a ~1s sampling window), close to what
// Activity Monitor shows, and it includes full executable paths.
// ─────────────────────────────────────────────────────────────────

final class CpuDetailsReader {

    func readCurrentDetails() -> CpuDetails {
        let output = Subprocess.run("/bin/ps", ["-Aro", "pid=,pcpu=,comm="])
        return CpuDetails(topProcesses: Self.parseProcesses(output, limit: 5))
    }

    /// Rows look like " 22884  10.3 /Applications/.../Docker Desktop".
    static func parseProcesses(_ psOutput: String, limit: Int) -> [ProcessCpuUsage] {
        let rowPattern = #/^\s*(\d+)\s+([\d.]+)\s+(.+)$/#
        var rows: [ProcessCpuUsage] = []

        for line in psOutput.split(separator: "\n") {
            guard rows.count < limit else { break }
            guard let match = line.wholeMatch(of: rowPattern),
                  let pid = Int32(match.1),
                  let cpuPercent = Double(match.2)
            else { continue }

            let path = String(match.3).trimmingCharacters(in: .whitespaces)
            rows.append(ProcessCpuUsage(
                id: pid,
                name: (path as NSString).lastPathComponent,
                executablePath: path.hasPrefix("/") ? path : "",
                cpuPercent: cpuPercent
            ))
        }
        return rows
    }
}
