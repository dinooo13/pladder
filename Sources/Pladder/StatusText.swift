import Foundation
import PladderCore
import PladderRefine
import PladderSystem

// Read by the menu, the overlay and settings; none of it runs between
// `recordingStopped` and `inserted`.
extension UnavailableReason {
    var text: String {
        switch self {
        case .starting: String(localized: "Starting…")
        case .loadingModel: String(localized: "Loading the speech model…")
        case .engineFailed(let failure): failure.headline
        }
    }
}

extension EngineFailure {
    // One line for the menu, which does not wrap; `text` is the whole sentence.
    var headline: String {
        switch self {
        case .download: String(localized: "The speech model download stopped.")
        case .incompleteFiles: String(localized: "The speech model’s files are incomplete.")
        case .loadFailed: String(localized: "Couldn’t load the speech model.")
        }
    }

    var text: String {
        switch self {
        case .download(let reason):
            // Downloading again resumes the partial download rather than starting it over.
            reason.text
        case .incompleteFiles:
            String(localized: "The speech model’s files are incomplete.")
        case .loadFailed(let detail):
            String(localized: "Couldn’t load the speech model: \(detail)")
        }
    }
}

// Whole sentences, each with what happens next: the download resumes where it stopped.
extension DownloadFailure {
    var text: String {
        switch self {
        case .serverError, .rateLimited:
            String(localized: "Hugging Face, where the speech model comes from, isn’t answering right now. Try again in a few minutes.")
        case .stalled, .timedOut, .network:
            String(localized: "The speech model download stopped. It picks up where it left off when you try again.")
        case .damagedFile:
            String(localized: "Part of the speech model arrived damaged. Downloading it again replaces that part.")
        case .noConnection:
            String(localized: "No internet connection. The speech model downloads once you’re online.")
        case .tls:
            String(localized: "The connection to Hugging Face isn’t secure, so the download was stopped. Check the network, then try again.")
        case .cancelled:
            String(localized: "The speech model download was cancelled.")
        // The downloader's own wording, which nothing here can translate.
        case .other(let detail): String(localized: "Couldn’t download the speech model: \(detail)")
        }
    }
}

extension DictationFailure {
    var text: String {
        switch self {
        // AVFoundation's description, already in the system language.
        case .microphone(let detail): String(localized: "Couldn’t use the microphone: \(detail)")
        case .engineNotLoaded: String(localized: "The speech model is still loading. Try again in a moment.")
        case .pasteKeystroke:
            String(localized: "Couldn’t paste. Try again, or restart Pladder.")
        case .other(let detail): detail
        }
    }

    // For the pill's two lines: the sentence without the system's own detail, which the
    // menu still shows in full.
    var shortText: String {
        switch self {
        case .microphone: String(localized: "Couldn’t use the microphone.")
        case .engineNotLoaded, .pasteKeystroke: text
        case .other: String(localized: "Something went wrong. Open the Pladder menu for details.")
        }
    }
}

extension OnDeviceModelAvailability {
    // Each sentence says what dictations do meanwhile: they paste as dictated.
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
    // S1-mini's licence asks for the name exactly so: "S1-mini" by "Superwhisper".
    var displayName: String {
        switch self {
        case .appleIntelligence: String(localized: "Apple Intelligence")
        case .s1Mini: String(localized: "S1-mini by Superwhisper")
        case .s1Mini8Bit: String(localized: "S1-mini by Superwhisper, 8-bit")
        }
    }

    var summary: String {
        switch self {
        case .appleIntelligence:
            String(localized: "Built into macOS. Adds one to two seconds to each dictation.")
        case .s1Mini:
            String(localized: "Adds about half a second. A one-time 1.5 GB download from Hugging Face; trained on English, also handles German and Spanish.")
        case .s1Mini8Bit:
            String(localized: "Adds about half a second. A one-time 805 MB download from Hugging Face; trained on English, also handles German and Spanish.")
        }
    }
}

extension ModelFileFailure {
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

enum MenuStatus {
    struct Chords {
        var hold: String
        var stop: String
        var accessibilityOff: Bool
        var secureKeyboardEntry: Bool
    }

    static func line(state: DictationState, engineStatus: EngineStatus, isLatched: Bool, chords: Chords) -> String {
        switch state {
        case .recording:
            // The Menu style has no pill, so this line is its latched cue.
            guard isLatched else { return String(localized: "Listening…") }
            return String(localized: "Listening… Press \(chords.stop) to stop.")
        case .transcribing: return String(localized: "Transcribing…")
        case .polishing: return String(localized: "Polishing…")
        case .inserting: return String(localized: "Pasting…")
        // The menu is where the pill's short version sends the user, so it keeps the detail.
        case .error(let failure): return failure.text
        case .copied: return String(localized: "Copied. Press ⌘V to paste.")
        case .idle:
            return readyLine(chords)
        case .unavailable:
            switch engineStatus {
            case .downloading(let progress):
                if let progress {
                    return String(localized: "Downloading the speech model… \(Int((progress * 100).rounded()))%")
                }
                return String(localized: "Downloading the speech model…")
            case .loading: return String(localized: "Loading the speech model…")
            case .unloaded: return String(localized: "The speech model isn’t loaded.")
            case .failed(let failure): return failure.headline
            case .ready: return readyLine(chords)
            }
        }
    }

    // A whole sentence either way: a suffix glued on cannot be translated.
    private static func readyLine(_ chords: Chords) -> String {
        if chords.accessibilityOff {
            return String(localized: "Hold \(chords.hold) to dictate, then press ⌘V")
        }
        if chords.secureKeyboardEntry {
            return String(localized: "Hold \(chords.hold) to dictate (Secure Keyboard Entry is on)")
        }
        return String(localized: "Hold \(chords.hold) to dictate")
    }

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

enum ProcessorText {
    static func name(_ id: String) -> String {
        switch id {
        case FillerRemover.processorID: String(localized: "Remove filler words")
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
            String(localized: "Drops “uh”, “um” and “äh”.")
        case DictionaryReplacer.processorID:
            String(localized: "Applies your replacement rules. Edit them in the Dictionary tab.")
        case CustomWordCorrector.processorID:
            String(localized: "Repairs near misses of the words you list in the Dictionary tab with an empty Heard as.")
        case WhitespaceNormalizer.processorID:
            String(localized: "Trims the transcript and collapses runs of spaces.")
        case SpokenPunctuation.processorID:
            String(localized: "Say “comma”, “question mark” or “new paragraph” to type them.")
        default: ""
        }
    }
}

extension HotkeyWarning {
    @MainActor var text: String {
        switch self {
        case .standIn(let stored, let standIn):
            String(localized: "Without Accessibility, \(stored.displayName) can’t be detected. \(standIn.sideAgnosticDisplayName) works in its place until you allow it.")
        case .systemShortcut(let owner, let chord):
            String(localized: "\(owner.sideAgnosticDisplayName) is a macOS keyboard shortcut, so \(chord.displayName) may never reach Pladder. Record another combination.")
        case .noModifier(let hotkey):
            String(localized: "Without a modifier, \(hotkey.displayName) can no longer be typed in other apps while Pladder is running.")
        case .toggleNeedsAccessibility(let toggle):
            String(localized: "Without Accessibility, \(toggle.displayName) can’t be detected, so the hands-free key is off until you allow it.")
        case .sendKeyNeedsAccessibility:
            String(localized: "The send key needs Accessibility.")
        case .sendKeyInsideChord(let key):
            String(localized: "\(key.displayName) is part of the talk key, so it can never be pressed separately.")
        }
    }
}
