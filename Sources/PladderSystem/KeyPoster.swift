import CoreGraphics
import Foundation
import PladderCore

/// Types one key, with modifiers, into whatever app has focus. The seam
/// between `PasteboardOutput` and the window server: the app posts real
/// events, the tests record them, so no test can ever type into the app the
/// developer is dictating into.
protocol KeyPoster: Sendable {
    /// One key down and up. `flags` carries the modifiers; an empty set types
    /// the bare key. Synchronous and fast: Cmd+V is posted with this on the
    /// release-to-paste path.
    func post(_ key: CGKeyCode, flags: CGEventFlags) throws
}

/// Posts to the HID event tap, i.e. the same place a real keyboard injects
/// its events, so every app sees them. Needs Accessibility.
struct HIDKeyPoster: KeyPoster {
    func post(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw OutputError.eventCreationFailed }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
