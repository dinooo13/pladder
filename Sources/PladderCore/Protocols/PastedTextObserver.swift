import Foundation

/// Watches the field a dictation was just pasted into, to see what the user
/// does to it. Implemented over Accessibility in `PladderSystem`; tests use a
/// scripted fake.
public protocol PastedTextObserver: Sendable {
    /// Called strictly after the paste, never on the release-to-paste path.
    /// Returns once the watch has ended, or nil when the pasted text could
    /// not be found at the caret: no grant, not a text field, a secure field,
    /// or a field that reformatted the paste.
    func observe(pasted: String) async -> PasteObservation?
}
