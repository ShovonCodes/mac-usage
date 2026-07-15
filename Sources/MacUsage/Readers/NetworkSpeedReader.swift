import Foundation

// ─────────────────────────────────────────────────────────────────
// Reads current network throughput from the kernel's per-interface
// byte counters (sysctl NET_RT_IFLIST2 — same source netstat uses,
// with 64-bit counters that don't wrap). Two consecutive readings
// give bytes/second, exactly like the CPU reader's tick deltas.
//
// Virtual interfaces (loopback, VPN tunnels, AirDrop, ...) are
// skipped so traffic isn't double-counted.
// ─────────────────────────────────────────────────────────────────

final class NetworkSpeedReader {

    private var previousTotals: (up: UInt64, down: UInt64)?
    private var previousDate: Date?

    func readCurrentSpeed() -> NetworkSpeedSnapshot {
        let totals = Self.readInterfaceTotals()
        let now = Date()
        defer {
            previousTotals = totals
            previousDate = now
        }

        guard let previousTotals, let previousDate else { return NetworkSpeedSnapshot() }
        let seconds = now.timeIntervalSince(previousDate)
        guard seconds > 0.1 else { return NetworkSpeedSnapshot() }

        // Counters can jump backwards if an interface detaches — clamp.
        let up = totals.up >= previousTotals.up
            ? Double(totals.up - previousTotals.up) / seconds : 0
        let down = totals.down >= previousTotals.down
            ? Double(totals.down - previousTotals.down) / seconds : 0

        return NetworkSpeedSnapshot(uploadBytesPerSecond: up, downloadBytesPerSecond: down)
    }

    /// Interfaces that don't represent real external traffic.
    private static let skippedPrefixes = ["lo", "utun", "awdl", "llw", "gif", "stf", "bridge", "ap"]

    private static func readInterfaceTotals() -> (up: UInt64, down: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var up: UInt64 = 0
        var down: UInt64 = 0
        var offset = 0

        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            }
            if Int32(header.ifm_type) == RTM_IFINFO2 {
                let header2 = buffer.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                if if_indextoname(UInt32(header2.ifm_index), &nameBuffer) != nil {
                    let name = String(cString: nameBuffer)
                    if !skippedPrefixes.contains(where: { name.hasPrefix($0) }) {
                        down &+= header2.ifm_data.ifi_ibytes
                        up &+= header2.ifm_data.ifi_obytes
                    }
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return (up, down)
    }
}
