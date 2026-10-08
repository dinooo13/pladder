import Foundation

extension Duration {
    /// The duration in seconds, for logs and for the `TimeInterval` APIs.
    public var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
