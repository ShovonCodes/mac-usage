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
/// Battery is deliberately absent: macOS already shows it natively,
/// and a second copy would be pure duplication.
enum MenuBarSegment: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case network
    case temperature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .temperature: return "Temperature"
        }
    }

    var defaultsKey: String {
        switch self {
        case .cpu: return "menuBarShowCpu"
        case .memory: return "menuBarShowMemory"
        case .network: return "menuBarShowNetwork"
        case .temperature: return "menuBarShowTemperature"
        }
    }

    /// Temperature is off by default; the other three are the ones
    /// worth a permanent slice of the menu bar.
    var isOnByDefault: Bool { self != .temperature }
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
                     alerting: Bool) -> NSImage {
        let parts = segments.compactMap { part(for: $0, readout: readout) }
        guard !parts.isEmpty else { return glyphOnly(alerting: alerting) }

        // The alert badge normally lives on the glyph. Without one it
        // becomes a mark inside the leading rule, so an alert is still
        // visible even when the metric that raised it has no segment
        // switched on.
        let alertWidth = alerting ? alertMarkWidth + innerGap : 0
        let width = rulePadding * 2 + alertWidth
            + parts.reduce(0) { $0 + $1.width } + segmentGap * CGFloat(parts.count - 1)

        let image = NSImage(size: NSSize(width: width, height: glyphSize),
                            flipped: false) { _ in
            // A template image is recolored by macOS, so black is
            // right whatever the menu bar looks like. The alert mark
            // needs real red, which forfeits template treatment, and
            // then the drawing has to match the menu bar itself.
            let color: NSColor
            if alerting {
                let isDarkMenuBar = NSAppearance.currentDrawing()
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                color = isDarkMenuBar ? .white : .black
            } else {
                color = .black
            }

            drawRule(at: 0, color: color)
            drawRule(at: width - ruleWidth, color: color)

            var x = rulePadding
            if alerting {
                drawAlertMark(at: x)
                x += alertMarkWidth + innerGap
            }
            for (index, part) in parts.enumerated() {
                if index > 0 { x += segmentGap }
                part.draw(x, color)
                x += part.width
            }
            return true
        }

        image.isTemplate = !alerting
        image.accessibilityDescription = accessibilityDescription(
            readout: readout, segments: segments, alerting: alerting
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

        case .memory:
            let text = "\(Int(readout.memoryPressurePercent.rounded()))%"
            let textWidth = width(of: text)
            return Part(width: meterWidth + innerGap + textWidth) { x, color in
                drawMeter(readout.memoryPressurePercent, at: x, color: color)
                draw(text, at: x + meterWidth + innerGap, color: color)
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
