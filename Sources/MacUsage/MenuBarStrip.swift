import AppKit

// ─────────────────────────────────────────────────────────────────
// The live readout drawn next to the menu bar glyph.
//
// Everything here is drawn into a single NSImage that the status item
// uses as its button image, exactly like the glyph already was. That
// keeps one rule intact: while nothing is alerting, the image is a
// *template*, so macOS reads only its alpha channel and recolors it
// black in a light menu bar and white in a dark one. That is why the
// strip is monochrome, and why everything below draws in one color
// passed down from the top rather than picking its own.
//
// Width is not fixed. The status item uses `variableLength` and the
// image is sized to whatever segments are switched on, so turning a
// segment off genuinely gives the width back to the menu bar.
// ─────────────────────────────────────────────────────────────────

/// One readout in the strip, in fixed left-to-right order.
///
/// The order matches the panel's default card order, so the menu bar
/// reads as an abbreviation of the panel rather than as a second,
/// differently-sorted list of the same numbers.
///
/// Battery is deliberately absent: macOS already shows it natively,
/// and a second copy would be pure duplication.
enum MenuBarSegment: String, CaseIterable, Identifiable {
    case cpu
    case gpu
    case memory
    case power
    case network
    case temperature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .power: return "Power"
        case .network: return "Network"
        case .temperature: return "Temperature"
        }
    }

    var defaultsKey: String {
        switch self {
        case .cpu: return "menuBarShowCpu"
        case .gpu: return "menuBarShowGpu"
        case .memory: return "menuBarShowMemory"
        case .power: return "menuBarShowPower"
        case .network: return "menuBarShowNetwork"
        case .temperature: return "menuBarShowTemperature"
        }
    }

    /// CPU, memory and network are the three worth a permanent slice of
    /// the menu bar on any Mac. GPU, power and temperature start off:
    /// they matter enormously to some people and never to most, and
    /// every segment that is on costs width for everyone.
    var isOnByDefault: Bool {
        switch self {
        case .cpu, .memory, .network: return true
        case .gpu, .power, .temperature: return false
        }
    }

    /// True for readings produced by StatsStore's slow lane (the SMC,
    /// the IO registry) rather than its fast one.
    ///
    /// The store needs this: with the panel shut the slow lane drops to
    /// 15 s, which is invisible when these numbers only live in the
    /// panel but reads as a frozen display when one of them is sitting
    /// in the menu bar next to a sparkline moving every 2 s.
    var isFedBySlowLane: Bool {
        switch self {
        case .cpu, .memory, .network: return false
        case .gpu, .power, .temperature: return true
        }
    }
}

/// The defaults the strip reads. Shared so StatsStore (which needs to
/// know whether to keep the fast lane running while the panel is shut)
/// and the Settings window agree on the keys.
enum MenuBarSettings {
    static let stripEnabledKey = "showMenuBarStrip"

    /// `UserDefaults.bool(forKey:)` returns false for an unset key, so
    /// every default that should start *on* has to check for absence
    /// rather than read the bool directly.
    static var isStripEnabled: Bool {
        UserDefaults.standard.object(forKey: stripEnabledKey) as? Bool ?? true
    }

    static func isEnabled(_ segment: MenuBarSegment) -> Bool {
        UserDefaults.standard.object(forKey: segment.defaultsKey) as? Bool
            ?? segment.isOnByDefault
    }

    /// Segments to draw right now, in enum order. Empty when the strip
    /// is switched off entirely, which leaves the glyph on its own and
    /// the menu bar exactly as it was before the strip existed.
    static var visibleSegments: [MenuBarSegment] {
        guard isStripEnabled else { return [] }
        return MenuBarSegment.allCases.filter(isEnabled)
    }

    /// True when at least one visible segment is fed by the slow lane.
    /// StatsStore reads this to decide how fast that lane has to run
    /// while the panel is shut.
    static var stripNeedsSlowLane: Bool {
        visibleSegments.contains { $0.isFedBySlowLane }
    }
}

