import Carbon.HIToolbox
import Foundation
import PladderCore

public extension Hotkey {
    @MainActor
    var displayName: String { KeyNames.name(for: self, collapsingSides: !isModifierOnly) }

    // For anything Carbon matches: its mask cannot tell Left from Right.
    @MainActor
    var sideAgnosticDisplayName: String { KeyNames.name(for: self, collapsingSides: true) }
}

public enum KeyNames {
    @MainActor
    public static func name(for hotkey: Hotkey, collapsingSides: Bool = false) -> String {
        guard !hotkey.keyCodes.isEmpty else { return localized("None") }
        return hotkey.keyCodes
            .sorted { (rank($0), $0) < (rank($1), $1) }
            .map { name(forKeyCode: $0, collapsingSides: collapsingSides) }
            .joined(separator: " + ")
    }

    @MainActor
    public static func name(forKeyCode code: UInt16, collapsingSides: Bool = false) -> String {
        if collapsingSides, let sideless = sidelessNames[code] { return localized(sideless) }
        if let fixed = fixedNames[code] { return localized(fixed) }
        // What the key types in the current layout is already in the user's language.
        if let character = KeyboardLayout.displayCharacter(for: code) { return character }
        return String(localized: "Key \(Int(code))", table: "KeyNames")
    }

    // The English name is the catalog key. Outside `Pladder.app` there is no catalog and
    // the key comes back as it is, so `swift run` and the tests need no bundle.
    private static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "KeyNames")
    }

    // Modifiers in the order macOS prints them, then Fn, then the rest by key code.
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

    private static let sidelessNames: [UInt16: String] = {
        let entries: [(Int, String)] = [
            (kVK_Command, "Command"), (kVK_RightCommand, "Command"),
            (kVK_Shift, "Shift"), (kVK_RightShift, "Shift"),
            (kVK_Option, "Option"), (kVK_RightOption, "Option"),
            (kVK_Control, "Control"), (kVK_RightControl, "Control"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (UInt16($0.0), $0.1) })
    }()

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
}
