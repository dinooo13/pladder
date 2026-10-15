import SwiftUI
import PladderCore

// Apart from the coordinator, so the pill can keep showing what it was while it leaves.
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    var level: Float = 0
    // AppKit reaches a borderless panel inconsistently, so the scheme is set in SwiftUI.
    var appearance: Appearance = .system
    var style: OverlayStyle = .compact
    var glass: Bool = true
    var speed: OverlayAnimationSpeed = .quick
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

// Here, because PladderCore never imports SwiftUI.
extension OverlayAnimationSpeed {
    var flightDuration: TimeInterval {
        switch self {
        case .instant: 0.06
        case .quick: 0.20
        case .expressive: 0.35
        }
    }

    // The controller waits exactly this long between the collapse and the dive, and the
    // content crossfade runs over the same span, so the two directions mirror each other.
    var morphDuration: TimeInterval {
        switch self {
        case .instant: 0.10
        case .quick: 0.26
        case .expressive: 0.5
        }
    }

    // The bounce is kept small enough that the spring settles inside `morphDuration`.
    var morphAnimation: Animation {
        switch self {
        case .instant: .smooth(duration: morphDuration)
        case .quick: .spring(duration: morphDuration, bounce: 0.12)
        case .expressive: .spring(duration: morphDuration, bounce: 0.22)
        }
    }

    // No bounce: a spring on opacity would dip past zero and flash the content back.
    var contentFade: Animation { .easeInOut(duration: morphDuration) }
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
