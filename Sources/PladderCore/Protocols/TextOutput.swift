import Foundation

/// What became of the text the output was handed.
public enum InsertResult: Sendable, Equatable {
    /// The text landed in the front application.
    case pasted
    /// The text was left on the clipboard for the user to paste themselves,
    /// because pasting was not possible (no Accessibility). No Return is sent
    /// in this case, whatever `submit` said.
    case copied
}

/// What an output can fail at for a reason the app knows how to phrase. No
/// `LocalizedError`: the wording lives in the app, next to the catalog.
public enum OutputError: Error, Equatable, Sendable {
    /// `CGEvent` refused to create the key event, which normally means the
    /// event source could not be created.
    case eventCreationFailed
}

/// Delivers final text into whatever application currently has focus.
public protocol TextOutput: Sendable {
    /// Inserts `text` at the cursor. With `submit`, Return is pressed once the
    /// text has landed, so a chat message is sent or a command runs without a
    /// second trip to the keyboard. The Return happens after this returns; it
    /// is not on the release-to-paste path.
    ///
    /// The result says whether the text was pasted or only copied, so the
    /// caller can tell the user to press ⌘V.
    @discardableResult
    func insert(_ text: String, submit: Bool) async throws -> InsertResult

    /// Lets the output do slow preparation, such as snapshotting the
    /// clipboard, while the user is still speaking. Called at key-down; not
    /// on the release-to-paste path.
    func prepare() async
}

extension TextOutput {
    public func prepare() async {}
}
