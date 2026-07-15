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

    /// Build the template image for the status item. Most menu bar
    /// icons are 18 pt; 20 pt reads a touch larger while still fitting
    /// the 24 pt menu bar. Drawing happens at the screen's actual
    /// scale, so it is crisp on Retina displays.
    static func make(size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            drawGlyph(size: size)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mac Usage"
        return image
    }

    private static func drawGlyph(size: CGFloat) {
        // All geometry is proportional to `size` (fractions of the
        // original 18 pt design), so the glyph scales as one piece.
        let center = NSPoint(x: size / 2, y: size / 2)
        let arcRadius: CGFloat = size * 0.36
        let arcStrokeWidth: CGFloat = size * 0.09

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
        let needleLength: CGFloat = size * 0.29
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: NSPoint(
            x: center.x + needleLength * cos(needleAngleRadians),
            y: center.y + needleLength * sin(needleAngleRadians)
        ))
        needle.lineWidth = size * 0.083
        needle.lineCapStyle = .round
        NSColor.black.setStroke()
        needle.stroke()

        // 4. Hub dot over the needle's base.
        let hubRadius: CGFloat = size * 0.094
        let hub = NSBezierPath(ovalIn: NSRect(
            x: center.x - hubRadius, y: center.y - hubRadius,
            width: hubRadius * 2, height: hubRadius * 2
        ))
        NSColor.black.setFill()
        hub.fill()
    }
}
