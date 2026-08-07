import Foundation

// ─────────────────────────────────────────────────────────────────
// Putting samples where they actually belong in time.
//
// Every history buffer in this app is appended to once per refresh
// tick, and those ticks are not evenly spaced: 2 s while the panel is
// open or the menu bar strip is on, 15 s otherwise. A chart that
// draws one bar per sample therefore draws a distorted x axis, where
// a stretch recorded while the panel was closed occupies the same
// width as a stretch recorded while it was open.
//
// The CPU chart did exactly that and could silently span anywhere
// from 2 to 15 minutes. The network chart already avoided it with a
// private bucketing routine; this is that idea pulled out so every
// chart shares it.
//
// Samples are dropped into fixed-width slots covering a fixed window
// ending "now". Slots with nothing in them stay empty, which is the
// honest answer: a gap in the data draws as a gap, rather than being
// closed up by the bars on either side.
// ─────────────────────────────────────────────────────────────────

enum TimeBuckets {

    /// Group `samples` into `slotCount` equal slots spanning the
    /// `window` seconds before `now`. Oldest slot first. A slot with
    /// no samples comes back empty.
    ///
    /// `now` is a parameter rather than being read inside so this is
    /// deterministic and testable.
    static func slots<Sample>(
        _ samples: [Sample],
        timestamp: (Sample) -> Date,
        window: TimeInterval,
        slotCount: Int,
        now: Date
    ) -> [[Sample]] {
        guard slotCount > 0, window > 0 else { return [] }
        var result = [[Sample]](repeating: [], count: slotCount)
        let start = now.addingTimeInterval(-window)
        let slotSeconds = window / Double(slotCount)

        for sample in samples {
            let offset = timestamp(sample).timeIntervalSince(start)
            guard offset >= 0 else { continue }   // older than the window
            let index = Int(offset / slotSeconds)
            // A sample timestamped a hair in the future (or exactly at
            // `now`) must not run off the end.
            result[min(slotCount - 1, max(0, index))].append(sample)
        }
        return result
    }

    /// Mean of a value across each slot, or nil where a slot is empty.
    static func averaged<Sample>(
        _ slots: [[Sample]],
        value: (Sample) -> Double
    ) -> [Double?] {
        slots.map { samples in
            guard !samples.isEmpty else { return nil }
            return samples.reduce(0) { $0 + value($1) } / Double(samples.count)
        }
    }
}
