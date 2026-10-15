import Foundation

// Every string is the same window of the field, the paste plus a margin either side;
// `before` and `after` are the margin as it was when the paste was found.
public struct PasteObservation: Sendable, Equatable {
    public var before: String
    public var pasted: String
    public var after: String
    public var readings: [String]

    public init(before: String = "", pasted: String, after: String = "", readings: [String]) {
        self.before = before
        self.pasted = pasted
        self.after = after
        self.readings = readings
    }
}
