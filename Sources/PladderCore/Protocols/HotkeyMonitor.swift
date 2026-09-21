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
    /// The press was interrupted: another key went down within
    /// `HotkeyChordTracker.interruptionWindow` of the chord engaging, so the
    /// user was typing a shortcut (Cmd+C, Cmd+Tab) rather than dictating. The
    /// recording is dropped without transcribing. Only the event tap can
    /// produce this; Carbon never sees the interrupting key.
    case cancelled
}

/// The push-to-talk chord: one or more physical keys that must be held together.
///
/// Keys are macOS virtual key codes (Carbon `kVK_*`). Modifier keys are ordinary
/// members of the chord under their own key codes, so Right Option (0x3D) and
/// Left Option (0x3A) are different keys, and a chord can be a lone modifier,
/// several modifiers, or modifiers plus a regular key. Matching is exact on the
/// sides for a modifier-only chord, which is what lets a lone Right Command be
/// a hotkey; a chord with a regular key ignores which side a modifier is on
/// (see `HotkeyChordTracker`).
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

    /// True when the chord can be registered as a system-wide hotkey without
    /// Accessibility (Carbon `RegisterEventHotKey`): exactly one regular key,
    /// any modifiers, no Fn. Sides are collapsed by that API, so Left and
    /// Right Shift are the same chord to it.
    public var canBeRegisteredWithoutAccessibility: Bool {
        regularKeyCodes.count == 1 && !keyCodes.contains(0x3F)
    }

    /// A chord with no keys never fires. Used to turn the submit key off.
    public var isEmpty: Bool { keyCodes.isEmpty }

    /// The form a chord is stored in. A chord with a regular key ignores the
    /// modifiers' sides, so it keeps the left-hand codes; a modifier-only
    /// chord is matched by side and is kept as pressed.
    public var canonical: Hotkey {
        isModifierOnly ? self : Hotkey(keyCodes: regularKeyCodes.union(collapsedModifierKeyCodes))
    }

    // MARK: Carbon's side-agnostic view of a chord

    /// The modifiers with each right-hand key folded onto its left-hand code,
    /// which is all Carbon's modifier mask can express. Fn has no side and no
    /// bit, so it is left alone and simply never matches anything Carbon owns.
    public var collapsedModifierKeyCodes: Set<UInt16> {
        Self.collapsingSides(modifierKeyCodes)
    }

    /// The same folding for a loose set of key codes, which is how the tracker
    /// compares held modifiers against a chord with a regular key.
    public static func collapsingSides(_ codes: Set<UInt16>) -> Set<UInt16> {
        Set(codes.map { code in
            switch code {
            case 0x36: 0x37 // Right Command -> Command
            case 0x3C: 0x38 // Right Shift -> Shift
            case 0x3D: 0x3A // Right Option -> Option
            case 0x3E: 0x3B // Right Control -> Control
            default: code
            }
        })
    }

    /// Carbon's modifier mask for this chord, as `RegisterEventHotKey` and the
    /// symbolic hot key list both spell it. The four constants are written out
    /// rather than imported so `PladderCore` stays Foundation-only, and so the
    /// conversion is unit-testable without Carbon.
    public var carbonModifierMask: UInt32 {
        var mask: UInt32 = 0
        for code in modifierKeyCodes {
            switch code {
            case 0x37, 0x36: mask |= 0x0100 // cmdKey
            case 0x38, 0x3C: mask |= 0x0200 // shiftKey
            case 0x3A, 0x3D: mask |= 0x0800 // optionKey
            case 0x3B, 0x3E: mask |= 0x1000 // controlKey
            default: break
            }
        }
        return mask
    }

    /// The chord a Carbon key code and modifier mask stand for. A mask cannot
    /// say which side was meant, so the left keys are used, the same reading
    /// the legacy settings decoder takes.
    ///
    /// Nil for `0xFFFF`, which is how the symbolic hot key list spells "this
    /// shortcut has no key". Bits outside the four modifier ones are ignored:
    /// macOS sets a private bit for the function-key shortcuts and nothing
    /// here needs to understand it.
    public init?(keyCode: UInt16, carbonModifierMask mask: UInt32) {
        guard keyCode != 0xFFFF else { return nil }
        var codes: Set<UInt16> = [keyCode]
        if mask & 0x0100 != 0 { codes.insert(0x37) }
        if mask & 0x0200 != 0 { codes.insert(0x38) }
        if mask & 0x0800 != 0 { codes.insert(0x3A) }
        if mask & 0x1000 != 0 { codes.insert(0x3B) }
        self.init(keyCodes: codes)
    }

    // MARK: macOS shortcuts

    /// The enabled macOS keyboard shortcut that swallows this chord, if any.
    ///
    /// Equality is not the rule. On a Mac with two input sources Control+Space
    /// and Control+Option+Space are enabled, and Control+Shift+Space never
    /// reaches the front app either: the same handling eats a chord whose
    /// modifiers *contain* an enabled shortcut's. So a shortcut owns a chord
    /// when it uses the same regular key and its modifiers are a subset of the
    /// chord's, sides collapsed. Conservative in the right direction: it may
    /// warn about a chord that would in fact have worked, never the reverse.
    ///
    /// The owner is returned rather than a Bool so the UI can name it.
    public func systemShortcutConflict(in shortcuts: Set<Hotkey>) -> Hotkey? {
        let keys = regularKeyCodes
        guard !keys.isEmpty else { return nil }
        let modifiers = collapsedModifierKeyCodes
        // Sorted so the name shown does not depend on the set's iteration
        // order when more than one shortcut matches.
        return shortcuts
            .filter { $0.regularKeyCodes == keys && $0.collapsedModifierKeyCodes.isSubset(of: modifiers) }
            .min { $0.keyCodes.sorted().lexicographicallyPrecedes($1.keyCodes.sorted()) }
    }

    // MARK: Well-known chords

    /// Option + Space (kVK_Option, kVK_Space). The default: no macOS shortcut
    /// owns it with one or several input sources, and Carbon registers it, so
    /// it works with and without Accessibility.
    public static let optionSpace = Hotkey(0x3A, 0x31)
    /// Right Command (kVK_RightCommand = 0x36). The default before
    /// Option+Space; still the usual modifier-only choice.
    public static let rightCommand = Hotkey(0x36)
    /// Right Option (kVK_RightOption = 0x3D).
    public static let rightOption = Hotkey(0x3D)
    /// Function key (kVK_Function = 0x3F). Requires the Fn key not be bound
    /// elsewhere in System Settings > Keyboard.
    public static let function = Hotkey(0x3F)

    /// The chord that stands in for this one without Accessibility, or nil
    /// when Carbon can register this one itself. Only a chord without exactly
    /// one regular key, or with Fn, needs it; the default always registers.
    public var standInWithoutAccessibility: Hotkey? {
        canBeRegisteredWithoutAccessibility ? nil : .optionSpace
    }

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
