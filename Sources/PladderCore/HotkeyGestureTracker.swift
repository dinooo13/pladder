import Foundation

// Hold, toggle, hybrid and keyboard bounce: docs/ARCHITECTURE.md, "Hotkeys".
public struct HotkeyGestureTracker: Sendable {
    public enum Mode: Sendable, Equatable {
        case hold, toggle, hybrid
    }

    public enum Action: Sendable, Equatable {
        case start(HotkeyRole)
        case stop(submit: Bool)
        case discard
    }

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
        case held(HotkeyRole, since: ContinuousClock.Instant, submit: Bool)
        case latched(HotkeyRole)
        case settling(HotkeyRole, since: ContinuousClock.Instant, submit: Bool, token: UInt64)
    }

    public let modes: [HotkeyRole: Mode]
    public let holdThreshold: Duration
    public let bounceWindow: Duration
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

    public var isLatched: Bool {
        if case .latched = phase { return true }
        return false
    }

    public mutating func pressed(_ role: HotkeyRole, at instant: ContinuousClock.Instant) -> Outcome {
        if let last = lastRelease, last.role == role, instant - last.at <= bounceWindow {
            deferReleases = true
            if case .settling(let held, let since, let submit, _) = phase, held == role {
                // The release was the keyboard bouncing: resume the hold. The pending settle is stale.
                phase = .held(role, since: since, submit: submit)
            }
            return Outcome()
        }
        switch phase {
        case .idle:
            phase = .held(role, since: instant, submit: false)
            return Outcome(action: .start(role))
        case .latched:
            // Any chord ends a latched recording; its release then arrives in idle and is ignored.
            phase = .idle
            return Outcome(action: .stop(submit: false))
        case .held, .settling:
            // Only nested chords get here, and `HotkeyChordSet` reports the first chord's end
            // before the second's press, so that end has already acted. What is left is a
            // hand-over past the window while releases are deferred, whose stop is on its way.
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
        // The chord tracker clears its send-key latch on every release, so a hold resumed
        // after a bounce would otherwise forget it.
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

    // Only the held chord can be interrupted; with nested chords the other one's
    // interruption is the hand-over.
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

    // Keeps the last release, so a bounce right after a stop is still recognised, and
    // `deferReleases`: the keyboard has not changed.
    public mutating func reset() {
        phase = .idle
    }
}
