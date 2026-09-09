import Foundation

/// Watches for the push-to-talk key system wide and reports press and release.
public protocol HotkeyMonitor: Sendable {
    /// Starts monitoring and returns a stream of events. Cancelling the consuming
    /// task or calling `stop()` ends monitoring.
    func start(hotkey: Hotkey) -> AsyncStream<HotkeyEvent>
    func stop()
}

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
}

/// Describes the push-to-talk key. Either a single modifier held alone, or a
/// regular key with a modifier mask.
public struct Hotkey: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A lone modifier such as Right Option. Press = modifier down, release = up.
        case modifier
        /// A regular key with optional modifiers.
        case key
    }

    public var kind: Kind
    /// macOS virtual key code (Carbon `kVK_*`).
    public var keyCode: UInt16
    /// Modifier flags bitmask. Uses the raw value of `NSEvent.ModifierFlags` so
    /// SpeakUpCore stays free of AppKit. Only meaningful when `kind == .key`.
    public var modifiers: UInt

    public init(kind: Kind, keyCode: UInt16, modifiers: UInt = 0) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Right Option (kVK_RightOption = 0x3D).
    public static let rightOption = Hotkey(kind: .modifier, keyCode: 0x3D)
    /// Right Command (kVK_RightCommand = 0x36).
    public static let rightCommand = Hotkey(kind: .modifier, keyCode: 0x36)
    /// Right Control (kVK_RightControl = 0x3E).
    public static let rightControl = Hotkey(kind: .modifier, keyCode: 0x3E)
    /// Function key (kVK_Function = 0x3F). Requires the Fn key not be bound
    /// elsewhere in System Settings > Keyboard.
    public static let function = Hotkey(kind: .modifier, keyCode: 0x3F)

    public static let presets: [(name: String, hotkey: Hotkey)] = [
        ("Right Option", .rightOption),
        ("Right Command", .rightCommand),
        ("Right Control", .rightControl),
        ("Fn / Globe", .function),
    ]

    public var displayName: String {
        Self.presets.first { $0.hotkey == self }?.name ?? "Key \(keyCode)"
    }
}
