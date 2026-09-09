import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    /// Engine not ready yet. Hotkey presses are ignored.
    case unavailable(reason: String)
    case recording(level: Float)
    case transcribing
    case inserting
    /// Shown briefly, then returns to idle.
    case error(message: String)

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
