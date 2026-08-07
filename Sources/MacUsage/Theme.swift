import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────
// The panel's color palette.
//
// Why this file exists instead of using SwiftUI's `.blue`, `.red`,
// `.pink` and friends directly:
//
// The stats panel is an NSVisualEffectView with the `.popover`
// material, so it is translucent - whatever wallpaper happens to be
// behind the menu bar shows through and shifts the effective
// background. Apple's system colors are tuned against *opaque*
// window backgrounds, and on a translucent mid-tone surface they
// fall apart. Sampled from the real panel in dark mode:
//
//     card title (accentColor)  #0B5FFF on #525E6D  =  1.18:1
//     "↓ Download" (.blue)      #1484FF on #413F41  =  2.87:1
//     "↑ Upload"   (.pink)      #FB2556 on #413F3F  =  2.74:1
//     hot temp chip (.red)      #FB2E38 on #6D5B67  =  1.66:1
//
// WCAG wants 4.5:1 for normal text and 3:1 for graphical objects, so
// those were 2-4x under. The fix has two halves:
//
//  1. `cardSurface` stops being nearly transparent. A near-invisible
//     gray 12% tint let the wallpaper's luminance drive every ratio
//     in the panel; a real (still translucent) scrim pins the surface
//     into a narrow band, which is what makes everything else
//     predictable. Every number below is computed against the
//     measured *worst* case in that band.
//
//  2. Each hue gets an explicit light/dark pair, lightened for dark
//     mode and darkened for light mode until it clears 3:1 as a mark.
//     A single color cannot serve both appearances here.
//
// Rule of thumb when adding UI: hues are for *marks* - rings, bars,
// legend dots, chips. Small text stays `.primary`/`.secondary`, which
// AppKit already guarantees is legible on any material. No saturated
// hue reaches 4.5:1 on this surface while still reading as that hue,
// so colored 10pt labels are a losing game.
// ─────────────────────────────────────────────────────────────────

enum Theme {

    // MARK: Data hues
    //
    // Ratios are against the worst case of the measured surface band
    // (dark #4C4D4E over a bright wallpaper, light #EAEAEC over a dark
    // one). Target for a mark is 3:1; all of these clear 4.3:1.

    /// CPU user time, memory "App", network download, charging battery.
    static let blue = adaptive(dark: 0x7FC4FF, light: 0x0057C7) // 4.54 / 5.48

    /// CPU system time, memory "Wired", network upload, battery health.
    /// Deliberately rosier than `red` so the health ring no longer
    /// reads as an alarm at 94%.
    static let pink = adaptive(dark: 0xFF9FB4, light: 0xB81E4A) // 4.39 / 5.26

    /// Critical: alerts, memory pressure, low battery, hot sensors.
    static let red = adaptive(dark: 0xFFA093, light: 0xC0281B) // 4.32 / 4.91

    /// Warning tier, one step below `red`.
    static let orange = adaptive(dark: 0xFFB65C, light: 0x95580A) // 4.88 / 4.75

    /// Memory "Compressed", and the middle of the heat scale.
    static let yellow = adaptive(dark: 0xEFD156, light: 0x7E6100) // 5.62 / 4.86

    /// Healthy / relaxed.
    static let green = adaptive(dark: 0x6FE08C, light: 0x1B7530) // 5.13 / 4.81

    /// Coldest step of the heat scale.
    static let teal = adaptive(dark: 0x6FDAE8, light: 0x00707E) // 5.19 / 4.83

    // MARK: Surfaces

    /// The rounded background behind every stat card.
    ///
    /// Black/white rather than gray: a gray scrim keeps the wallpaper's
    /// hue and luminance, which is exactly what was washing the panel
    /// out. Darkening in dark mode and lightening in light mode instead
    /// pushes the surface *away* from the mid-tones the material
    /// otherwise lands on, and it is still translucent enough to keep
    /// the vibrancy the panel is built around.
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor.black.withAlphaComponent(0.22)
            : NSColor.white.withAlphaComponent(0.50)
    })

    /// The uppercase "CPU" / "MEMORY" card headings.
    ///
    /// These used to be `Color.accentColor`, which measured 1.18:1 -
    /// effectively invisible. Headings are chrome, not data, so they
    /// give up their color: this is a touch stronger than `.secondary`
    /// so the small semibold caps still hold up over a bright
    /// wallpaper, and it leaves the rings and charts as the only
    /// colored things in the panel.
    static let sectionTitle = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.70)
            : NSColor.black.withAlphaComponent(0.66)
    })

    /// Tint strength for a hue used as a *background* (temperature
    /// chips, the alert banner). Light enough that `.primary` text on
    /// top still clears 5:1.
    static let tintAlpha: Double = 0.22

    // MARK: Plumbing

    /// SwiftUI's `Color` has no dynamic-appearance initializer, so the
    /// light/dark pair is resolved by AppKit and wrapped.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDark(appearance) ? nsColor(dark) : nsColor(light)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: 1)
    }
}
