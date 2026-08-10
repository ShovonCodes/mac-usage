import Foundation
import IOKit

// ─────────────────────────────────────────────────────────────────
// How hard the GPU is working, from the IO registry.
//
// Every graphics driver publishes an `IOAccelerator` service whose
// `PerformanceStatistics` dictionary carries "Device Utilization %".
// No root, no entitlement, no subprocess. Measured at ~2.5 ms per
// read on an M1, which is the same class of cost as DiskReader's
// registry walk - hence the slow lane.
//
// The same dictionary also carries "Renderer Utilization %" and
// "Tiler Utilization %", the two halves of Apple's tile-based
// pipeline. They are deliberately not read: measured on an M1 they
// track the device figure within about three points, idle and under a
// pure-compute Metal load alike (device 99%, renderer 96%, tiler
// 96%). Three rows showing the same number is not a breakdown.
//
// ── The one thing to know about this source ──────────────────────
// "Device Utilization %" is *not* an instantaneous sample. It is the
// share of time the GPU was busy **since the last read of that
// property**, and reading it resets the window. Verified on an M1:
//
//     read, wait 3 s, read  →  13%
//     read again, at once   →   0%
//     read again, at once   →   0%
//     wait 3 s, read        →  13%
//
// Two consequences the rest of the app has to respect:
//
//  1. There must be exactly one caller on one cadence. A second
//     reader (say, a menu bar lane at 2 s alongside a panel lane at
//     15 s) would keep stealing each other's window and both would
//     report nonsense. This is why StatsStore calls it from the slow
//     lane only and the menu bar strip reads the published snapshot
//     rather than the reader.
//  2. The number is an average over the gap since the previous read,
//     so it means "busy over the last 2 s" with the panel open and
//     "busy over the last 15 s" without. That is the same bargain
//     every other slow-lane rate makes, and it is the honest one: a
//     true instant sample of a GPU is mostly noise.
//
// Multi-GPU Macs (Intel models with a discrete card) publish one
// service each, so the reader keeps them all and the snapshot's
// headline figure is whichever is busiest. Apple Silicon has exactly
// one.
// ─────────────────────────────────────────────────────────────────

final class GpuReader {

    init() {
        // The utilization window starts at whoever read the property
        // last, which before launch could have been any process at any
        // time - or nobody, in which case it reaches back to boot.
        // One throwaway read makes the first published figure measure
        // a window this app defines rather than an unknown one.
        _ = readSnapshot()
    }

    func readSnapshot() -> GpuSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return GpuSnapshot() }
        defer { IOObjectRelease(iterator) }

        var devices: [GpuDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let device = readDevice(service) {
                devices.append(device)
            }
        }
        return GpuSnapshot(devices: devices)
    }

    private func readDevice(_ service: io_registry_entry_t) -> GpuDevice? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // The registry entry name ("AGXAcceleratorG13G_B0") is stable
        // across reads and unique per card, so it identifies the row.
        // The friendly name comes from "model" ("Apple M1"); a card
        // that publishes no model falls back to the entry name rather
        // than showing a blank.
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS
        else { return nil }
        let entryName = String(cString: nameBuffer)

        let statistics = dictionary["PerformanceStatistics"] as? [String: Any] ?? [:]

        return GpuDevice(
            id: entryName,
            name: modelName(dictionary) ?? entryName,
            coreCount: (dictionary["gpu-core-count"] as? NSNumber)?.intValue,
            utilizationPercent: percent(statistics["Device Utilization %"]) ?? 0,
            // Unified-memory Macs report the GPU's slice of system RAM;
            // discrete cards report dedicated VRAM under a different
            // key. Try both so an Intel Mac is not left showing zero.
            inUseMemoryBytes: bytes(statistics["In use system memory"])
                ?? bytes(statistics["vramUsedBytes"]) ?? 0,
            allocatedMemoryBytes: bytes(statistics["Alloc system memory"]) ?? 0
        )
    }

    /// "model" is a CFString on Apple Silicon but a NUL-terminated
    /// CFData blob on some Intel drivers, so both shapes are decoded.
    private func modelName(_ dictionary: [String: Any]) -> String? {
        if let text = dictionary["model"] as? String { return text }
        guard let data = dictionary["model"] as? Data else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return text.isEmpty ? nil : text
    }

    /// Utilization keys arrive as integers; clamp to 0-100 so a driver
    /// reporting something odd cannot overdraw a gauge.
    private func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return min(max(number.doubleValue, 0), 100)
    }

    private func bytes(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return UInt64(max(0, number.int64Value))
    }
}
