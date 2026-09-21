import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    /// Engine not ready yet. Hotkey presses are ignored.
    case unavailable(UnavailableReason)
    case recording(level: Float)
    case transcribing
    case inserting
    /// Transcript is on the clipboard for the user to paste; shown briefly,
    /// then returns to idle. Reached when Pladder cannot paste it itself,
    /// i.e. without Accessibility.
    case copied
    /// Shown briefly, then returns to idle.
    case error(DictationFailure)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .inserting: return true
        default: return false
        }
    }
}

/// Why the hotkey is dead for the moment. A value, not a sentence: Core is
/// Foundation only and never produces user-facing text, so the app is what
/// turns these into the line the menu shows, in the system language.
public enum UnavailableReason: Equatable, Sendable {
    /// The app has just launched; nothing has been decided yet.
    case starting
    /// The engine is downloading, compiling or loading its model.
    case loadingModel
    /// The engine gave up; `EngineFailure` says what went wrong.
    case engineFailed(EngineFailure)
}

/// Why one dictation ended without text. Same reasoning as
/// `UnavailableReason`: values here, wording in the app.
public enum DictationFailure: Equatable, Sendable {
    /// Capture could not start. `detail` is the OS description, which the
    /// system has already localized.
    case microphone(detail: String)
    /// The engine was asked to transcribe before it was ready.
    case engineNotLoaded
    /// The synthetic ⌘V could not be built.
    case pasteKeystroke
    /// Anything else, described by the error itself.
    case other(detail: String)

    /// Classifies the errors Pladder throws itself and keeps the description
    /// of every other one.
    public init(_ error: any Error) {
        if let error = error as? TranscriptionError, error == .notLoaded {
            self = .engineNotLoaded
        } else if let error = error as? OutputError, error == .eventCreationFailed {
            self = .pasteKeystroke
        } else {
            self = .other(detail: error.localizedDescription)
        }
    }
}
