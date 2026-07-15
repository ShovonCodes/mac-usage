import Foundation

// ─────────────────────────────────────────────────────────────────
// Top processes by network throughput, from `nettop`.
//
// nettop's byte counters are cumulative, so it runs with -d (delta
// mode) and -L 2: the second sample block reports each process's
// bytes moved during the interval — a true rate. One run costs ~5s
// of wall time (nettop's own sampling window), so the store calls
// this on a slow cadence and only while the panel is open.
// ─────────────────────────────────────────────────────────────────

final class NetworkProcessesReader {

    private let sampleIntervalSeconds: Double = 2

    func readTopProcesses(limit: Int = 5) -> [ProcessNetworkUsage] {
        let output = Subprocess.run(
            "/usr/bin/nettop",
            ["-P", "-x", "-d", "-L", "2", "-s", "\(Int(sampleIntervalSeconds))"]
        )
        let entries = Self.parseNettopOutput(
            output,
            intervalSeconds: sampleIntervalSeconds,
            limit: limit
        )
        guard !entries.isEmpty else { return [] }

        // nettop only gives "name.pid" — resolve full paths for icons.
        let pids = entries.compactMap { Self.pid(fromNettopKey: $0.id) }
        let psOutput = Subprocess.run(
            "/bin/ps",
            ["-o", "pid=,comm=", "-p", pids.map(String.init).joined(separator: ",")]
        )
        let paths = MemoryDetailsReader.parseExecutablePaths(psOutput)

        return entries.map { entry in
            guard let pid = Self.pid(fromNettopKey: entry.id),
                  let path = paths[pid]
            else { return entry }
            return ProcessNetworkUsage(
                id: entry.id,
                name: (path as NSString).lastPathComponent,
                executablePath: path,
                uploadBytesPerSecond: entry.uploadBytesPerSecond,
                downloadBytesPerSecond: entry.downloadBytesPerSecond
            )
        }
    }

    /// CSV: header row names the columns; each data row starts with a
    /// sample timestamp and the "name.pid" process key. With -d -L 2,
    /// rows from the LAST timestamp block are per-interval deltas.
    static func parseNettopOutput(
        _ output: String,
        intervalSeconds: Double,
        limit: Int
    ) -> [ProcessNetworkUsage] {
        let lines = output.split(separator: "\n")
        guard let headerLine = lines.first else { return [] }

        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false)
        guard let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out")
        else { return [] }

        // Keep only the final sample block (the delta block).
        guard let lastTime = lines.last?.split(
            separator: ",", omittingEmptySubsequences: false
        ).first else { return [] }

        var rows: [ProcessNetworkUsage] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(bytesInIndex, bytesOutIndex),
                  fields[0] == lastTime,
                  let bytesIn = Double(fields[bytesInIndex]),
                  let bytesOut = Double(fields[bytesOutIndex]),
                  bytesIn + bytesOut > 0
            else { continue }

            let key = String(fields[1])
            rows.append(ProcessNetworkUsage(
                id: key,
                name: Self.name(fromNettopKey: key),
                executablePath: "",
                uploadBytesPerSecond: bytesOut / intervalSeconds,
                downloadBytesPerSecond: bytesIn / intervalSeconds
            ))
        }

        return Array(
            rows.sorted { $0.totalBytesPerSecond > $1.totalBytesPerSecond }.prefix(limit)
        )
    }

    // "Google Chrome H.4821" → name "Google Chrome H", pid 4821
    static func name(fromNettopKey key: String) -> String {
        guard let dot = key.lastIndex(of: ".") else { return key }
        return String(key[..<dot])
    }

    static func pid(fromNettopKey key: String) -> Int32? {
        guard let dot = key.lastIndex(of: ".") else { return nil }
        return Int32(key[key.index(after: dot)...])
    }
}
