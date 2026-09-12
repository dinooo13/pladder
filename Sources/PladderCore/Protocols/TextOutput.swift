import Foundation

/// Delivers final text into whatever application currently has focus.
public protocol TextOutput: Sendable {
    func insert(_ text: String) async throws
}
