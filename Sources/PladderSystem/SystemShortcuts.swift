import Carbon.HIToolbox
import Foundation
import PladderCore
import os

/// The keyboard shortcuts macOS itself handles, read from Carbon.
///
/// The window server dispatches an enabled symbolic hot key before the front
/// app — and before a Carbon registration — ever sees the keys, so a chord that
/// collides with one is dead on arrival. `RegisterEventHotKey` does not say so:
/// it returns `noErr` for Command+Space and Control+Space alike, because
/// `eventHotKeyExistsErr` only reports another app's Carbon registration. This
/// list is the check that works.
///
/// Which shortcuts are enabled is per Mac: install a second keyboard layout and
/// Control+Space becomes the input-source switch, which is why the stand-in
/// chord is chosen against this and not hard-coded.
public enum SystemShortcuts {
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")

    /// Every enabled shortcut as a chord, with each modifier read as its
    /// left-hand key since the mask cannot say which side was meant.
    ///
    /// `CopySymbolicHotKeys` is documented as not thread safe and linear in the
    /// number of shortcuts (a few hundred here), so this is `@MainActor` and
    /// called on explicit triggers — launch, a permission flip, a hotkey edit,
    /// the settings window opening — never on a key press.
    @MainActor
    public static func enabled() -> Set<Hotkey> {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let entries = array?.takeRetainedValue() as? [[String: Any]] else {
            log.error("Could not read the macOS keyboard shortcuts (\(status, privacy: .public))")
            return []
        }

        // The keys are `#define`d CFStrings in CarbonEvents.h rather than
        // imported constants, so they are spelled out.
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
