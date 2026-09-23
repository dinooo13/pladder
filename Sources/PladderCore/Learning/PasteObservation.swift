import Foundation

/// What was seen of the field a dictation was pasted into, from the moment
/// the paste was found until the watch ended.
///
/// Every string is the same window of the field: the pasted text plus a
/// margin on either side, never the whole field. `before` and `after` are
/// that margin as it was when the paste was found; they let the diff anchor a
/// one-word paste on the text around it and tell the user's corrections of
/// the dictation apart from edits to their own text next to it.
public struct PasteObservation: Sendable, Equatable {
    /// The window's text before the paste, when the paste was found.
    public var before: String
    /// The text as it was found in the field: the transcript, with or without
    /// the trailing space the output added.
    public var pasted: String
    /// The window's text after the paste, when the paste was found.
    public var after: String
    /// The window after each change, oldest first; the last one is the field
    /// when the watch ended.
    public var readings: [String]

    public init(before: String = "", pasted: String, after: String = "", readings: [String]) {
        self.before = before
        self.pasted = pasted
        self.after = after
        self.readings = readings
    }
}
