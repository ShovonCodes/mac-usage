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
/// controller can find the menu bar panel's window. Reports the
/// window as soon as the view lands in one — before first draw.
struct HostingViewAccessor: NSViewRepresentable {
    @Binding var view: NSView?
    var onWindowAvailable: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let nsView = WindowObservingView()
        nsView.onWindowAvailable = onWindowAvailable
        DispatchQueue.main.async { self.view = nsView }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowObservingView)?.onWindowAvailable = onWindowAvailable
    }
}

final class WindowObservingView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAvailable?(window)
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Keeps the menu bar panel centered under the status item icon.
//
// MenuBarExtra opens its window edge-aligned to the status item and
// re-places it on every open. Repositioning after the fact flickers,
// so instead this watches the window's move notifications and
// re-centers the moment the system places it — same runloop turn,
// before the misplaced frame reaches the screen.
// ─────────────────────────────────────────────────────────────────

@MainActor
final class PanelCenterer {

    private weak var window: NSWindow?
    private var moveObserver: NSObjectProtocol?

    func attach(to window: NSWindow) {
        if self.window === window {
            center()
            return
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        self.window = window
        center()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.center() }
        }
    }

    private func center() {
        guard let panelWindow = window else { return }
        // The status item lives in its own tiny window at menu bar
        // height — the only other window this app owns up there.
        guard let iconFrame = NSApp.windows.first(where: {
            $0 !== panelWindow && $0.className.contains("StatusBarWindow")
        })?.frame else { return }
        guard let screen = panelWindow.screen ?? NSScreen.main else { return }

        let margin: CGFloat = 8
        var x = iconFrame.midX - panelWindow.frame.width / 2
        x = max(screen.visibleFrame.minX + margin,
                min(x, screen.visibleFrame.maxX - panelWindow.frame.width - margin))

        // Already centered (or this move was our own correction) —
        // returning here is what stops notification recursion.
        guard abs(panelWindow.frame.origin.x - x) > 0.5 else { return }
        panelWindow.setFrameOrigin(NSPoint(x: x, y: panelWindow.frame.origin.y))
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }
}
