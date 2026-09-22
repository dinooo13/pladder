import Foundation

/// Turns role-tagged presses and releases into what the recording should do:
/// start it, stop it, or drop it. Pure value type, no I/O and no clock of its
/// own: every event carries its instant, and the one timer it needs is asked
/// for through `Outcome.settle` and answered with `timerFired(token:)`.
///
/// Each role has a mode:
/// - `hold` stops at release: push-to-talk.
/// - `toggle` latches at release, however long the press: the recording
///   carries on until the next press of any chord.
/// - `hybrid` is both on one chord: a release sooner than `holdThreshold`
///   after the press latches, a later one stops. A tap starts a long
///   dictation, a hold is push-to-talk as before.
///
/// A role without a mode is `hold`.
///
/// **Bounce.** Some Bluetooth keyboards report a held key as released and
/// pressed again a few milliseconds apart. A press of a role within
/// `bounceWindow` of that role's last release is such a bounce: it never
/// starts, stops or latches anything. The first one seen turns on
/// `deferReleases`, from then on a release that would stop the recording
/// waits `bounceWindow` first (`settling`), and a bounce inside that wait
/// resumes the hold as if the release never happened. Until a bounce is
/// seen, nothing waits: a healthy keyboard never pays for the protection,
/// and a bouncing one loses one hold early and is then protected. A latch
/// is never deferred, because nothing waits on it.
///
/// No separate press debounce: both monitors already report strictly
/// alternating presses and releases per chord, so the only press that can
/// follow another closely is one that follows a release closely, and that is
/// the bounce rule.
public struct HotkeyGestureTracker: Sendable {
    public enum Mode: Sendable, Equatable {
        case hold, toggle, hybrid
    }

    public enum Action: Sendable, Equatable {
        /// Start a recording for this role.
        case start(HotkeyRole)
        /// Stop the recording and transcribe it.
        case stop(submit: Bool)
        /// The press was interrupted by a shortcut: drop the recording.
        case discard
    }

    /// A request for `timerFired(token:)` after `after`.
    public struct Settle: Sendable, Equatable {
        public var token: UInt64
        public var after: Duration

        public init(token: UInt64, after: Duration) {
            self.token = token
            self.after = after
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var action: Action?
        public var settle: Settle?

        public init(action: Action? = nil, settle: Settle? = nil) {
            self.action = action
            self.settle = settle
        }
    }

    private enum Phase: Sendable, Equatable {
        case idle
        /// The chord is down and the recording running.
        case held(HotkeyRole, since: ContinuousClock.Instant, submit: Bool)
        /// The chord was let go and the recording carries on.
        case latched(HotkeyRole)
        /// The chord was let go and the stop waits out the bounce window.
        case settling(HotkeyRole, since: ContinuousClock.Instant, submit: Bool, token: UInt64)
    }

    public let modes: [HotkeyRole: Mode]
    public let holdThreshold: Duration
    public let bounceWindow: Duration
    /// True once a bounce has been seen; a stopping release then waits
    /// `bounceWindow` before it stops.
    public private(set) var deferReleases: Bool

    private var phase: Phase = .idle
    private var lastRelease: (role: HotkeyRole, at: ContinuousClock.Instant)?
    private var nextToken: UInt64 = 0

    public init(
        modes: [HotkeyRole: Mode],
        holdThreshold: Duration = .milliseconds(400),
        bounceWindow: Duration = .milliseconds(50),
        deferReleases: Bool = false
    ) {
        self.modes = modes
        self.holdThreshold = holdThreshold
        self.bounceWindow = bounceWindow
        self.deferReleases = deferReleases
    }

    /// True while a recording carries on after its chord was let go.
    public var isLatched: Bool {
        if case .latched = phase { return true }
        return false
    }

    public mutating func pressed(_ role: HotkeyRole, at instant: ContinuousClock.Instant) -> Outcome {
        if let last = lastRelease, last.role == role, instant - last.at <= bounceWindow {
            deferReleases = true
            if case .settling(let held, let since, let submit, _) = phase, held == role {
                // The release was the keyboard, not the user: carry on as if
                // the key had stayed down. The pending settle is now stale.
                phase = .held(role, since: since, submit: submit)
            }
            return Outcome()
        }
        switch phase {
        case .idle:
            phase = .held(role, since: instant, submit: false)
            return Outcome(action: .start(role))
        case .latched:
            // Any chord ends a latched recording. Its release arrives in idle
            // and is ignored.
            phase = .idle
            return Outcome(action: .stop(submit: false))
        case .held, .settling:
            // A second chord while one is held: its own tracker has already
            // released or interrupted the first, and that event is what acts.
            return Outcome()
        }
    }

    public mutating func released(
        _ role: HotkeyRole, submit: Bool, at instant: ContinuousClock.Instant
    ) -> Outcome {
        lastRelease = (role, instant)
        guard case .held(let held, let since, let wasSubmit) = phase, held == role else {
            return Outcome()
        }
        // The chord tracker clears its send-key latch on every release, so a
        // hold resumed after a bounce would otherwise forget it.
        let submit = submit || wasSubmit
        let latches: Bool = switch modes[role] ?? .hold {
        case .hold: false
        case .toggle: true
        case .hybrid: instant - since < holdThreshold
        }
        if latches {
            phase = .latched(role)
            return Outcome()
        }
        guard deferReleases else {
            phase = .idle
            return Outcome(action: .stop(submit: submit))
        }
        nextToken &+= 1
        phase = .settling(role, since: since, submit: submit, token: nextToken)
        return Outcome(settle: Settle(token: nextToken, after: bounceWindow))
    }

    /// The press was interrupted by another key. Only the chord that is held
    /// can be; with nested chords the other one's interruption is the hand-over.
    public mutating func interrupted(_ role: HotkeyRole) -> Outcome {
        guard case .held(let held, _, _) = phase, held == role else { return Outcome() }
        phase = .idle
        return Outcome(action: .discard)
    }

    public mutating func timerFired(token: UInt64) -> Outcome {
        guard case .settling(_, _, let submit, let pending) = phase, pending == token else {
            return Outcome()
        }
        phase = .idle
        return Outcome(action: .stop(submit: submit))
    }

    /// Back to idle, for when the recording ended some other way: the cap,
    /// a refused start, a monitor swap. The last release is kept, so a bounce
    /// right after a stop is still recognised, and so is `deferReleases`: the
    /// keyboard has not changed.
    public mutating func reset() {
        phase = .idle
    }
}
