import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case unavailable(UnavailableReason)
    // The level is the coordinator's `inputLevel`, not part of the state: it changes
    // twenty times a second, and everything that reads the state would redraw with it.
    case recording
    case transcribing
    case polishing
    case inserting
    case copied
    case error(DictationFailure)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .polishing, .inserting: return true
        default: return false
        }
    }
}

public enum UnavailableReason: Equatable, Sendable {
    case starting
    case loadingModel
    case engineFailed(EngineFailure)
}

public enum DictationFailure: Equatable, Sendable {
    // `detail` is the OS description, already localized.
    case microphone(detail: String)
    case engineNotLoaded
    case pasteKeystroke
    case other(detail: String)

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
