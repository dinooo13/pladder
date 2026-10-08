import Foundation

/// Which chord fired. The coordinator starts a recording for either and
/// decides at release what the dictation goes through. `toggle` is only a
/// chord of its own when it differs from the dictate chord; equal, it makes
/// the dictate chord hybrid instead (see `HotkeyGestureTracker`).
public enum HotkeyRole: String, Sendable, Hashable, CaseIterable, Comparable {
    case dictate, toggle

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What a monitor reports: a chord's transition, tagged with the chord it
/// belongs to, or the cancel key, which belongs to none.
public struct HotkeyMonitorEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One chord tracker's transition.
        case chord(HotkeyRole, HotkeyEvent)
        /// The cancel key went down while enabled (`setCancelKeyEnabled`):
        /// drop the recording, whichever chord started it.
        case escape
    }

    public var kind: Kind
    /// When the key moved, stamped by the monitor as the keystroke arrives.
    /// The coordinator times holds from this rather than from when it gets
    /// round to the event: a press waits for the microphone to start, and a
    /// release queued behind it must not look longer than it was. Nil from a
    /// source that does not stamp, a test fake say; the reader uses now.
    public var instant: ContinuousClock.Instant?

    public init(_ kind: Kind, instant: ContinuousClock.Instant? = nil) {
        self.kind = kind
        self.instant = instant
    }

    /// A chord's transition: `.chord(role, event)`.
    public init(role: HotkeyRole, event: HotkeyEvent, instant: ContinuousClock.Instant? = nil) {
        self.init(.chord(role, event), instant: instant)
    }
}

/// Watches for the push-to-talk chords system wide and reports press and release.
public protocol HotkeyMonitor: Sendable {
    /// Starts monitoring and returns a stream of events, each tagged with the
    /// role of the chord it belongs to. Each chord is matched on its own; a
    /// chord in the set that is empty is ignored. A keystroke that ends one
    /// chord and engages another reports the end first (see
    /// `HotkeyChordSet`). `submitKey` is the chord that, pressed while any of
    /// them is held, asks for Return after the paste; an empty chord turns
    /// that off. Cancelling the consuming task or calling `stop()` ends
    /// monitoring.
    func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent>
    func stop()
    /// While true a plain Escape is the cancel key: reported as `.escape` and
    /// kept from other apps. The coordinator turns it on when a recording
    /// starts and off when it ends, so Escape is never taken system wide
    /// between recordings. Must return at once: it is called on the release
    /// path. `start` and `stop` turn it off.
    func setCancelKeyEnabled(_ enabled: Bool)
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
