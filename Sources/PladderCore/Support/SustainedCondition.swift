import Foundation

// For Secure Event Input, which a password field turns on while it has focus:
// swapping monitors on the first positive poll would swap back a second later.
public struct SustainedCondition: Sendable, Equatable {
    // With the default and a two-second poll: three positives in a row, about 4 s in.
    public let threshold: Duration
    private var trueSince: ContinuousClock.Instant?

    public init(threshold: Duration = .seconds(3)) {
        self.threshold = threshold
    }

    // Drops on the first negative: leaving a state that stops the app working should
    // be immediate, entering it should not.
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
