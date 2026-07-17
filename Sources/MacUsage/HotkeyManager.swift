import AppKit
import Carbon.HIToolbox

// ─────────────────────────────────────────────────────────────────
// The global ⌃⌥M hotkey that opens/closes the panel from anywhere.
//
// Uses Carbon's RegisterEventHotKey — old, but it is the only
// system-wide hotkey API that works without the Accessibility
// permission (an NSEvent global monitor would require it). The
// hotkey is registered only while the Settings switch is on.
// ─────────────────────────────────────────────────────────────────

final class HotkeyManager {

    /// Called when the hotkey fires. Carbon delivers the event on the
    /// main run loop, so this runs on the main thread.
    var onHotkeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKeyRef == nil else { return } // already registered

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The handler is a C function pointer, so it can't capture
        // anything — `self` rides along in the userData pointer.
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotkeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .onHotkeyPressed?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_5347) /* 'MUSG' */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
