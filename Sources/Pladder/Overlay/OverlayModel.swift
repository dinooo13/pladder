import SwiftUI
import PladderCore

// Apart from the coordinator, so the pill can keep showing what it was while it leaves.
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    var level: Float = 0
    var style: OverlayStyle = .compact
    var presentation: OverlayPresentation = .hidden
    var partialTranscript: String?
    init() {}
}

enum OverlayPresentation: Equatable {
    case hidden
    case flyingIn
    case settled
    case flyingOut
}

enum OverlayMotion {
    static let flightDuration: TimeInterval = 0.20

    // The controller waits exactly this long between the collapse and the dive, and the
    // content crossfade runs over the same span, so the two directions mirror each other.
    static let morphDuration: TimeInterval = 0.26

    // The bounce is kept small enough that the spring settles inside `morphDuration`.
    static let morphAnimation: Animation = .spring(duration: morphDuration, bounce: 0.12)

    // No bounce: a spring on opacity would dip past zero and flash the content back.
    static let contentFade: Animation = .easeInOut(duration: morphDuration)
}

enum OverlayPhase: Equatable {
    case empty
    case recording
    case transcribing
    case polishing
    case copied
    case error(DictationFailure)

    init(_ state: DictationState) {
        switch state {
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .polishing: self = .polishing
        case .copied: self = .copied
        // The controller never mirrors `.inserting`; only a preview gets here.
        case .inserting: self = .empty
        case .error(let failure): self = .error(failure)
        case .idle, .unavailable: self = .empty
        }
    }
}
