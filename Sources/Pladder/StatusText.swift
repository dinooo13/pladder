import Foundation
import PladderCore
import PladderRefine

/// The wording for every state `PladderCore` and `PladderEngines` report as a
/// value.
///
/// Core imports Foundation only and must not produce user-facing text, so it
/// emits enum cases and this is the single place that turns them into
/// sentences — which also means the sentences are here, in the app, where the
/// String Catalog is. None of it runs between `recordingStopped` and
/// `inserted`: these are read by the menu and the overlay, and on failure.
extension UnavailableReason {
    var text: String {
        switch self {
        case .starting: String(localized: "Starting")
        case .loadingModel: String(localized: "Loading model")
        case .engineFailed(let failure): failure.text
        }
    }
}

extension EngineFailure {
    var text: String {
        switch self {
        case .download(let reason):
            // Retry calls `load()` again, which resumes the `.partial` rather
            // than starting the ~460 MB over; saying so is the point.
            String(localized: "Download failed: \(reason.text) (Retry resumes it)")
        case .incompleteFiles:
            String(localized: "Model files incomplete (Retry re-downloads them)")
        case .loadFailed(let detail):
            String(localized: "Model could not be loaded: \(detail)")
        }
    }
}

extension DownloadFailure {
    var text: String {
        switch self {
        case .serverError: String(localized: "Hugging Face returned an error")
        case .rateLimited: String(localized: "Hugging Face rate limit")
        case .stalled: String(localized: "the transfer stalled")
        case .damagedFile: String(localized: "a file arrived damaged")
        case .noConnection: String(localized: "no connection")
        case .timedOut: String(localized: "timed out")
        case .tls: String(localized: "TLS error")
        case .cancelled: String(localized: "cancelled")
        case .network: String(localized: "network error")
        // The downloader's own wording, which nothing here can translate.
        case .other(let detail): detail
        }
    }
}

extension DictationFailure {
    var text: String {
        switch self {
        // AVFoundation's description, already in the system language.
        case .microphone(let detail): String(localized: "Microphone: \(detail)")
        case .engineNotLoaded: String(localized: "Speech model is not loaded yet.")
        case .pasteKeystroke:
            String(localized: "Could not create the paste keystroke. Try again, or restart Pladder.")
        case .other(let detail): detail
        }
    }
}

extension OnDeviceModelAvailability {
    /// The sentence under the "Polish dictations" toggle, nil when the model
    /// can run. Each says what dictations do meanwhile: they paste as
    /// dictated, only without the polish.
    var polishKeyText: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence is off, so dictations paste as dictated. Turn it on in System Settings.")
        case .deviceNotEligible:
            String(localized: "This Mac cannot run Apple Intelligence, so dictations paste as dictated.")
        case .modelNotReady:
            String(localized: "The Apple Intelligence model is still downloading, so dictations paste as dictated for now.")
        case .unavailable:
            String(localized: "Apple Intelligence is unavailable, so dictations paste as dictated.")
        }
    }
}