extension AlertRule {
    /// nil: the strip never shows this reading, so its alert is a dot.
    var stripSegment: MenuBarSegment? {
        switch self {
        case .cpu: return .cpu
        case .memoryPressure: return .memory
        case .cpuTemperature: return .temperature
        case .batteryLow: return nil
        }
    }
}

/// Red segments for alerts whose reading is on screen, a dot for the rest.
struct MenuBarAlertMarks: Equatable {
    private(set) var redSegments: Set<MenuBarSegment> = []
    private(set) var showsDot = false

    /// `drawn` excludes enabled segments with no reading: they take no width.
    init(firing: [AlertRule], drawn: [MenuBarSegment]) {
        for rule in firing {
            if let segment = rule.stripSegment, drawn.contains(segment) {
                redSegments.insert(segment)
            } else {
                showsDot = true
            }
        }
    }

    var isEmpty: Bool { redSegments.isEmpty && !showsDot }
}

/// The values one redraw needs. Assembled by the AppDelegate from the
/// store so the drawing code stays free of any view model.
struct MenuBarReadout {
    var cpuBusyPercent: Double = 0
    /// Total busy percent per tick, oldest first, for the sparkline.
    var cpuHistory: [Double] = []
    /// Pressure, not "how much RAM is allocated". macOS deliberately
    /// fills unused RAM with cache, so a high usage figure is normal
    /// and says nothing; pressure is the number that tells you the
    /// machine is actually struggling. Activity Monitor leads with it
    /// for the same reason.
    var memoryPressurePercent: Double = 0
    var uploadBytesPerSecond: Double = 0
    var downloadBytesPerSecond: Double = 0
    var cpuTemperatureCelsius: Double?
    /// nil when no GPU could be read at all, which is a different thing
    /// from a GPU sitting idle at 0%. The segment disappears for the
    /// first and shows "0%" for the second.
    var gpuUtilizationPercent: Double?
    /// Whole-system draw. nil on a Mac exposing no usable power rail.
    var systemWatts: Double?
}

enum MenuBarStrip {

    private static let glyphSize: CGFloat = 24
    private static let textSize: CGFloat = 11
    private static let sparklineWidth: CGFloat = 26
    private static let sparklineHeight: CGFloat = 12
    /// Chip body plus a pin's width on each side.
    private static let meterWidth: CGFloat = 12
    private static let pinLength: CGFloat = 1.5
    private static let thermometerWidth: CGFloat = 7
    private static let ringDiameter: CGFloat = 12
    private static let boltWidth: CGFloat = 7
    private static let boltHeight: CGFloat = 13
    /// The span the thermometer's mercury maps onto. Below 30 C a Mac
    /// is essentially cold and above 95 it is throttling, so anchoring
    /// the scale there uses the whole glyph for the range that
    /// actually varies.
    private static let thermometerRange: ClosedRange<Double> = 30...95
    private static let meterHeight: CGFloat = 12
    /// Space between the glyph and the first segment, and between
    /// segments. Wider than the gap inside a segment so the readouts
    /// group visually instead of running together.
    private static let segmentGap: CGFloat = 9
    private static let innerGap: CGFloat = 4
    private static let ruleWidth: CGFloat = 1
    /// Space between a rule and the nearest readout.
    private static let rulePadding: CGFloat = 7
    private static let alertMarkWidth: CGFloat = 6

