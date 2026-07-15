import AppKit

// ─────────────────────────────────────────────────────────────────
// The custom glyph shown in the menu bar — a small speedometer that
// mirrors the app icon: faint full track, bright value arc, needle.
//
// It is drawn in code (no image assets), which keeps the plain
// `swift build` binary self-contained — nothing extra to copy into
// the app bundle.
//
// Menu bar icons are "template images": macOS only looks at the
// alpha channel and recolors the shape itself — black in a light
// menu bar, white in a dark one. That's why everything below is
// drawn in black; the faint track comes from lower alpha.
// ─────────────────────────────────────────────────────────────────

enum MenuBarIcon {

    /// Build the template image for the status item. All geometry is
    /// proportional to `pointSize`; drawing happens at the screen's
    /// actual scale, so it is crisp on Retina displays.
    static func make(pointSize: CGFloat = 24) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false) { _ in
            drawGlyph(size: pointSize)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mac Usage"
        return image
    }

    private static func drawGlyph(size: CGFloat) {
        // Proportions were designed at 18×18; scale everything.
        let scale = size / 18
        let center = NSPoint(x: size / 2, y: size / 2)
        let arcRadius: CGFloat = 6.5 * scale
        let arcStrokeWidth: CGFloat = 1.6 * scale

        // Speedometer sweep: bottom-left, over the top, to bottom-right
        // (270° total, with the gap at the bottom).
        // AppKit angles: 0° points right, positive is counterclockwise.
        let sweepStartAngle: CGFloat = 225
        let sweepTotalDegrees: CGFloat = 270
        let sweepEndAngle = sweepStartAngle - sweepTotalDegrees // -45° = bottom-right

        // How "full" the gauge reads — same as the app icon.
        let gaugeFraction: CGFloat = 0.68
        let valueEndAngle = sweepStartAngle - sweepTotalDegrees * gaugeFraction

        // 1. Faint full track.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: arcRadius,
                        startAngle: sweepStartAngle, endAngle: sweepEndAngle,
                        clockwise: true)
        track.lineWidth = arcStrokeWidth
        track.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()

        // 2. Bright value arc on top of the track.
        let valueArc = NSBezierPath()
        valueArc.appendArc(withCenter: center, radius: arcRadius,
                           startAngle: sweepStartAngle, endAngle: valueEndAngle,
                           clockwise: true)
        valueArc.lineWidth = arcStrokeWidth
        valueArc.lineCapStyle = .round
        NSColor.black.setStroke()
        valueArc.stroke()

        // 3. Needle pointing at the value arc's end.
        let needleAngleRadians = valueEndAngle * .pi / 180
        let needleLength: CGFloat = 5.2 * scale
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: NSPoint(
            x: center.x + needleLength * cos(needleAngleRadians),
            y: center.y + needleLength * sin(needleAngleRadians)
        ))
        needle.lineWidth = 1.5 * scale
        needle.lineCapStyle = .round
        NSColor.black.setStroke()
        needle.stroke()

        // 4. Hub dot over the needle's base.
        let hubRadius: CGFloat = 1.7 * scale
        let hub = NSBezierPath(ovalIn: NSRect(
            x: center.x - hubRadius, y: center.y - hubRadius,
            width: hubRadius * 2, height: hubRadius * 2
        ))
        NSColor.black.setFill()
        hub.fill()
    }
}
