import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────
// Shows a stat card's detail view in its own floating panel beside
// the main menu bar panel.
//
// Why a second window: the MenuBarExtra window is kept centered
// under the status icon by macOS, so growing it sideways shifts all
// of its content. A separate panel lets the main panel stay exactly
// where it is; the detail appears on whichever side of it has room.
// ─────────────────────────────────────────────────────────────────

@MainActor
final class DetailPanelController {

    private var panel: NSPanel?

    /// Horizontal gap between the main panel and the detail panel.
    private let gapBetweenPanels: CGFloat = 8

    /// Shows `content` in a floating panel beside the window that
    /// contains `anchorView` (the main menu bar panel). Prefers the
    /// left side; falls back to the right when the left lacks room.
    func show<Content: View>(content: Content, besideWindowContaining anchorView: NSView?) {
        hide()
        guard let anchorWindow = anchorView?.window else { return }
        guard let screen = anchorWindow.screen ?? NSScreen.main else { return }

        let hostingView = NSHostingView(rootView: content)
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        // Same frosted-glass look as the main panel.
        let backgroundView = NSVisualEffectView(frame: hostingView.frame)
        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true
        backgroundView.addSubview(hostingView)

        let anchorFrame = anchorWindow.frame
        let visibleFrame = screen.visibleFrame
        let neededWidth = size.width + gapBetweenPanels

        let x: CGFloat
        if anchorFrame.minX - visibleFrame.minX >= neededWidth {
            x = anchorFrame.minX - neededWidth
        } else {
            x = anchorFrame.maxX + gapBetweenPanels
        }
        // Top-align with the main panel, but never above the visible area.
        let y = min(anchorFrame.maxY, visibleFrame.maxY) - size.height

        let newPanel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = anchorWindow.level      // float with the menu panel
        newPanel.collectionBehavior = [.transient, .ignoresCycle]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = backgroundView

        newPanel.alphaValue = 0
        newPanel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Grabs the NSView SwiftUI hosts this background in, so the panel
/// controller can find the menu bar panel's window.
struct HostingViewAccessor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async { self.view = nsView }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
