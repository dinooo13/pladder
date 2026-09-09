import Foundation

/// A post-processing step applied to transcribed text before it is inserted.
///
/// Processors are pure with respect to the text: given a string, return a
/// string. They may be async (an on-device language model, for example) but the
/// default ones are synchronous string manipulation.
public protocol TextProcessor: Sendable {
    /// Stable identifier, used for the enable/disable toggles in settings.
    var id: String { get }

    /// Human readable name for settings.
    var displayName: String { get }

    /// One-line description shown under the toggle in settings.
    var detail: String { get }

    func process(_ text: String) async throws -> String
}
