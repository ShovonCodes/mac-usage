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
    check("legacy order gains new cards without losing anything",
          Set(legacy) == all && legacy.count == all.count, "got \(legacy.map(\.rawValue))")
    check("cards added later are appended for existing installs",
          Array(legacy.suffix(3)) == [.gpu, .power, .disk],
          "got \(legacy.map(\.rawValue))")
    check("a saved order keeps its own arrangement",
          legacy.prefix(6).map(\.rawValue)
              == ["cpu", "memory", "battery", "network", "temperature", "fans"],
          "got \(legacy.map(\.rawValue))")
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
                 networkDown: 0, cpuTemperature: 40, gpuUtilization: 12, systemPowerWatts: 6, now: base)
    store.record(cpuUser: 30, cpuSystem: 0, memoryPressure: 40, networkUp: 0,
                 networkDown: 0, cpuTemperature: 60, gpuUtilization: 18, systemPowerWatts: 10,
                 now: base.addingTimeInterval(2))
    store.record(cpuUser: 50, cpuSystem: 0, memoryPressure: 60, networkUp: 0,
                 networkDown: 0, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
                 now: base.addingTimeInterval(4))
    check("minute still in progress is not published", store.minutes.isEmpty)

    store.record(cpuUser: 0, cpuSystem: 0, memoryPressure: 0, networkUp: 0,
                 networkDown: 0, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
                 now: base.addingTimeInterval(60))
    check("rollover publishes exactly one row", store.minutes.count == 1,
          "got \(store.minutes.count)")
    check("cpu averaged across the minute", store.minutes[0].cpuUser == 30,
          "got \(store.minutes[0].cpuUser)")
    check("pressure averaged", store.minutes[0].memoryPressure == 40,
          "got \(store.minutes[0].memoryPressure)")
    check("temperature averages only samples that had one",
          store.minutes[0].cpuTemperature == 50,
          "got \(String(describing: store.minutes[0].cpuTemperature))")
    check("gpu averages only samples that had one",
          store.minutes[0].gpuUtilization == 15,
          "got \(String(describing: store.minutes[0].gpuUtilization))")
    check("power averages only samples that had one",
          store.minutes[0].systemPowerWatts == 8,
          "got \(String(describing: store.minutes[0].systemPowerWatts))")
    try? FileManager.default.removeItem(at: tmp)
}

section("HistoryStore: absent sensor stays absent")
MainActor.assumeIsolated {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-test-\(UUID().uuidString).json")
    let store = HistoryStore(fileURL: tmp)
    let base = Date(timeIntervalSince1970: 1_700_000_040)
    store.record(cpuUser: 1, cpuSystem: 1, memoryPressure: 1, networkUp: 1,
                 networkDown: 1, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
                 now: base)
    store.flushPending()
    check("no sensor yields nil, not zero", store.minutes.first?.cpuTemperature == nil)
    check("no GPU yields nil, not zero", store.minutes.first?.gpuUtilization == nil)
    check("no power rail yields nil, not zero",
          store.minutes.first?.systemPowerWatts == nil)
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
                     networkDown: 0, cpuTemperature: 55, gpuUtilization: 33, systemPowerWatts: 7.5,
                     now: now.addingTimeInterval(-120))
        store.flushPending()
        store.record(cpuUser: 99, cpuSystem: 1, memoryPressure: 9, networkUp: 0,
                     networkDown: 0, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
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
        check("gpu series survives a reload",
              reloaded.minutes.first { $0.cpuUser == 42 }?.gpuUtilization == 33,
              "got \(String(describing: reloaded.minutes.first?.gpuUtilization))")
        check("power series survives a reload",
              reloaded.minutes.first { $0.cpuUser == 42 }?.systemPowerWatts == 7.5,
              "got \(String(describing: reloaded.minutes.first?.systemPowerWatts))")
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
                 networkDown: 0, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
                 now: Date())
    store.flushPending()
    check("store still records after a corrupt load", store.minutes.count == 1)
    try? FileManager.default.removeItem(at: bad)

    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-missing-\(UUID().uuidString).json")
    check("missing file starts empty", HistoryStore(fileURL: missing).minutes.isEmpty)

    // A file written by a version that predates a series must still
    // load. Optional fields are what buys that: one non-optional
    // addition would make every old file fail to parse and silently
    // throw away the user's day of history.
    let old = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mu-old-\(UUID().uuidString).json")
    let minute = Int(Date().timeIntervalSince1970 / 60) - 1
    try? """
    [{"m":\(minute),"cpuUser":7,"cpuSystem":3,"memoryPressure":11,\
    "networkUp":0,"networkDown":0}]
    """.write(to: old, atomically: true, encoding: .utf8)
    let upgraded = HistoryStore(fileURL: old)
    check("a file without the gpu field still loads", upgraded.minutes.count == 1,
          "got \(upgraded.minutes.count)")
    check("its missing series read as absent",
          upgraded.minutes.first?.gpuUtilization == nil
              && upgraded.minutes.first?.systemPowerWatts == nil)
    check("its existing series survive", upgraded.minutes.first?.cpuUser == 7)
    try? FileManager.default.removeItem(at: old)

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
                     networkDown: 0, cpuTemperature: nil, gpuUtilization: nil, systemPowerWatts: nil,
                     now: base.addingTimeInterval(Double(i) * 60))
    }
    check("retention capped at 24 h of rows", store.minutes.count <= 1_440,
          "got \(store.minutes.count)")
    check("newest rows kept, oldest dropped",
          store.minutes.last!.cpuUser > store.minutes.first!.cpuUser)
}

