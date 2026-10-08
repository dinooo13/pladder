import AppKit
import Foundation
import Observation
import PladderCore

/// Mirrors the coordinator's state onto the overlay panel and decides when the
/// pill appears and disappears.
@MainActor
final class OverlayController {
    private let coordinator: DictationCoordinator
    private let model = OverlayModel()
    private lazy var panel = OverlayPanel(model: model)

    private var hideTask: Task<Void, Never>?
    private var presentTask: Task<Void, Never>?
    private var running = false
    private var visible = false
    /// The pill is being held up across a polish pass. It leaves by the dive
    /// like a pasted dictation, not by the fade, and that has to hold even
    /// when `.polishing` never comes: a transcript under the polish minimum
    /// is pasted straight from `.transcribing`.
    private var heldForPolish = false
    /// The pill gathered into the disc at the release before the text was
    /// pasted, and waits there with a spinner in it until the `.idle` branch
    /// sends it down. Diving at once and flying back up to say
    /// "Transcribing…" put one release through two exits.
    private var holdingDisc = false

    /// How long a press has to last before the pill appears. Cmd+C, Cmd+V and
    /// Cmd+Tab all begin with the same modifier as the default chord and are
    /// over well inside this, so the press the tracker is about to cancel
    /// never shows anything. A real dictation lasts far longer and pays for
    /// this only in seeing the pill a sixth of a second later.
    private static let presentDelay: Duration = .milliseconds(150)

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard !running else { return }
        running = true
        observe()
        apply(coordinator.state)
    }

    func stop() {
        running = false
        cancelPresent()
        hideTask?.cancel()
        panel.orderOut(nil)
        visible = false
        holdingDisc = false
    }

    /// Pushes the app's appearance onto the pill's SwiftUI scheme. The panel
    /// itself takes it at every `show`: a borderless panel that is never key
    /// or main does not reliably follow an `NSApp.appearance` change.
    func applyAppearance(_ appearance: Appearance) {
        model.appearance = appearance
    }

    /// Pushes the overlay style and background choice onto the model, which
    /// the pill and the panel's size both read.
    func applyStyle(_ style: OverlayStyle, glass: Bool) {
        model.style = style
        model.glass = glass
    }

    /// Pushes the animation speed onto the model; both the panel's slide and
    /// the pill's morph read it.
    func applySpeed(_ speed: OverlayAnimationSpeed) {
        model.speed = speed
    }

    /// `withObservationTracking` fires once per change, so we re-arm it every
    /// time. The callback runs *before* the new value is stored, hence the hop
    /// onto a task to read it.
    private func observe() {
        withObservationTracking {
            _ = coordinator.state
            // Read so a new partial re-arms this too: between two passes the
            // state stays `.recording` and nothing else would fire.
            _ = coordinator.partialTranscript
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.apply(self.coordinator.state)
                self.observe()
            }
        }
    }

    private func apply(_ state: DictationState) {
        // Anything but a recording supersedes a pill that has not appeared yet.
        if !state.isRecording { cancelPresent() }
        switch state {
        case .recording:
            heldForPolish = false
            // Menu Bar relies on the menu bar glyph alone, so nothing is
            // presented. If the style was switched mid-dictation the pill may
            // already be up; fade it out the same way idle does.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            model.state = state
            model.partialTranscript = coordinator.partialTranscript
            cancelHide()
            schedulePresent()
        case .transcribing:
            // The pill gathers into the disc from the recording row it was
            // showing at the release, and the model is deliberately left
            // alone so that is what gathers. The text normally lands inside
            // the gathering, the disc dives, and the paste is the
            // confirmation; a transcription that outlasts it holds the disc
            // (`scheduleHide`).
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            // A polish cycle is seconds, not milliseconds: the pill stays up
            // and says what is happening until `.idle` dives it out.
            if coordinator.willPolish {
                heldForPolish = true
                model.partialTranscript = nil
                model.state = .transcribing
                cancelHide()
                return
            }
            // A new partial can re-run this once the pill is on its way out;
            // only the first `.transcribing` acts. A pill that was never up
            // stays down: the paste is the confirmation.
            guard visible else { return }
            scheduleHide(after: .zero, flight: true)
        case .polishing:
            // Menu never shows the pill (errors aside), so a polish pass in
            // Menu style fades whatever may be on screen out.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            // Normally the pill is already up from `.transcribing` and this
            // only morphs it onto the Polishing row; `present` covers a
            // release inside the present delay, where it flies in fresh.
            heldForPolish = true
            model.state = state
            cancelHide()
            present(flight: true)
        case .inserting:
            // Milliseconds long, and `.idle` or `.copied` follows at once, so
            // nothing is shown and nothing is hidden here: hiding would
            // flicker between the paste and the clipboard hint.
            break
        case .error:
            // Errors show in every style, Menu Bar included: a failed paste
            // must never be silent. They fade in place rather than fly: an
            // alarm should be there at once, not arrive a moment later.
            heldForPolish = false
            model.state = state
            cancelHide()
            present(flight: false)
            scheduleHide(after: .seconds(2), flight: false)
        case .copied:
            // Same rule as an error: the text is on the clipboard and nothing
            // pasted it, so the user has to be told in every style. No hide is
            // scheduled here — the coordinator holds `.copied` for its display
            // duration and the `.idle` branch below hides the pill after it.
            model.state = state
            cancelHide()
            present(flight: false)
        case .idle, .unavailable:
            // Deliberately *not* updating the model here: the pill keeps
            // whatever it was showing — the recording row, the disc, the
            // clipboard hint — and leaves the screen with it. `scheduleHide`
            // resets the model once the panel is out. The clipboard hint
            // leaves the way a pasted dictation does, collapsing into the
            // disc and diving, so the two paths end alike, and so does a
            // pill held up across a polish pass; only a discarded recording
            // and an error fade in place.
            let flight = model.state == .copied || heldForPolish
            heldForPolish = false
            // The disc has already gathered and was waiting for this.
            if holdingDisc {
                holdingDisc = false
                hideTask?.cancel()
                hideTask = Task { [weak self] in await self?.dive() }
                return
            }
            guard visible else { return }
            scheduleHide(after: .zero, flight: flight)
        }
    }

    /// A flight presentation is the flying disc: the pill rises from the
    /// screen's bottom edge as the Minimal circle and expands into its
    /// style's shape on arrival. Errors and the clipboard hint skip the
    /// flight — they must be immediate — and fade in where the pill rests;
    /// the pill is parked as the disc while hidden, so they open out of it
    /// during the fade.
    private func present(flight: Bool) {
        guard !visible else { return }
        visible = true
        holdingDisc = false
        if flight {
            model.presentation = .flyingIn
            panel.show(flight: true) {
                // The view animates on every presentation change, so this
                // expands the disc into the style's shape. A release during
                // the flight has already gathered it for the dive, and a
                // waiting disc must not open into the row.
                guard self.visible else { return }
                self.model.presentation = .settled
            }
        } else {
            model.presentation = .settled
            panel.show(flight: false)
        }
    }

    /// Presents after `presentDelay`, unless the pill is already up (a press
    /// inside the previous take's fade-out, where waiting would blink it) or
    /// a wait is already running (a partial re-applying `.recording` must not
    /// push the appearance back again).
    private func schedulePresent() {
        guard !visible, presentTask == nil else { return }
        presentTask = Task { [weak self] in
            try? await Task.sleep(for: Self.presentDelay)
            guard !Task.isCancelled, let self, self.running else { return }
            self.presentTask = nil
            guard self.coordinator.state.isRecording, self.model.style != .menuBar else { return }
            self.cancelHide()
            self.present(flight: true)
        }
    }

    private func cancelPresent() {
        presentTask?.cancel()
        presentTask = nil
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// `flight` matches the presentation: a recording pill dives back down
    /// through the screen's bottom edge, anything else fades in place.
    private func scheduleHide(after delay: Duration, flight: Bool) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.visible else { return }
            self.visible = false
            if flight {
                // First the capsule gathers into the disc, then the panel
                // slides down behind the screen edge: the mirror of the
                // arrival, which slides up and then expands.
                self.model.presentation = .flyingOut
                try? await Task.sleep(for: .seconds(self.model.speed.morphDuration))
                guard !Task.isCancelled, !self.visible else { return }
                // Nothing pasted yet — a cold engine, a release inside an
                // engine pass — so the disc stays where it is, a spinner in
                // place of the wave, until the `.idle` branch sends it down.
                // The hint and an error open out of it in place.
                switch self.coordinator.state {
                case .transcribing, .polishing, .inserting, .copied, .error:
                    self.model.state = .transcribing
                    self.holdingDisc = true
                    return
                case .idle, .unavailable, .recording:
                    await self.dive()
                }
            } else {
                self.panel.hide(flight: false)
                try? await Task.sleep(for: .seconds(OverlayPanel.fadeOutDuration))
                guard !Task.isCancelled, !self.visible else { return }
                self.park()
            }
        }
    }

    /// Slides the gathered disc down behind the screen edge, then parks it.
    private func dive() async {
        panel.hide(flight: true)
        try? await Task.sleep(for: .seconds(model.speed.flightDuration))
        guard !Task.isCancelled, !visible else { return }
        park()
    }

    /// Once the panel is out, put the model back to idle. `OverlayPill`
    /// restarts the Minimal dot and its pulse when the phase *leaves*
    /// `.recording`, so a model left at the last recording level would open
    /// the next take on bare bars. A press inside the flight cancels the hide,
    /// so that one take skips the dot intro.
    private func park() {
        model.presentation = .hidden
        model.state = .idle
        model.partialTranscript = nil
    }
}
