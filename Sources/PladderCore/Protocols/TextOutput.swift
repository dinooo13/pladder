import Foundation

/// Delivers final text into whatever application currently has focus.
public protocol TextOutput: Sendable {
    /// Inserts `text` at the cursor. With `submit`, Return is pressed once the
    /// text has landed, so a chat message is sent or a command runs without a
    /// second trip to the keyboard. The Return happens after this returns; it
    /// is not on the release-to-paste path.
    func insert(_ text: String, submit: Bool) async throws
}
