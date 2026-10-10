import Foundation
import PladderCore
import PladderRefine
import PladderSystem

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
    var polishWarning: String? {
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

extension PolishModel {
    /// The picker's wording. S1-mini's licence asks for its name exactly
    /// so: "S1-mini" by "Superwhisper".
    var displayName: String {
        switch self {
        case .appleIntelligence: String(localized: "Apple Intelligence")
        case .s1Mini: String(localized: "S1-mini by Superwhisper (1.5 GB)")
        case .s1Mini8Bit: String(localized: "S1-mini by Superwhisper, 8-bit (805 MB)")
        }
    }
}

extension ModelFileFailure {
    /// Each says what dictations do meanwhile, like the Apple sentences.
    var text: String {
        switch self {
        case .download:
            String(localized: "The download stopped, so dictations paste as dictated.")
        case .checksum:
            String(localized: "The download did not match the published model and was deleted, so dictations paste as dictated.")
        case .disk:
            String(localized: "The model could not be saved, probably for lack of disk space, so dictations paste as dictated.")
        }
    }
}

/// The menu's first line and its last-transcript entry.
enum MenuStatus {
    /// The chords the line can name, already worded for the monitor that
    /// matches them.
    struct Chords {
        /// What to hold to dictate: the stored chord or its stand-in.
        var hold: String
        /// What ends a latched recording.
        var stop: String
        /// The stand-in is listening because Accessibility is missing.
        var accessibilityOff: Bool
        /// Carbon is standing in for a deaf tap.
        var secureKeyboardEntry: Bool
    }

    static func line(state: DictationState, engineStatus: EngineStatus, isLatched: Bool, chords: Chords) -> String {
        switch state {
        case .recording:
            // The Menu style has no pill, so this line is its latched cue.
            guard isLatched else { return String(localized: "Recording…") }
            return String(localized: "Recording — press \(chords.stop) to stop")
        case .transcribing: return String(localized: "Transcribing…")
        case .polishing: return String(localized: "Polishing…")
        case .inserting: return String(localized: "Inserting…")
        case .error(let failure): return String(localized: "Error: \(failure.text)")
        case .copied: return String(localized: "Copied — press ⌘V")
        case .idle:
            return readyLine(chords)
        case .unavailable:
            switch engineStatus {
            case .downloading(let progress):
                if let progress {
                    return String(localized: "Model: downloading \(Int((progress * 100).rounded()))%")
                }
                return String(localized: "Model: downloading…")
            case .loading: return String(localized: "Model: loading…")
            case .unloaded: return String(localized: "Model: not loaded")
            case .failed(let failure): return String(localized: "Model failed: \(failure.text)")
            case .ready: return readyLine(chords)
            }
        }
    }

    /// What to say when nothing is happening. Say why the send key and the
    /// swallowing stopped when they did: both are the tap's. A whole
    /// sentence either way: a suffix glued on cannot be translated.
    private static func readyLine(_ chords: Chords) -> String {
        if chords.accessibilityOff {
            return String(localized: "Ready — hold \(chords.hold) (Accessibility is off)")
        }
        if chords.secureKeyboardEntry {
            return String(localized: "Ready — hold \(chords.hold) (Secure Keyboard Entry is on)")
        }
        return String(localized: "Ready — hold \(chords.hold)")
    }

    /// A short, word-boundary-aware summary of the most recent transcript;
    /// longer previews make the menu bar menu comically wide.
    static func summary(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let limit = 32
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > 20 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }
}

/// The Processing tab's wording for the standard processors, by id. Core
/// holds no strings, so a processor is a stable id there and its name and
/// one-line description are here, beside the catalog.
enum ProcessorText {
    static func name(_ id: String) -> String {
        switch id {
        case FillerRemover.processorID: String(localized: "Remove fillers")
        case DictionaryReplacer.processorID: String(localized: "Dictionary")
        case CustomWordCorrector.processorID: String(localized: "Custom words")
        case WhitespaceNormalizer.processorID: String(localized: "Tidy whitespace")
        case SpokenPunctuation.processorID: String(localized: "Spoken punctuation")
        default: id
        }
    }

    static func detail(_ id: String) -> String {
        switch id {
        case FillerRemover.processorID:
            String(localized: "Strips hesitation sounds like “uh” and “um” from English, German and Spanish transcripts.")
        case DictionaryReplacer.processorID:
            String(localized: "Applies your replacement rules. Edit them in the Dictionary tab.")
        case CustomWordCorrector.processorID:
            String(localized: "Repairs near misses of the words you list in the Dictionary tab with an empty Heard as.")
        case WhitespaceNormalizer.processorID:
            String(localized: "Trims the transcript and collapses runs of spaces.")
        case SpokenPunctuation.processorID:
            String(localized: "Turns spoken marks such as “comma”, “question mark” and “new paragraph” into the marks themselves, in English, German and Spanish.")
        default: ""
        }
    }
}

extension HotkeyWarning {
    /// The sentence under the recorder field.
    @MainActor var text: String {
        switch self {
        case .standIn(let stored, let standIn):
            String(localized: "Without Accessibility, \(stored.displayName) cannot be detected, so \(standIn.sideAgnosticDisplayName) stands in for it until Accessibility is granted. Record a combination with a regular key to choose your own.")
        case .systemShortcut(let owner, let chord):
            String(localized: "\(owner.sideAgnosticDisplayName) is a macOS keyboard shortcut, so \(chord.displayName) may never reach Pladder. Record another combination.")
        case .noModifier(let hotkey):
            String(localized: "Without a modifier, \(hotkey.displayName) can no longer be typed in other apps while Pladder is running.")
        case .toggleNeedsAccessibility(let toggle):
            String(localized: "Without Accessibility, \(toggle.displayName) cannot be detected, so the toggle key is off until Accessibility is granted.")
        case .sendKeyNeedsAccessibility:
            String(localized: "The send key needs Accessibility.")
        case .sendKeyInsideChord(let key):
            String(localized: "\(key.displayName) is part of the push-to-talk key, so it can never be pressed separately.")
        }
    }
}
