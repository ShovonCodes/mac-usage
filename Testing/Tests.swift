import Foundation

var failures = 0, checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name) \(detail())") }
}
func section(_ s: String) { print("\n\(s)") }

@main struct Tests {
static func main() {

section("TimeBuckets: placement by timestamp")
do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // 4 slots over 120s => 30s each.
    let samples = [
        now.addingTimeInterval(-110),  // slot 0
        now.addingTimeInterval(-95),   // slot 0
        now.addingTimeInterval(-75),   // slot 1
        now.addingTimeInterval(-5),    // slot 3
        now.addingTimeInterval(-300),  // outside window, dropped
    ]
    let slots = TimeBuckets.slots(samples, timestamp: { $0 }, window: 120, slotCount: 4, now: now)
    check("slot count", slots.count == 4, "got \(slots.count)")
    check("slot 0 holds two", slots[0].count == 2, "got \(slots[0].count)")
    check("slot 1 holds one", slots[1].count == 1, "got \(slots[1].count)")
    check("slot 2 empty (real gap preserved)", slots[2].isEmpty)
    check("slot 3 holds one", slots[3].count == 1, "got \(slots[3].count)")
    check("older-than-window dropped", slots.flatMap { $0 }.count == 4)
}

section("TimeBuckets: boundary safety")
do {
    let now = Date(timeIntervalSince1970: 2_000_000)
    // Exactly at `now` must land in the last slot, not out of bounds.
    let atNow = TimeBuckets.slots([now], timestamp: { $0 }, window: 60, slotCount: 6, now: now)
    check("sample exactly at now lands in last slot", atNow[5].count == 1)
    // A sample timestamped in the future must not crash or escape.
    let future = TimeBuckets.slots([now.addingTimeInterval(90)], timestamp: { $0 },
                                   window: 60, slotCount: 6, now: now)
    check("future sample clamped into last slot", future[5].count == 1)
    check("degenerate slotCount returns empty",
          TimeBuckets.slots([now], timestamp: { $0 }, window: 60, slotCount: 0, now: now).isEmpty)
    check("degenerate window returns empty",
          TimeBuckets.slots([now], timestamp: { $0 }, window: 0, slotCount: 6, now: now).isEmpty)
}

section("TimeBuckets: averaging")
do {
    let now = Date(timeIntervalSince1970: 3_000_000)
    struct S { let t: Date; let v: Double }
    let samples = [S(t: now.addingTimeInterval(-50), v: 10),
                   S(t: now.addingTimeInterval(-45), v: 30)]
    let slots = TimeBuckets.slots(samples, timestamp: \.t, window: 60, slotCount: 2, now: now)
    let avg = TimeBuckets.averaged(slots) { $0.v }
    check("empty slot averages to nil", avg[1] == nil)
    check("populated slot averages", avg[0] == 20, "got \(String(describing: avg[0]))")
}

section("ExpandableSection: card order parsing")
do {
    let all = Set(ExpandableSection.allCases)
    check("empty string yields every card in default order",
          ExpandableSection.order(from: "") == ExpandableSection.allCases)
    let legacy = ExpandableSection.order(from: "cpu,memory,battery,network,temperature,fans")
    check("legacy order gains disk without losing anything",
          Set(legacy) == all && legacy.count == all.count, "got \(legacy.map(\.rawValue))")
    check("disk appended at the end for existing installs",
          legacy.last == .disk, "got \(String(describing: legacy.last))")
    check("unknown entries dropped",
          !ExpandableSection.order(from: "cpu,bogus,memory").map(\.rawValue).contains("bogus"))
    let duped = ExpandableSection.order(from: "cpu,cpu,cpu,memory")
    check("duplicates collapse", duped.count == all.count, "got \(duped.count)")
    check("round trip is stable",
          ExpandableSection.order(from: ExpandableSection.rawValue(for: legacy)) == legacy)
    check("garbage yields a complete set",
          Set(ExpandableSection.order(from: ",,,@@@,,")) == all)
}

section("HistoryStore: minute rollover and averaging")
MainActor.assumeIsolated {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-test-\(UUID().uuidString).json")
    let store = HistoryStore(fileURL: tmp)
    let base = Date(timeIntervalSince1970: 1_700_000_040) // mid-minute

    // Three samples inside one minute, then one in the next.
    store.record(cpuUser: 10, cpuSystem: 0, memoryPressure: 20, networkUp: 0,
                 networkDown: 0, cpuTemperature: 40, now: base)
    store.record(cpuUser: 30, cpuSystem: 0, memoryPressure: 40, networkUp: 0,
                 networkDown: 0, cpuTemperature: 60, now: base.addingTimeInterval(2))
    store.record(cpuUser: 50, cpuSystem: 0, memoryPressure: 60, networkUp: 0,
                 networkDown: 0, cpuTemperature: nil, now: base.addingTimeInterval(4))
    check("minute still in progress is not published", store.minutes.isEmpty)

    store.record(cpuUser: 0, cpuSystem: 0, memoryPressure: 0, networkUp: 0,
                 networkDown: 0, cpuTemperature: nil, now: base.addingTimeInterval(60))
    check("rollover publishes exactly one row", store.minutes.count == 1,
          "got \(store.minutes.count)")
    check("cpu averaged across the minute", store.minutes[0].cpuUser == 30,
          "got \(store.minutes[0].cpuUser)")
    check("pressure averaged", store.minutes[0].memoryPressure == 40,
          "got \(store.minutes[0].memoryPressure)")
    check("temperature averages only samples that had one",
          store.minutes[0].cpuTemperature == 50,
          "got \(String(describing: store.minutes[0].cpuTemperature))")
    try? FileManager.default.removeItem(at: tmp)
}

section("HistoryStore: absent sensor stays absent")
MainActor.assumeIsolated {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-test-\(UUID().uuidString).json")
    let store = HistoryStore(fileURL: tmp)
    let base = Date(timeIntervalSince1970: 1_700_000_040)
    store.record(cpuUser: 1, cpuSystem: 1, memoryPressure: 1, networkUp: 1,
                 networkDown: 1, cpuTemperature: nil, now: base)
    store.flushPending()
    check("no sensor yields nil, not zero", store.minutes.first?.cpuTemperature == nil)
    try? FileManager.default.removeItem(at: tmp)
}

section("HistoryStore: save, reload, prune")
MainActor.assumeIsolated {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-test-\(UUID().uuidString).json")
    let now = Date()
    do {
        let store = HistoryStore(fileURL: tmp)
        // One fresh minute, one two days stale.
        store.record(cpuUser: 42, cpuSystem: 8, memoryPressure: 5, networkUp: 0,
                     networkDown: 0, cpuTemperature: 55, now: now.addingTimeInterval(-120))
        store.flushPending()
        store.record(cpuUser: 99, cpuSystem: 1, memoryPressure: 9, networkUp: 0,
                     networkDown: 0, cpuTemperature: nil,
                     now: now.addingTimeInterval(-48 * 3600))
        store.flushPending()
        store.save()
    }
    check("file written", FileManager.default.fileExists(atPath: tmp.path))
    check("no .tmp sibling left behind",
          !FileManager.default.fileExists(atPath: tmp.appendingPathExtension("tmp").path))
    do {
        let reloaded = HistoryStore(fileURL: tmp)
        check("recent row survives a reload",
              reloaded.minutes.contains { $0.cpuUser == 42 })
        check("row older than 24 h pruned on load",
              !reloaded.minutes.contains { $0.cpuUser == 99 })
        check("recent(hours:) filters", reloaded.recent(hours: 0.1, now: now).count == 1,
              "got \(reloaded.recent(hours: 0.1, now: now).count)")
        check("recent(hours:) excludes out-of-range",
              reloaded.recent(hours: 0.01, now: now).isEmpty)
    }
    try? FileManager.default.removeItem(at: tmp)
}

section("HistoryStore: corrupt and missing files")
MainActor.assumeIsolated {
    let bad = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-bad-\(UUID().uuidString).json")
    try? "not json at all {{{".write(to: bad, atomically: true, encoding: .utf8)
    let store = HistoryStore(fileURL: bad)
    check("corrupt file is discarded, not fatal", store.minutes.isEmpty)
    // And it must still be usable afterwards.
    store.record(cpuUser: 5, cpuSystem: 5, memoryPressure: 5, networkUp: 0,
                 networkDown: 0, cpuTemperature: nil, now: Date())
    store.flushPending()
    check("store still records after a corrupt load", store.minutes.count == 1)
    try? FileManager.default.removeItem(at: bad)

    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-missing-\(UUID().uuidString).json")
    check("missing file starts empty", HistoryStore(fileURL: missing).minutes.isEmpty)

    check("nil fileURL degrades to memory only",
          HistoryStore(fileURL: nil).minutes.isEmpty)
}

section("HistoryStore: retention ceiling")
MainActor.assumeIsolated {
    let store = HistoryStore(fileURL: nil)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // 1500 consecutive minutes, past the 1440 cap.
    for i in 0..<1_500 {
        store.record(cpuUser: Double(i), cpuSystem: 0, memoryPressure: 0, networkUp: 0,
                     networkDown: 0, cpuTemperature: nil,
                     now: base.addingTimeInterval(Double(i) * 60))
    }
    check("retention capped at 24 h of rows", store.minutes.count <= 1_440,
          "got \(store.minutes.count)")
    check("newest rows kept, oldest dropped",
          store.minutes.last!.cpuUser > store.minutes.first!.cpuUser)
}

section("AlertEngine: hysteresis stops flapping")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.thresholds[.cpu] = 90
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor func at(_ cpu: Double, _ offset: TimeInterval) -> (firing: [StatAlert], toNotify: [StatAlert]) {
        engine.evaluate(AlertReading(cpuBusyPercent: cpu), settings: settings,
                        now: t0.addingTimeInterval(offset))
    }
    check("below threshold does not fire", at(89, 0).firing.isEmpty)
    check("above threshold fires", at(91, 2).firing.count == 1)
    // Recovering to just under 90 must NOT clear: that is the flap.
    check("stays firing at 88 (inside rearm margin)", at(88, 4).firing.count == 1)
    check("stays firing at 86", at(86, 6).firing.count == 1)
    check("clears once past the margin (84 < 90-5)", at(84, 8).firing.isEmpty)
    check("does not refire at 89 after clearing", at(89, 10).firing.isEmpty)
    check("refires above threshold again", at(95, 12).firing.count == 1)
}

