import Foundation

public enum HotkeyRole: String, Sendable, Hashable, CaseIterable, Comparable {
    case dictate, toggle

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct HotkeyMonitorEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case chord(HotkeyRole, HotkeyEvent)
        case escape
    }

    public var kind: Kind
    public var instant: ContinuousClock.Instant?

    public init(_ kind: Kind, instant: ContinuousClock.Instant? = nil) {
        self.kind = kind
        self.instant = instant
    }

    public init(role: HotkeyRole, event: HotkeyEvent, instant: ContinuousClock.Instant? = nil) {
        self.init(.chord(role, event), instant: instant)
    }
}

public protocol HotkeyMonitor: Sendable {
    // A keystroke that ends one chord and engages another reports the end first.
    func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent>
    func stop()
    // Called on the release path, so it must return at once. While on, a plain Escape
    // is reported as `.escape` and kept from other apps; `start` and `stop` turn it off.
    func setCancelKeyEnabled(_ enabled: Bool)
}

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released(submit: Bool)
    // Only the tap reports it; Carbon never sees the other key.
    case interrupted
}