section("PowerEnergySummary: watt-minutes become watt-hours")
do {
    func row(_ minute: Int, _ watts: Double?) -> HistoryMinute {
        HistoryMinute(m: minute, systemPowerWatts: watts)
    }
    // 60 minutes at 12 W is exactly 12 Wh, which is the one case where
    // a units mistake cannot hide behind a plausible-looking number.
    let hour = PowerEnergySummary(rows: (0..<60).map { row($0, 12) })
    check("an hour at 12 W is 12 Wh", abs(hour.wattHours - 12) < 0.0001,
          "got \(hour.wattHours)")
    check("average is the mean", hour.averageWatts == 12)
    check("coverage counts the minutes", hour.minutesCovered == 60)

    let mixed = PowerEnergySummary(rows: [row(0, 6), row(1, nil), row(2, 30)])
    check("gaps are left out of the energy total",
          abs(mixed.wattHours - 36.0 / 60) < 0.0001, "got \(mixed.wattHours)")
    check("gaps do not drag the average down", mixed.averageWatts == 18,
          "got \(mixed.averageWatts)")
    check("peak is the highest minute", mixed.peakWatts == 30)
    check("coverage excludes the gap", mixed.minutesCovered == 2)

    let none = PowerEnergySummary(rows: [row(0, nil), row(1, nil)])
    check("no readings reports empty rather than 0 Wh", none.isEmpty)
    check("empty summary has no energy", none.wattHours == 0)
    check("empty rows are safe", PowerEnergySummary(rows: []).isEmpty)
}

section("PowerSnapshot: which rail leads, and when the card exists")
do {
    check("system total leads when present",
          PowerSnapshot(systemWatts: 8, batteryWatts: 9, adapterWatts: 0).totalWatts == 8)
    check("battery rail stands in for a missing system rail",
          PowerSnapshot(systemWatts: nil, batteryWatts: 9, adapterWatts: nil).totalWatts == 9)
    check("adapter rail is the last resort",
          PowerSnapshot(systemWatts: nil, batteryWatts: nil, adapterWatts: 61).totalWatts == 61)
    check("no rail means no card", !PowerSnapshot().isPresent)
    // 0 W is a reading, not an absence: the mains rail sits there
    // whenever the charger is out.
    check("a rail reading zero still counts as present",
          PowerSnapshot(systemWatts: 0).isPresent)
}