section("AlertEngine: notifications fire on transition only")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.thresholds[.cpu] = 50
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor func at(_ cpu: Double, _ offset: TimeInterval) -> (firing: [StatAlert], toNotify: [StatAlert]) {
        engine.evaluate(AlertReading(cpuBusyPercent: cpu), settings: settings,
                        now: t0.addingTimeInterval(offset))
    }
    check("first crossing notifies", at(60, 0).toNotify.count == 1)
    check("still firing does not renotify", at(70, 2).toNotify.isEmpty)
    check("still firing does not renotify again", at(80, 4).toNotify.isEmpty)
    _ = at(10, 6)  // clears
    check("recross inside cooldown stays silent", at(60, 8).toNotify.isEmpty)
    _ = at(10, 10)
    check("recross after cooldown notifies again",
          at(60, 11 * 60).toNotify.count == 1)
    check("notifications suppressed when switched off", {
        var quiet = settings; quiet.notificationsEnabled = false
        let e = AlertEngine()
        return e.evaluate(AlertReading(cpuBusyPercent: 99), settings: quiet, now: t0)
            .toNotify.isEmpty
    }())
    check("but it still fires for the badge", {
        var quiet = settings; quiet.notificationsEnabled = false
        let e = AlertEngine()
        return e.evaluate(AlertReading(cpuBusyPercent: 99), settings: quiet, now: t0)
            .firing.count == 1
    }())
}

