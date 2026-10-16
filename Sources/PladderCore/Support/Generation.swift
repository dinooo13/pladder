import Foundation

// See docs/ARCHITECTURE.md, "Superseded work".
public struct Generation: Sendable, Equatable {
    public private(set) var current = 0

    public init() {}

    @discardableResult
    public mutating func next() -> Int {
        current += 1
        return current
    }

    public func isCurrent(_ id: Int) -> Bool {
        id == current
    }
}
