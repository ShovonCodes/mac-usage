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

        let newPanel = FloatingPanel.make(wrapping: hostingView)
        newPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                          display: false)
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

    /// Resizes the visible panel when its SwiftUI content changes size
    /// (e.g. the temperature grid/list toggle). Keeps the top edge
    /// fixed so the panel stays aligned with the main panel.
    func updateContentSize(_ size: CGSize) {
        guard let panel, panel.isVisible else { return }
        guard abs(panel.frame.height - size.height) > 0.5
                || abs(panel.frame.width - size.width) > 0.5 else { return }

        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}

/// Reports the view's size so the detail panel window can follow
/// content changes (panels don't auto-resize like SwiftUI windows).
struct SizeReporter: ViewModifier {
    let onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size) { onChange($0) }
            }
        )
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

/// The borderless frosted-glass panel style shared by the main stats
/// panel and the hover detail panels.
enum FloatingPanel {
    @MainActor
    static func make(wrapping contentView: NSView) -> NSPanel {
        let frame = contentView.frame

        let backgroundView = NSVisualEffectView(frame: frame)
        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true
        contentView.autoresizingMask = [.width, .height]
        backgroundView.addSubview(contentView)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = backgroundView
        return panel
    }
}
