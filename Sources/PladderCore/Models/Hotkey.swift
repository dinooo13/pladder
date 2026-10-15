import Foundation

// macOS virtual key codes (`kVK_*`). Modifiers are members under their own codes,
// so Left and Right Option are different keys.
public struct Hotkey: Codable, Sendable, Hashable {
    public var keyCodes: Set<UInt16>

    public init(keyCodes: Set<UInt16>) {
        self.keyCodes = keyCodes
    }

    public init(_ keyCodes: UInt16...) {
        self.keyCodes = Set(keyCodes)
    }

    // MARK: Modifier keys

    // Caps Lock is a latch, not a key you hold, so it is deliberately not here.
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

    public var canBeRegisteredWithoutAccessibility: Bool {
        regularKeyCodes.count == 1 && !keyCodes.contains(0x3F)
    }

    public var isEmpty: Bool { keyCodes.isEmpty }

    // The form a chord is stored and compared in.
    public var canonical: Hotkey {
        isModifierOnly ? self : Hotkey(keyCodes: regularKeyCodes.union(collapsedModifierKeyCodes))
    }

    // MARK: Carbon's side-agnostic view of a chord

    // Fn has no side and no Carbon bit: it is left alone and never matches.
    public var collapsedModifierKeyCodes: Set<UInt16> {
        Self.collapsingSides(modifierKeyCodes)
    }

    public static func collapsingSides(_ codes: Set<UInt16>) -> Set<UInt16> {
        Set(codes.map { code in carbonModifiers.first { $0.right == code }?.left ?? code })
    }

    private static let carbonModifiers: [(left: UInt16, right: UInt16, bit: UInt32)] = [
        (0x37, 0x36, 0x0100), // Command, cmdKey
        (0x38, 0x3C, 0x0200), // Shift, shiftKey
        (0x3A, 0x3D, 0x0800), // Option, optionKey
        (0x3B, 0x3E, 0x1000), // Control, controlKey
    ]

    // Carbon's constants are written out so `PladderCore` stays Foundation-only.
    public var carbonModifierMask: UInt32 {
        let collapsed = collapsedModifierKeyCodes
        return Self.carbonModifiers.reduce(0) { mask, modifier in
            collapsed.contains(modifier.left) ? mask | modifier.bit : mask
        }
    }

    // 0xFFFF is the symbolic hot key list's "no key". Bits outside the four modifiers
    // are ignored: macOS sets a private one for the function-key shortcuts.
    public init?(keyCode: UInt16, carbonModifierMask mask: UInt32) {
        guard keyCode != 0xFFFF else { return nil }
        var codes: Set<UInt16> = [keyCode]
        for modifier in Self.carbonModifiers where mask & modifier.bit != 0 { codes.insert(modifier.left) }
        self.init(keyCodes: codes)
    }

    // MARK: macOS shortcuts

    // Equality is not the rule: with two input sources Control+Space is enabled and
    // Control+Shift+Space never reaches the app either. A shortcut owns a chord when it
    // has the same regular key and a subset of its modifiers, sides collapsed.
    public func systemShortcutConflict(in shortcuts: Set<Hotkey>) -> Hotkey? {
        let keys = regularKeyCodes
        guard !keys.isEmpty else { return nil }
        let modifiers = collapsedModifierKeyCodes
        return shortcuts
            .filter { $0.regularKeyCodes == keys && $0.collapsedModifierKeyCodes.isSubset(of: modifiers) }
            .min { $0.keyCodes.sorted().lexicographicallyPrecedes($1.keyCodes.sorted()) }
    }

    // MARK: Well-known chords

    public static let optionSpace = Hotkey(0x3A, 0x31)
    public static let rightCommand = Hotkey(0x36)
    public static let rightOption = Hotkey(0x3D)
    public static let keyV = Hotkey(0x09)

    public var standInWithoutAccessibility: Hotkey? {
        canBeRegisteredWithoutAccessibility ? nil : .optionSpace
    }

    // MARK: Codable

    // Version 1 stored `{"kind": "modifier"|"key", "keyCode": n, "modifiers": mask}`
    // with the side-agnostic `NSEvent.ModifierFlags` mask. Still read, never written.
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
            // A mask cannot say which side was meant; the left keys are the usual reading.
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
        try c.encode(keyCodes.sorted(), forKey: .keyCodes)
    }
}
