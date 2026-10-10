import Foundation

/// Watches the field a dictation was just pasted into, to see what the user
/// does to it. Implemented over Accessibility in `PladderSystem`; tests use a
/// scripted fake.
///
/// The contract `CorrectionLearner` relies on:
///
/// - One watch at a time. A new `observe` ends the watch in progress early,
///   and that earlier call then returns what it saw up to that point, not
///   nil, before the new watch starts. So a second dictation never costs the
///   first its correction, and the learner can start a task per paste
///   without coordinating them.
/// - Cancelling the calling task does not end the watch. It runs until one
///   of its own ends (the user leaves the field, the field goes away, the
///   observation window passes) or a newer `observe` ends it, and only then
///   returns, at most the observation window later. There is no early exit
///   for the caller; the learner's tasks are never cancelled and need none.
public protocol PastedTextObserver: Sendable {
    /// Called strictly after the paste, never on the release-to-paste path.
    /// Returns once the watch has ended, or nil when the pasted text could
    /// not be found at the caret: no grant, not a text field, a secure field,
    /// or a field that reformatted the paste.
    func observe(pasted: String) async -> PasteObservation?
}
