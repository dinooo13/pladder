import Foundation

public enum HotkeyWarning: Equatable, Sendable {
    case standIn(stored: Hotkey, standIn: Hotkey)
    // The window server dispatches an enabled macOS shortcut before either monitor sees it.
    case systemShortcut(owner: Hotkey, chord: Hotkey)
    case noModifier(Hotkey)
    case toggleNeedsAccessibility(Hotkey)
    case sendKeyNeedsAccessibility
    case sendKeyInsideChord(Hotkey)

    // A stand-in comes first, unless macOS owns that too, which matters more: the
    // stand-in is the chord actually listened for.
    public static func forKey(
        _ hotkey: Hotkey, standIn: Hotkey?, systemShortcuts: Set<Hotkey>
    ) -> HotkeyWarning? {
        if let standIn {
            if let owner = standIn.systemShortcutConflict(in: systemShortcuts) {
                return .systemShortcut(owner: owner, chord: standIn)
            }
            return .standIn(stored: hotkey, standIn: standIn)
        }
        if let owner = hotkey.systemShortcutConflict(in: systemShortcuts) {
            return .systemShortcut(owner: owner, chord: hotkey)
        }
        guard hotkey.modifierKeyCodes.isEmpty, !hotkey.keyCodes.isEmpty else { return nil }
        return .noModifier(hotkey)
    }

    // A toggle equal to the key is hybrid: whatever stands in for the key does for it too.
    public static func forToggle(
        _ toggle: Hotkey, hotkey: Hotkey, accessibilityTrusted: Bool, systemShortcuts: Set<Hotkey>
    ) -> HotkeyWarning? {
        guard !toggle.isEmpty, toggle.canonical != hotkey.canonical else { return nil }
        if !accessibilityTrusted && !toggle.canBeRegisteredWithoutAccessibility {
            return .toggleNeedsAccessibility(toggle)
        }
        if let owner = toggle.systemShortcutConflict(in: systemShortcuts) {
            return .systemShortcut(owner: owner, chord: toggle)
        }
        return nil
    }

    public static func forSendKey(
        _ submitKey: Hotkey, hotkey: Hotkey, accessibilityTrusted: Bool
    ) -> HotkeyWarning? {
        guard !submitKey.keyCodes.isEmpty else { return nil }
        if !accessibilityTrusted { return .sendKeyNeedsAccessibility }
        guard submitKey.keyCodes.isSubset(of: hotkey.keyCodes) else { return nil }
        return .sendKeyInsideChord(submitKey)
    }
}
