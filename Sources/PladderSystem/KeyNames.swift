import Carbon.HIToolbox
import Foundation
import PladderCore

public extension Hotkey {
    /// "Right Option", "Option + Space", "Fn + F5". Sides are named only for a
    /// modifier-only chord, the only kind matched by side. Character keys are
    /// named after what they type in the current keyboard layout.
    var displayName: String { KeyNames.name(for: self, collapsingSides: !isModifierOnly) }

    /// The same name without the sides: "Control + Shift + Space".
    ///
    /// For anything Carbon matches — the stored chord while Accessibility is
    /// missing, a macOS shortcut — where the modifier mask genuinely cannot
    /// tell Left from Right, so naming a side would promise a precision the
    /// matching does not have.
    var sideAgnosticDisplayName: String { KeyNames.name(for: self, collapsingSides: true) }
}

/// Human-readable names for virtual key codes.
public enum KeyNames {
    public static func name(for hotkey: Hotkey, collapsingSides: Bool = false) -> String {
        guard !hotkey.keyCodes.isEmpty else { return localized("None") }
        return hotkey.keyCodes
            .sorted { (rank($0), $0) < (rank($1), $1) }
            .map { name(forKeyCode: $0, collapsingSides: collapsingSides) }
            .joined(separator: " + ")
    }

    public static func name(forKeyCode code: UInt16, collapsingSides: Bool = false) -> String {
        if collapsingSides, let sideless = sidelessNames[code] { return localized(sideless) }
        if let fixed = fixedNames[code] { return localized(fixed) }
        // What the key types in the current layout, which is already the
        // user's own language by definition.
        if let character = layoutCharacter(for: code) { return character }
        return String(localized: "Key \(Int(code))", table: "KeyNames")
    }

    /// The dictionaries below stay English, because the English name is the
    /// catalog key. A key with no German entry — F1 to F20, Eisu, Kana — is
    /// returned as it stands, which is the right answer for all of them.
    ///
    /// Outside `Pladder.app` there is no catalog at all and this returns the
    /// key too, so `swift run` and the tests need no bundle.
    ///
    /// Called by the settings recorder and the menu; never by the
    /// coordinator, so no lookup is on the release-to-paste path.
    private static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "KeyNames")
    }

    /// Modifiers first, in the order macOS prints them (Control, Option,
    /// Shift, Command), then Fn, then everything else by key code.
    private static func rank(_ code: UInt16) -> Int {
        switch Int(code) {
        case kVK_Control, kVK_RightControl: 0
        case kVK_Option, kVK_RightOption: 1
        case kVK_Shift, kVK_RightShift: 2
        case kVK_Command, kVK_RightCommand: 3
        case kVK_Function: 4
        default: 5
        }
    }

    /// Modifier names with the side dropped, for chords matched by Carbon.
    /// `rank` is unchanged, so "Control + Shift + Space" still comes out in
    /// the order macOS prints modifiers.
    private static let sidelessNames: [UInt16: String] = {
        let entries: [(Int, String)] = [
            (kVK_Command, "Command"), (kVK_RightCommand, "Command"),
            (kVK_Shift, "Shift"), (kVK_RightShift, "Shift"),
            (kVK_Option, "Option"), (kVK_RightOption, "Option"),
            (kVK_Control, "Control"), (kVK_RightControl, "Control"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (UInt16($0.0), $0.1) })
    }()

    /// Keys whose name does not depend on the layout.
    private static let fixedNames: [UInt16: String] = {
        let entries: [(Int, String)] = [
            (kVK_Command, "Left Command"), (kVK_RightCommand, "Right Command"),
            (kVK_Shift, "Left Shift"), (kVK_RightShift, "Right Shift"),
            (kVK_Option, "Left Option"), (kVK_RightOption, "Right Option"),
            (kVK_Control, "Left Control"), (kVK_RightControl, "Right Control"),
            (kVK_Function, "Fn / Globe"), (kVK_CapsLock, "Caps Lock"),
            (kVK_Return, "Return"), (kVK_Tab, "Tab"), (kVK_Space, "Space"),
            (kVK_Delete, "Delete"), (kVK_ForwardDelete, "Forward Delete"), (kVK_Escape, "Escape"),
            (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "Page Up"), (kVK_PageDown, "Page Down"),
            (kVK_LeftArrow, "Left Arrow"), (kVK_RightArrow, "Right Arrow"),
            (kVK_UpArrow, "Up Arrow"), (kVK_DownArrow, "Down Arrow"),
            (kVK_Help, "Help"), (kVK_ContextualMenu, "Menu"),
            (kVK_VolumeUp, "Volume Up"), (kVK_VolumeDown, "Volume Down"), (kVK_Mute, "Mute"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
            (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
            (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"),
            (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
            (kVK_ANSI_KeypadDecimal, "Keypad ."), (kVK_ANSI_KeypadMultiply, "Keypad *"),
            (kVK_ANSI_KeypadPlus, "Keypad +"), (kVK_ANSI_KeypadClear, "Keypad Clear"),
            (kVK_ANSI_KeypadDivide, "Keypad /"), (kVK_ANSI_KeypadEnter, "Keypad Enter"),
            (kVK_ANSI_KeypadMinus, "Keypad -"), (kVK_ANSI_KeypadEquals, "Keypad ="),
            (kVK_ANSI_Keypad0, "Keypad 0"), (kVK_ANSI_Keypad1, "Keypad 1"), (kVK_ANSI_Keypad2, "Keypad 2"),
            (kVK_ANSI_Keypad3, "Keypad 3"), (kVK_ANSI_Keypad4, "Keypad 4"), (kVK_ANSI_Keypad5, "Keypad 5"),
            (kVK_ANSI_Keypad6, "Keypad 6"), (kVK_ANSI_Keypad7, "Keypad 7"), (kVK_ANSI_Keypad8, "Keypad 8"),
            (kVK_ANSI_Keypad9, "Keypad 9"),
            (kVK_JIS_Eisu, "Eisu"), (kVK_JIS_Kana, "Kana"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (UInt16($0.0), $0.1) })
    }()

    /// The character `code` produces, unmodified, in the current keyboard
    /// layout, upper-cased for display. Nil for keys that type nothing visible.
    private static func layoutCharacter(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            guard let scalar = text.unicodeScalars.first,
                  !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar)
            else { return nil }
            return text.uppercased()
        }
    }
}
