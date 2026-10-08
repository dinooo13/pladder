import SwiftUI
import PladderCore

/// The state the overlay renders. Kept separate from the coordinator so the
/// panel can be driven independently (and shown while fading out after the
/// coordinator has already returned to `.idle`).
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    /// Appearance forced by the Appearance setting; `.system` means follow.
    /// AppKit's window propagation reaches a borderless panel inconsistently,
    /// so the color scheme is set in SwiftUI directly.
    var appearance: Appearance = .system
    /// Which pill the user picked. `.menuBar` never presents except for
    /// errors; the controller decides that, not the view.
    var style: OverlayStyle = .compact
    /// Liquid Glass behind the pill, or a flat window-background fill.
    var glass: Bool = true
    /// How fast the pill flies in and out.
    var speed: OverlayAnimationSpeed = .quick
    /// Where the pill is in the fly-in/fly-out presentation. The panel does
    /// the sliding below the screen edge; this phase keeps the pill as the
    /// Minimal disc whenever it is not settled, so it flies as the disc and
    /// morphs to its style's shape once it has arrived.
    var presentation: OverlayPresentation = .hidden
    /// What the engine has heard so far, for the Live Transcript style. Nil in
    /// every other style, and nil again the moment the key is released.
    var partialTranscript: String?
    init() {}
}

enum OverlayPresentation: Equatable {
    /// Off screen, parked as the disc so the next flight starts from it.
    case hidden
    /// Rising from the bottom edge as the disc; content forced to Minimal.
    case flyingIn
    /// At rest, in the style's own shape.
    case settled
    /// Collapsing to the disc, about to dive; content forced to Minimal.
    case flyingOut
}

/// The timing the animation setting maps to. Panel and view read the same
/// values so the slide and the morph stay in sync; the mapping lives here
/// because PladderCore never imports SwiftUI.
extension OverlayAnimationSpeed {
    /// How long the panel takes to slide up from (or back down behind) the
    /// bottom edge of the screen.
    var flightDuration: TimeInterval {
        switch self {
        case .instant: 0.06
        case .quick: 0.20
        case .expressive: 0.35
        }
    }

    /// How long the disc↔row morph takes, in both directions. Arrival is
    /// slide-up then expand; departure is collapse then slide-down. The
    /// controller waits exactly this long between the collapse and the dive,
    /// so the two directions are mirror images, and the content crossfade
    /// runs over the same span so what is inside the pill never outruns the
    /// pill.
    var morphDuration: TimeInterval {
        switch self {
        case .instant: 0.10
        case .quick: 0.26
        case .expressive: 0.5
        }
    }

    /// The spring the disc↔row geometry uses. A spring's duration is
    /// perceptual, so the bounce is kept small enough that the settle stays
    /// inside `morphDuration`.
    var morphAnimation: Animation {
        switch self {
        case .instant: .smooth(duration: morphDuration)
        case .quick: .spring(duration: morphDuration, bounce: 0.12)
        case .expressive: .spring(duration: morphDuration, bounce: 0.22)
        }
    }

    /// How the content arriving with a morph fades in: over the same span as
    /// the geometry, but no bounce, since a spring on opacity would dip past
    /// zero and flash the content back. What is leaving goes quickly instead
    /// (`OverlayPill.contentHandover`), so the eye never sees two dots.
    var contentFade: Animation { .easeInOut(duration: morphDuration) }
}

/// What the pill looks like, with the live audio level projected out.
///
/// `DictationState.recording` carries a level that changes many times a second.
/// Driving the capsule's morph animation off the state itself would restart
/// that animation on every meter update, so the morph animates on this
/// level-free phase instead while the bars animate on their own.
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
        // The controller never mirrors `.inserting` onto the model, so this
        // is only reached by a preview, and it draws nothing.
        case .inserting: self = .empty
        case .error(let failure): self = .error(failure)
        case .idle, .unavailable: self = .empty
        }
    }
}
