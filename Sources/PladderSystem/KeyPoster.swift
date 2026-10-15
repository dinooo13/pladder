import CoreGraphics
import Foundation
import PladderCore

// The tests record the keys, so no test can type into the app being dictated into.
protocol KeyPoster: Sendable {
    // Synchronous and fast: Cmd+V goes through this on the release path.
    func post(_ key: CGKeyCode, flags: CGEventFlags) throws
}

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
