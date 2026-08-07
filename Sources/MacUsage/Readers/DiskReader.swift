import Foundation
import IOKit

// ─────────────────────────────────────────────────────────────────
// Boot volume capacity, and how hard the disks are being worked.
//
// Two unrelated sources in one reader, because they answer one
// question ("how is the disk doing?") and belong on one card:
//
//  • Space comes from URLResourceValues. The key is
//    `volumeAvailableCapacityForImportantUsage`, not the plain
//    available-capacity key: it counts purgeable space the system
//    would reclaim under pressure, which is the number Finder and
//    System Settings show. The plain key reads several GB lower and
//    would make the app disagree with the rest of the Mac. (Same
//    principle as battery health matching System Settings.)
//
//  • Throughput comes from each IOBlockStorageDriver's "Statistics"
//    dictionary in the IO registry: "Bytes (Read)" and
//    "Bytes (Write)" are counters since boot, so a rate is the
//    difference between two samples divided by the elapsed time.
//    No root needed.
//
// Virtual devices are skipped. A mounted disk image publishes an
// IOBlockStorageDriver exactly like real hardware does, so opening a
// .dmg would otherwise register as disk activity. The driver's
// provider (an IOBlockStorageDevice) tags itself in its "Protocol
// Characteristics": real storage reports an interconnect like
// "Apple Fabric", a disk image reports "Virtual Interface". This is
// the same idea as NetworkSpeedReader skipping lo/utun/awdl.
// ─────────────────────────────────────────────────────────────────

final class DiskReader {

    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousSampleTime: Date?

    func readSnapshot() -> DiskSnapshot {
        var snapshot = DiskSnapshot()

        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            snapshot.totalBytes = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            snapshot.freeBytes = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        }

        let (readBytes, writeBytes) = readByteCounters()
        let now = Date()
        if let previousSampleTime {
            let elapsed = now.timeIntervalSince(previousSampleTime)
            if elapsed > 0 {
                // &- so a counter reset (device replug) yields a huge
                // wrapped value rather than trapping; the max(0,) and
                // the sanity of the next sample absorb it.
                snapshot.readBytesPerSecond =
                    Double(readBytes &- previousReadBytes) / elapsed
                snapshot.writeBytesPerSecond =
                    Double(writeBytes &- previousWriteBytes) / elapsed
            }
        }
        previousReadBytes = readBytes
        previousWriteBytes = writeBytes
        previousSampleTime = now

        return snapshot
    }

    /// Cumulative bytes read and written across every physical drive.
    private func readByteCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard isPhysical(driver) else { continue }
            guard let statistics = IORegistryEntryCreateCFProperty(
                driver, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            totalRead += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            totalWrite += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (totalRead, totalWrite)
    }

    /// True unless the driver's device advertises a virtual
    /// interconnect, which is how disk images present themselves.
    private func isPhysical(_ driver: io_registry_entry_t) -> Bool {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(device) }

        let characteristics = IORegistryEntryCreateCFProperty(
            device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let interconnect = characteristics?["Physical Interconnect"] as? String
        return interconnect != "Virtual Interface"
    }
}