    /// Build the status item image.
    ///
    /// Two shapes, not one. With no segments switched on this is the
    /// gauge glyph alone, exactly as before the strip existed. With
    /// segments on, the glyph is dropped and the readouts sit between
    /// two hairline rules instead: the glyph was costing ~24 pt to
    /// repeat an identity the readouts already imply, and the rules
    /// make the group read as one object rather than as loose numbers
    /// drifting among the other menu bar items.
    static func make(readout: MenuBarReadout,
                     segments: [MenuBarSegment],
                     alerts: [AlertRule]) -> NSImage {
        let parts = segments.compactMap { segment in
            part(for: segment, readout: readout).map { (segment, $0) }
        }
        let marks = MenuBarAlertMarks(firing: alerts, drawn: parts.map(\.0))
        guard !parts.isEmpty else { return glyphOnly(alerting: marks.showsDot) }

        let alertWidth = marks.showsDot ? alertMarkWidth + innerGap : 0
        let width = rulePadding * 2 + alertWidth
            + parts.reduce(0) { $0 + $1.1.width } + segmentGap * CGFloat(parts.count - 1)

        let image = NSImage(size: NSSize(width: width, height: glyphSize),
                            flipped: false) { _ in
            // Any red forfeits template recoloring, so match the bar by hand.
            let isDarkMenuBar = NSAppearance.currentDrawing()
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: NSColor = marks.isEmpty || !isDarkMenuBar ? .black : .white
            let red = alertRed(isDarkMenuBar: isDarkMenuBar)

            drawRule(at: 0, color: color)
            drawRule(at: width - ruleWidth, color: color)

            var x = rulePadding
            if marks.showsDot {
                drawAlertMark(at: x)
                x += alertMarkWidth + innerGap
            }
            for (index, (segment, part)) in parts.enumerated() {
                if index > 0 { x += segmentGap }
                if marks.redSegments.contains(segment) {
                    drawGlowing(part, at: x, color: red)
                } else {
                    part.draw(x, color)
                }
                x += part.width
            }
            return true
        }

        image.isTemplate = marks.isEmpty
        image.accessibilityDescription = accessibilityDescription(
            readout: readout, segments: segments, alerting: !marks.isEmpty
        )
        return image
    }

