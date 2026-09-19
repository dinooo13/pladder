import Foundation

/// Reports whether something polled has been true continuously for long
/// enough to act on, so a momentary flicker does not flap whatever reacts.
///
/// Used for Secure Event Input, which a password field turns on for as long as
/// it has focus: swapping the hotkey monitor on the first positive poll would
/// mean swapping back a second later. Pure value type with no clock of its
/// own — the caller passes the instant — so the behaviour is unit-testable.
public struct SustainedCondition: Sendable, Equatable {
    /// How long the condition has to hold before `observe` starts returning
    /// true. With a two-second poll this means two consecutive positives.
    public let threshold: Duration
    /// When the current run of true observations started, if any.
    private var trueSince: ContinuousClock.Instant?

    public init(threshold: Duration = .seconds(3)) {
        self.threshold = threshold
    }

    /// Records one observation and returns whether the condition now counts as
    /// sustained. False resets the run, so the answer drops on the first
    /// negative observation: leaving a state that stops the app working should
    /// be immediate, entering it should not.
    public mutating func observe(_ value: Bool, at instant: ContinuousClock.Instant = .now) -> Bool {
        guard value else {
            trueSince = nil
            return false
        }
        guard let start = trueSince else {
            trueSince = instant
            return false
        }
        return instant - start >= threshold
    }
}
