import Foundation

public protocol TextProcessor: Sendable {
    // Stored in the settings' list of disabled processors: never change one.
    var id: String { get }

    func process(_ text: String) -> String
}