    /// The strip switched off: just the gauge, as it always was.
    private static func glyphOnly(alerting: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: glyphSize, height: glyphSize),
                            flipped: false) { _ in
            if alerting {
                let isDarkMenuBar = NSAppearance.currentDrawing()
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                MenuBarIcon.drawGlyph(size: glyphSize, color: isDarkMenuBar ? .white : .black)
                MenuBarIcon.drawAlertBadge(size: glyphSize)
            } else {
                MenuBarIcon.drawGlyph(size: glyphSize, color: .black)
            }
            return true
        }
        image.isTemplate = !alerting
        image.accessibilityDescription = alerting
            ? "Mac Usage: attention needed" : "Mac Usage"
        return image
    }

    /// One red per bar appearance, as in Theme: none clears 4.5:1 on both.
    private static func alertRed(isDarkMenuBar: Bool) -> NSColor {
        isDarkMenuBar
            ? NSColor(srgbRed: 1.00, green: 0.42, blue: 0.38, alpha: 1)  // #FF6B61
            : NSColor(srgbRed: 0.75, green: 0.16, blue: 0.11, alpha: 1)  // #C0281B
    }

    private static func drawGlowing(_ part: Part, at x: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        glow.set()
        part.draw(x, color)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A hairline bracket. Faint on purpose: it should group the
    /// readouts, not compete with them.
    private static func drawRule(at x: CGFloat, color: NSColor) {
        let inset: CGFloat = 5
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: NSRect(x: x, y: inset,
                                  width: ruleWidth,
                                  height: glyphSize - inset * 2)).fill()
    }

    /// Small red dot: the badge's job, without the glyph to sit on.
    private static func drawAlertMark(at x: CGFloat) {
        let diameter = alertMarkWidth
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (glyphSize - diameter) / 2,
                                    width: diameter, height: diameter)).fill()
    }

    // MARK: Segment layout

    /// A measured piece of the strip: how wide it is, and how to draw
    /// it once its left edge is known. Width has to be known before the
    /// image exists, so measuring and drawing are separate passes.
    private struct Part {
        let width: CGFloat
        let draw: (CGFloat, NSColor) -> Void
    }

    /// Returns nil for a segment with nothing to show, so it takes no
    /// width at all. A lone placeholder glyph sitting in the menu bar
    /// is worse than the reading simply not being there.
    private static func part(for segment: MenuBarSegment,
                             readout: MenuBarReadout) -> Part? {
        switch segment {
        case .cpu:
            let text = "\(Int(readout.cpuBusyPercent.rounded()))%"
            let textWidth = width(of: text)
            return Part(width: sparklineWidth + innerGap + textWidth) { x, color in
                drawSparkline(readout.cpuHistory, at: x, color: color)
                draw(text, at: x + sparklineWidth + innerGap, color: color)
            }

        case .gpu:
            // Absent GPU, absent segment. A "0%" here would be a claim
            // the reader never made.
            guard let utilization = readout.gpuUtilizationPercent else { return nil }
            let text = "\(Int(utilization.rounded()))%"
            let textWidth = width(of: text)
            return Part(width: ringDiameter + innerGap + textWidth) { x, color in
                drawBusyRing(utilization, at: x, color: color)
                draw(text, at: x + ringDiameter + innerGap, color: color)
            }

        case .memory:
            let text = "\(Int(readout.memoryPressurePercent.rounded()))%"
            let textWidth = width(of: text)
            return Part(width: meterWidth + innerGap + textWidth) { x, color in
                drawMeter(readout.memoryPressurePercent, at: x, color: color)
                draw(text, at: x + meterWidth + innerGap, color: color)
            }

        case .power:
            guard let watts = readout.systemWatts else { return nil }
            // Whole watts only. A tenth of a watt is inside the rail's
            // own tick-to-tick noise, and the extra character would
            // shuffle the width of everything to its right.
            let text = "\(Int(watts.rounded()))W"
            let textWidth = width(of: text)
            return Part(width: boltWidth + innerGap + textWidth) { x, color in
                drawBolt(at: x, color: color)
                draw(text, at: x + boltWidth + innerGap, color: color)
            }

        case .network:
            let text = "↓\(rate(readout.downloadBytesPerSecond))"
                + "  ↑\(rate(readout.uploadBytesPerSecond))"
            return Part(width: width(of: text)) { x, color in
                draw(text, at: x, color: color)
            }

        case .temperature:
            guard let celsius = readout.cpuTemperatureCelsius else { return nil }
            let text = "\(Int(celsius.rounded()))°"
            let textWidth = width(of: text)
            return Part(width: thermometerWidth + innerGap + textWidth) { x, color in
                drawThermometer(celsius, at: x, color: color)
                draw(text, at: x + thermometerWidth + innerGap, color: color)
            }
        }
    }

    // MARK: Drawing

    private static func font() -> NSFont {
        // Monospaced digits stop the strip from shifting width every
        // time a number changes, which would make the whole menu bar
        // jitter once a second.
        NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font()]).width
    }

    private static func draw(_ text: String, at x: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: x, y: (glyphSize - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// Bars for the recent CPU history, oldest at the left. Drawn at a
    /// fixed 0-100 scale so the height means the same thing every time
    /// rather than rescaling to whatever the recent peak happened
    /// to be.
    private static func drawSparkline(_ history: [Double],
                                      at x: CGFloat,
                                      color: NSColor) {
        let barWidth: CGFloat = 2
        let barGap: CGFloat = 1
        let capacity = Int((sparklineWidth + barGap) / (barWidth + barGap))
        guard capacity > 0 else { return }

        let samples = Array(history.suffix(capacity))
        let bottom = (glyphSize - sparklineHeight) / 2

        // Right-aligned: newest sample sits at the right edge, so the
        // bars stay still as history fills in rather than sliding.
        let usedWidth = CGFloat(samples.count) * (barWidth + barGap) - barGap
        var barX = x + sparklineWidth - max(0, usedWidth)

        color.withAlphaComponent(0.9).setFill()
        for sample in samples {
            let fraction = min(max(sample, 0), 100) / 100
            let height = max(1, sparklineHeight * fraction)
            NSBezierPath(rect: NSRect(x: barX, y: bottom,
                                      width: barWidth, height: height)).fill()
            barX += barWidth + barGap
        }
    }

    /// A memory chip that fills from the bottom.
    ///
    /// This was a rounded tank, which at this size is the exact shape
    /// of the macOS battery indicator sitting a few points away in the
    /// same menu bar. Stacked graduation bars fixed that but read as a
    /// hamburger menu once mostly full. A chip outline with pins down
    /// each side is unambiguous at every level: the silhouette says
    /// "memory" on its own, and the fill stays continuous so the value
    /// is exact rather than quantised.
    private static func drawMeter(_ percent: Double,
                                  at x: CGFloat,
                                  color: NSColor) {
        let bodyWidth = meterWidth - pinLength * 2
        let bottom = (glyphSize - meterHeight) / 2
        let body = NSRect(x: x + pinLength, y: bottom,
                          width: bodyWidth, height: meterHeight)

        let outline = NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = 1
        color.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        // Pins, three a side. They are what stop this reading as a
        // plain rounded rectangle, which is to say as a battery.
        color.withAlphaComponent(0.55).setFill()
        for index in 0..<3 {
            let y = body.minY + 2.5 + CGFloat(index) * 3.5
            NSBezierPath(rect: NSRect(x: body.minX - pinLength, y: y,
                                      width: pinLength, height: 1)).fill()
            NSBezierPath(rect: NSRect(x: body.maxX, y: y,
                                      width: pinLength, height: 1)).fill()
        }

        let well = body.insetBy(dx: 2, dy: 2)
        let fraction = min(max(percent, 0), 100) / 100
        guard fraction > 0 else { return }
        color.setFill()
        NSBezierPath(rect: NSRect(x: well.minX, y: well.minY,
                                  width: well.width,
                                  height: well.height * fraction)).fill()
    }

    /// A ring that fills clockwise from twelve o'clock.
    ///
    /// GPU and CPU are the same kind of number, so the strip cannot
    /// tell them apart by their text: with no labels, identity has to
    /// come from silhouette. CPU already owns the sparkline and memory
    /// the chip, and a ring is the one remaining shape that is still
    /// unmistakable at 12 pt. It is also what the GPU card's hover
    /// detail draws, so the same metric looks the same in both places.
    private static func drawBusyRing(_ percent: Double,
                                     at x: CGFloat,
                                     color: NSColor) {
        let lineWidth: CGFloat = 2
        let radius = (ringDiameter - lineWidth) / 2
        let center = NSPoint(x: x + ringDiameter / 2, y: glyphSize / 2)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        color.withAlphaComponent(0.3).setStroke()
        track.stroke()

        let fraction = min(max(percent, 0), 100) / 100
        guard fraction > 0 else { return }
        let progress = NSBezierPath()
        progress.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - 360 * fraction,
                           clockwise: true)
        progress.lineWidth = lineWidth
        // A round cap means a barely-busy GPU still leaves a visible
        // dot rather than nothing, which would be indistinguishable
        // from the segment being switched off.
        progress.lineCapStyle = .round
        color.setStroke()
        progress.stroke()
    }

    /// A lightning bolt.
    ///
    /// Watts have no natural full scale, so unlike the meter and the
    /// thermometer this glyph carries no value: it is pure identity,
    /// there to say which number the digits beside it are. Filling it
    /// would need a ceiling, and the panel card had to invent a moving
    /// one; a moving ceiling cannot be explained in 7 pt of menu bar.
    private static func drawBolt(at x: CGFloat, color: NSColor) {
        let bottom = (glyphSize - boltHeight) / 2
        // Outline in a 0-1 box, y up, scaled into the glyph.
        let points: [(CGFloat, CGFloat)] = [
            (0.62, 1.00), (0.00, 0.46), (0.38, 0.46),
            (0.34, 0.00), (1.00, 0.54), (0.62, 0.54),
        ]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let location = NSPoint(x: x + point.0 * boltWidth,
                                   y: bottom + point.1 * boltHeight)
            if index == 0 { path.move(to: location) } else { path.line(to: location) }
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// A thermometer whose mercury rises with the reading.
    ///
    /// CPU has its sparkline and memory its chip, so temperature was
    /// the one readout arriving as a bare number. Network needs no
    /// glyph: its arrows already say which direction is which.
    private static func drawThermometer(_ celsius: Double,
                                        at x: CGFloat,
                                        color: NSColor) {
        let bulbRadius: CGFloat = 2.6
        let stemWidth: CGFloat = 2.6
        let bottom = (glyphSize - meterHeight) / 2
        let centerX = x + thermometerWidth / 2
        let bulbCenter = NSPoint(x: centerX, y: bottom + bulbRadius)
        let stemTop = bottom + meterHeight
        let stemBottom = bulbCenter.y

        // Outline: stem capsule plus bulb, drawn faint so the mercury
        // inside it is what carries the reading.
        color.withAlphaComponent(0.4).setStroke()
        let stem = NSBezierPath(roundedRect: NSRect(
            x: centerX - stemWidth / 2, y: stemBottom,
            width: stemWidth, height: stemTop - stemBottom
        ), xRadius: stemWidth / 2, yRadius: stemWidth / 2)
        stem.lineWidth = 1
        stem.stroke()

        let bulb = NSBezierPath(ovalIn: NSRect(
            x: bulbCenter.x - bulbRadius, y: bulbCenter.y - bulbRadius,
            width: bulbRadius * 2, height: bulbRadius * 2
        ))
        bulb.lineWidth = 1
        bulb.stroke()

        // The bulb is always full: a thermometer with an empty bulb
        // reads as broken rather than as cold.
        color.setFill()
        bulb.fill()

        let span = thermometerRange.upperBound - thermometerRange.lowerBound
        let fraction = min(max((celsius - thermometerRange.lowerBound) / span, 0), 1)
        guard fraction > 0 else { return }
        let mercuryWidth = stemWidth - 1.6
        let mercuryHeight = (stemTop - stemBottom) * fraction
        NSBezierPath(roundedRect: NSRect(
            x: centerX - mercuryWidth / 2, y: stemBottom,
            width: mercuryWidth, height: mercuryHeight
        ), xRadius: mercuryWidth / 2, yRadius: mercuryWidth / 2).fill()
    }

    // MARK: Formatting

    /// Compact throughput for a space where every point counts:
    /// "1.2M", "88K", "0B". ByteCountFormatter's "1.2 MB/s" is three
    /// times as wide for the same information.
    private static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1_000 { return "\(Int(value))B" }
        if value < 1_000_000 { return String(format: "%.0fK", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        return String(format: "%.1fG", value / 1_000_000_000)
    }

    private static func accessibilityDescription(readout: MenuBarReadout,
                                                 segments: [MenuBarSegment],
                                                 alerting: Bool) -> String {
        var parts = ["Mac Usage"]
        if alerting { parts.append("attention needed") }
        for segment in segments {
            switch segment {
            case .cpu:
                parts.append("CPU \(Int(readout.cpuBusyPercent.rounded())) percent")
            case .gpu:
                if let utilization = readout.gpuUtilizationPercent {
                    parts.append("GPU \(Int(utilization.rounded())) percent")
                }
            case .power:
                if let watts = readout.systemWatts {
                    parts.append("\(Int(watts.rounded())) watts")
                }
            case .memory:
                parts.append("memory pressure \(Int(readout.memoryPressurePercent.rounded())) percent")
            case .network:
                parts.append("down \(rate(readout.downloadBytesPerSecond)) per second, "
                             + "up \(rate(readout.uploadBytesPerSecond)) per second")
            case .temperature:
                if let celsius = readout.cpuTemperatureCelsius {
                    parts.append("CPU \(Int(celsius.rounded())) degrees")
                }
            }
        }
        return parts.joined(separator: ", ")
    }
}