section("AlertEngine: battery fires downwards")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.enabled = Dictionary(uniqueKeysWithValues:
        AlertRule.allCases.map { ($0, $0 == .batteryLow) })
    settings.thresholds[.batteryLow] = 10
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor func battery(_ level: Double, present: Bool = true, discharging: Bool = true) -> [StatAlert] {
        engine.evaluate(AlertReading(batteryPercent: level, batteryIsPresent: present,
                                     batteryIsDischarging: discharging),
                        settings: settings, now: t0).firing
    }
    check("above threshold quiet", battery(20).isEmpty)
    check("below threshold fires", battery(8).count == 1)
    check("charging back to 12 stays firing (rearm margin)", battery(12).count == 1)
    check("clears past the margin", battery(16).isEmpty)
    check("desktop with no battery never fires", battery(0, present: false).isEmpty)
    check("plugged in never fires", battery(2, discharging: false).isEmpty)
}

section("AlertEngine: absent sensor is not a passing reading")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.enabled = Dictionary(uniqueKeysWithValues:
        AlertRule.allCases.map { ($0, $0 == .cpuTemperature) })
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let none = engine.evaluate(AlertReading(cpuTemperatureCelsius: nil),
                               settings: settings, now: t0)
    check("no temperature sensor yields no alert", none.firing.isEmpty)
    let hot = engine.evaluate(AlertReading(cpuTemperatureCelsius: 99),
                              settings: settings, now: t0)
    check("hot sensor does fire", hot.firing.count == 1)
}