section("PowerReader: implausible rail readings are rejected")
do {
    check("a normal wattage passes", PowerReader.plausibleWatts(8.4) == 8.4)
    check("zero passes", PowerReader.plausibleWatts(0) == 0)
    // Seen while scanning the SMC: some keys in the P group answer -1.
    check("negative rejected", PowerReader.plausibleWatts(-1) == nil)
    check("beyond any Mac power supply rejected", PowerReader.plausibleWatts(5_000) == nil)
    check("absent key stays absent", PowerReader.plausibleWatts(nil) == nil)
}

section("PowerHistoryChart: the moving scale has a floor")
do {
    check("idle jitter does not fill the chart",
          PowerHistoryChart.fullScale(for: [0.2, 0.3, 0.1]) == 10,
          "got \(PowerHistoryChart.fullScale(for: [0.2, 0.3, 0.1]))")
    check("a load peak raises the scale to the next 5 W",
          PowerHistoryChart.fullScale(for: [8, 21.4]) == 25,
          "got \(PowerHistoryChart.fullScale(for: [8, 21.4]))")
    check("a peak already on the step is not rounded past it",
          PowerHistoryChart.fullScale(for: [20]) == 20)
    check("an empty window still has a scale",
          PowerHistoryChart.fullScale(for: []) == 10)
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

section("MenuBarSegment: defaults and lane")
do {
    check("only CPU, memory and network start on",
          Set(MenuBarSegment.allCases.filter(\.isOnByDefault)) == [.cpu, .memory, .network],
          "got \(MenuBarSegment.allCases.filter(\.isOnByDefault).map(\.rawValue))")
    check("sensor readings are the slow-lane ones",
          Set(MenuBarSegment.allCases.filter(\.isFedBySlowLane)) == [.gpu, .power, .temperature],
          "got \(MenuBarSegment.allCases.filter(\.isFedBySlowLane).map(\.rawValue))")
    // A shared key would make one switch silently move another.
    check("every segment has its own defaults key",
          Set(MenuBarSegment.allCases.map(\.defaultsKey)).count == MenuBarSegment.allCases.count)
    check("no segment key collides with the strip's own",
          !MenuBarSegment.allCases.map(\.defaultsKey).contains(MenuBarSettings.stripEnabledKey))
    // The strip is meant to read as an abbreviation of the panel, so
    // the segments it shares with the cards must appear in card order.
    let cardOrder = ExpandableSection.allCases.map(\.rawValue)
    let stripOrder = MenuBarSegment.allCases.map(\.rawValue)
    check("segments follow the panel's card order",
          stripOrder == cardOrder.filter(stripOrder.contains),
          "strip \(stripOrder) vs cards \(cardOrder)")
}

section("RefreshCadence: which lane runs how fast")
do {
    check("panel open runs both lanes live",
          RefreshCadence.fast(isPanelOpen: true, isStripVisible: false) == RefreshCadence.live
          && RefreshCadence.slow(isPanelOpen: true, stripNeedsSlowLane: false)
              == RefreshCadence.live)
    check("nothing visible idles both lanes",
          RefreshCadence.fast(isPanelOpen: false, isStripVisible: false) == RefreshCadence.idle
          && RefreshCadence.slow(isPanelOpen: false, stripNeedsSlowLane: false)
              == RefreshCadence.idle)
    check("a strip of syscall readings keeps only the fast lane live",
          RefreshCadence.fast(isPanelOpen: false, isStripVisible: true) == RefreshCadence.live
          && RefreshCadence.slow(isPanelOpen: false, stripNeedsSlowLane: false)
              == RefreshCadence.idle)
    // The point of the middle tier: a sensor reading in the menu bar
    // must not sit frozen for 15 s, but must not drag the SMC to 2 s
    // either.
    check("a sensor in the strip lands between live and idle",
          RefreshCadence.slow(isPanelOpen: false, stripNeedsSlowLane: true)
              == RefreshCadence.stripSensors)
    check("the sensor tier really is in between",
          RefreshCadence.live < RefreshCadence.stripSensors
          && RefreshCadence.stripSensors < RefreshCadence.idle)
}

print("\n\(checks - failures)/\(checks) passed")
if failures > 0 { exit(1) }
}
}
