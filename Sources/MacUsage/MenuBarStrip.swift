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
    var memoryUsedPercent: Double = 0
    var uploadBytesPerSecond: Double = 0
    var downloadBytesPerSecond: Double = 0
    var cpuTemperatureCelsius: Double?
}

enum MenuBarStrip {

    private static let glyphSize: CGFloat = 24
    private static let textSize: CGFloat = 11
    private static let sparklineWidth: CGFloat = 26
    private static let sparklineHeight: CGFloat = 12
    private static let meterWidth: CGFloat = 9
    private static let meterHeight: CGFloat = 12
    /// Space between the glyph and the first segment, and between
    /// segments. Wider than the gap inside a segment so the readouts
    /// group visually instead of running together.
    private static let segmentGap: CGFloat = 9
    private static let innerGap: CGFloat = 4

    /// Build the whole status item image: glyph, then each visible
    /// segment. With no segments this is byte-for-byte the old
    /// glyph-only image.
    static func make(readout: MenuBarReadout,
                     segments: [MenuBarSegment],
                     alerting: Bool) -> NSImage {
        let parts = segments.compactMap { part(for: $0, readout: readout) }
        let width = glyphSize + parts.reduce(0) { $0 + segmentGap + $1.width }

        let image = NSImage(size: NSSize(width: width, height: glyphSize),
                            flipped: false) { _ in
            // A template image is recolored by macOS, so black is
            // right whatever the menu bar looks like. The alert badge
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

            MenuBarIcon.drawGlyph(size: glyphSize, color: color)
            if alerting {
                MenuBarIcon.drawAlertBadge(size: glyphSize)
            }

            var x = glyphSize
            for part in parts {
                x += segmentGap
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
            let text = "\(Int(readout.memoryUsedPercent.rounded()))%"
            let textWidth = width(of: text)
            return Part(width: meterWidth + innerGap + textWidth) { x, color in
                drawMeter(readout.memoryUsedPercent, at: x, color: color)
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
            return Part(width: width(of: text)) { x, color in
                draw(text, at: x, color: color)
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

    /// A small vertical tank that fills from the bottom. Echoes the
    /// panel's ring gauges: a faint full track with a solid value on
    /// top, so the reading is legible even at a glance.
    private static func drawMeter(_ percent: Double,
                                  at x: CGFloat,
                                  color: NSColor) {
        let bottom = (glyphSize - meterHeight) / 2
        let track = NSRect(x: x, y: bottom, width: meterWidth, height: meterHeight)
        let radius: CGFloat = 2

        color.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(percent, 0), 100) / 100
        guard fraction > 0 else { return }
        let fillHeight = max(1, meterHeight * fraction)
        let fill = NSRect(x: x, y: bottom, width: meterWidth, height: fillHeight)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
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
                parts.append("memory \(Int(readout.memoryUsedPercent.rounded())) percent")
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