section("AlertEngine: disabled rules and threshold clamping")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.enabled[.cpu] = false
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check("disabled rule never fires",
          engine.evaluate(AlertReading(cpuBusyPercent: 100), settings: settings, now: t0)
            .firing.isEmpty)

    var absurd = AlertSettings()
    absurd.thresholds[.cpu] = -500
    check("absurd low threshold clamped into range",
          absurd.threshold(for: .cpu) == AlertRule.cpu.allowedRange.lowerBound,
          "got \(absurd.threshold(for: .cpu))")
    absurd.thresholds[.cpu] = 9_999
    check("absurd high threshold clamped into range",
          absurd.threshold(for: .cpu) == AlertRule.cpu.allowedRange.upperBound)
    check("unset threshold falls back to the default",
          AlertSettings().threshold(for: .memoryPressure) == 80)
    check("unset enabled falls back to on", AlertSettings().isEnabled(.cpu))
}

section("AlertEngine: rules are independent")
MainActor.assumeIsolated {
    let engine = AlertEngine()
    var settings = AlertSettings()
    settings.thresholds[.cpu] = 50
    settings.thresholds[.memoryPressure] = 50
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let both = engine.evaluate(
        AlertReading(cpuBusyPercent: 99, memoryPressurePercent: 99),
        settings: settings, now: t0)
    check("two rules fire together", both.firing.count == 2, "got \(both.firing.count)")
    check("ids are stable and distinct",
          Set(both.firing.map(\.id)) == ["cpu", "memoryPressure"],
          "got \(both.firing.map(\.id))")
    let one = engine.evaluate(
        AlertReading(cpuBusyPercent: 10, memoryPressurePercent: 99),
        settings: settings, now: t0.addingTimeInterval(2))
    check("clearing one leaves the other", one.firing.map(\.id) == ["memoryPressure"],
          "got \(one.firing.map(\.id))")
}

print("\n\(checks - failures)/\(checks) passed")
if failures > 0 { exit(1) }
}
}
