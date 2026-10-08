import Foundation

/// What the settings window warns about under each recorder field, as a
/// value: the decisions are here, where they can be tested, and the app
/// words them.
public enum HotkeyWarning: Equatable, Sendable {
    /// Without Accessibility the stored chord cannot be detected, and the
    /// default stands in for it.
    case standIn(stored: Hotkey, standIn: Hotkey)
    /// An enabled macOS shortcut is dispatched by the window server before
    /// either monitor sees the keys, so the chord may never arrive.
    case systemShortcut(owner: Hotkey, chord: Hotkey)
    /// A chord without a modifier is swallowed system wide, so a plain letter
    /// or Space becomes untypeable while Pladder runs.
    case noModifier(Hotkey)
    /// Without Accessibility a toggle chord Carbon cannot register listens
    /// for nothing, and it has no stand-in of its own.
    case toggleNeedsAccessibility(Hotkey)
    /// The send key presses Return through the same synthetic event as the
    /// paste, so it is off entirely without Accessibility.
    case sendKeyNeedsAccessibility
    /// A send key the chord already contains can never be pressed on its own.
    case sendKeyInsideChord(Hotkey)

    /// In order: the stand-in — unless macOS owns that too, which matters
    /// more, since it is the chord actually listened for; macOS owning the
    /// stored chord; a chord without a modifier.
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

    /// Nothing for an empty toggle key, or one equal to the key: that one is
    /// hybrid, and whatever stands in for the key stands in for it too.
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
