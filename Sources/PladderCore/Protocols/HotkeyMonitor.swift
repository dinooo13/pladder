import Foundation

/// Watches for the push-to-talk chord system wide and reports press and release.
public protocol HotkeyMonitor: Sendable {
    /// Starts monitoring and returns a stream of events. `submitKey` is the
    /// chord that, pressed while the hotkey is held, asks for Return after the
    /// paste; an empty chord turns that off. Cancelling the consuming task or
    /// calling `stop()` ends monitoring.
    func start(hotkey: Hotkey, submitKey: Hotkey) -> AsyncStream<HotkeyEvent>
    func stop()
}

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    /// `submit` is true when the submit key was pressed at some point while the
    /// chord was held, in which case the text is followed by Return.
    case released(submit: Bool)
}

/// The push-to-talk chord: one or more physical keys that must be held together.
///
/// Keys are macOS virtual key codes (Carbon `kVK_*`). Modifier keys are ordinary
/// members of the chord under their own key codes, so Right Option (0x3D) and
/// Left Option (0x3A) are different keys, and a chord can be a lone modifier,
/// several modifiers, or modifiers plus a regular key. Matching is exact on the
/// modifiers (see `HotkeyChordTracker`), which is what keeps Shift+Right Option
/// from being mistaken for Right Option.
public struct Hotkey: Codable, Sendable, Hashable {
    public var keyCodes: Set<UInt16>

    public init(keyCodes: Set<UInt16>) {
        self.keyCodes = keyCodes
    }

    public init(_ keyCodes: UInt16...) {
        self.keyCodes = Set(keyCodes)
    }

    // MARK: Modifier keys

    /// Left and Right Command, Shift, Option, Control, plus Fn. Caps Lock is a
    /// latch rather than a key you hold, so it is deliberately not here.
    public static let allModifierKeyCodes: Set<UInt16> = [
        0x37, 0x36, // Command, Right Command
        0x38, 0x3C, // Shift, Right Shift
        0x3A, 0x3D, // Option, Right Option
        0x3B, 0x3E, // Control, Right Control
        0x3F,       // Fn / Globe
    ]

    public static func isModifierKeyCode(_ code: UInt16) -> Bool {
        allModifierKeyCodes.contains(code)
    }

    public var modifierKeyCodes: Set<UInt16> { keyCodes.filter(Self.isModifierKeyCode) }
    public var regularKeyCodes: Set<UInt16> { keyCodes.filter { !Self.isModifierKeyCode($0) } }
    public var isModifierOnly: Bool { !keyCodes.isEmpty && regularKeyCodes.isEmpty }
    /// A chord with no keys never fires. Used to turn the submit key off.
    public var isEmpty: Bool { keyCodes.isEmpty }

    // MARK: Well-known chords

    /// Right Command (kVK_RightCommand = 0x36). The default: rarely part of a
    /// shortcut, and it types nothing on its own.
    public static let rightCommand = Hotkey(0x36)
    /// Right Option (kVK_RightOption = 0x3D).
    public static let rightOption = Hotkey(0x3D)
    /// Function key (kVK_Function = 0x3F). Requires the Fn key not be bound
    /// elsewhere in System Settings > Keyboard.
    public static let function = Hotkey(0x3F)

    // MARK: Codable

    // Version 1 stored `{"kind": "modifier"|"key", "keyCode": n, "modifiers": mask}`
    // with the side-agnostic `NSEvent.ModifierFlags` mask. Those files are still
    // read; everything is written in the chord form.
    private enum CodingKeys: String, CodingKey {
        case keyCodes
        case kind, keyCode, modifiers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let codes = try c.decodeIfPresent([UInt16].self, forKey: .keyCodes) {
            keyCodes = Set(codes)
            return
        }
        var codes: Set<UInt16> = [try c.decode(UInt16.self, forKey: .keyCode)]
        if try c.decodeIfPresent(String.self, forKey: .kind) != "modifier" {
            // A mask cannot say which side was meant; the left keys are the
            // conventional reading of "Control+Space".
            let mask = try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0
            if mask & (1 << 17) != 0 { codes.insert(0x38) } // shift
            if mask & (1 << 18) != 0 { codes.insert(0x3B) } // control
            if mask & (1 << 19) != 0 { codes.insert(0x3A) } // option
            if mask & (1 << 20) != 0 { codes.insert(0x37) } // command
            if mask & (1 << 23) != 0 { codes.insert(0x3F) } // fn
        }
        keyCodes = codes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Sorted so the settings file is stable across saves.
        try c.encode(keyCodes.sorted(), forKey: .keyCodes)
    }
}
