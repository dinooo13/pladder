import Carbon.HIToolbox
import Foundation
import PladderCore
import os

// The window server dispatches an enabled symbolic hot key before any app or Carbon
// registration sees it, and `RegisterEventHotKey` returns `noErr` for Command+Space
// anyway. Per Mac: a second input source makes Control+Space the source switch.
public enum SystemShortcuts {
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")

    // `CopySymbolicHotKeys` is not thread-safe and linear in the shortcuts (a few
    // hundred), so: main actor, on explicit triggers, never on a key press.
    @MainActor
    public static func enabled() -> Set<Hotkey> {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let entries = array?.takeRetainedValue() as? [[String: Any]] else {
            log.error("Could not read the macOS keyboard shortcuts (\(status, privacy: .public))")
            return []
        }

        // `#define`d CFStrings in CarbonEvents.h, not imported constants.
        var shortcuts: Set<Hotkey> = []
        for entry in entries {
            guard entry["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  let code = entry["kHISymbolicHotKeyCode"] as? Int,
                  let mask = entry["kHISymbolicHotKeyModifiers"] as? Int,
                  let key = UInt16(exactly: code),
                  // 0xFFFF is "no key assigned"; `Hotkey` refuses it.
                  let chord = Hotkey(keyCode: key, carbonModifierMask: UInt32(truncatingIfNeeded: mask))
            else { continue }
            shortcuts.insert(chord)
        }
        log.debug("\(shortcuts.count, privacy: .public) macOS keyboard shortcuts are enabled")
        return shortcuts
    }
}
