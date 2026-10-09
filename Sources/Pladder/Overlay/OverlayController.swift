import AppKit
import Foundation
import Observation
import PladderCore

// When the pill appears and how it leaves: docs/ARCHITECTURE.md, "The overlay".
@MainActor
final class OverlayController {
    private let coordinator: DictationCoordinator
    private let model = OverlayModel()
    private lazy var panel = OverlayPanel(model: model)

    private var hideTask: Task<Void, Never>?
    private var presentTask: Task<Void, Never>?
    private var running = false
    private var visible = false
    // A pill held up for polish leaves by the dive, even when `.polishing` never comes:
    // a transcript under the polish minimum is pasted straight from `.transcribing`.
    private var heldForPolish = false
    // The disc gathered at the release waits, with a spinner, for `.idle`: diving at once
    // and flying back up to say "Transcribing…" put one release through two exits.
    private var holdingDisc = false

    // Cmd+C, Cmd+V and Cmd+Tab share a lone-Command chord's modifier and are over well
    // inside this, so a press the tracker will cancel never shows the pill.
    private static let presentDelay: Duration = .milliseconds(150)

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard !running else { return }
        running = true
        observe()
        observeLevel()
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

    func applyAppearance(_ appearance: Appearance) {
        model.appearance = appearance
    }

    func applyStyle(_ style: OverlayStyle, glass: Bool) {
        model.style = style
        model.glass = glass
    }

    func applySpeed(_ speed: OverlayAnimationSpeed) {
        model.speed = speed
    }

    // Fires once, and before the new value is stored: re-armed every time, read on a task.
    private func observe() {
        withObservationTracking {
            _ = coordinator.state
            // Between two live passes the state stays `.recording`, so a new partial must re-arm.
            _ = coordinator.partialTranscript
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.apply(self.coordinator.state)
                self.observe()
            }
        }
    }

    // Its own loop: the level changes twenty times a second and only the bars need it.
    private func observeLevel() {
        withObservationTracking {
            _ = coordinator.inputLevel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                // Only while recording: the pill gathers from its last row, and the level dropping
                // to zero would flatten the bars mid-gather.
                if self.coordinator.state.isRecording {
                    self.model.level = self.coordinator.inputLevel
                }
                self.observeLevel()
            }
        }
    }

    private func apply(_ state: DictationState) {
        if !state.isRecording { cancelPresent() }
        switch state {
        case .recording:
            heldForPolish = false
            // Menu Bar shows nothing; a pill up from a style switch mid-dictation fades out.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            model.state = state
            model.partialTranscript = coordinator.partialTranscript
            cancelHide()
            schedulePresent()
        case .transcribing:
            // The model is left alone, so the recording row is what gathers into the disc; the
            // paste is the confirmation. A transcription that outlasts the gather holds the disc.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            // A polish takes seconds: the pill stays up and says so until `.idle` dives it out.
            if coordinator.willPolish {
                heldForPolish = true
                model.partialTranscript = nil
                model.state = .transcribing
                cancelHide()
                return
            }
            // Only the first `.transcribing` acts, and a pill that was never up stays down.
            guard visible else { return }
            scheduleHide(after: .zero, flight: true)
        case .polishing:
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero, flight: false) }
                return
            }
            // Normally a morph of the pill already up; `present` covers a release inside the
            // present delay, where it flies in fresh.
            heldForPolish = true
            model.state = state
            cancelHide()
            present(flight: true)
        case .inserting:
            // Milliseconds long; hiding here would flicker between the paste and the copy hint.
            break
        case .error:
            // In every style, Menu Bar included: a failed paste must never be silent. Fades in
            // place: an alarm should be there at once, not arrive a moment later.
            heldForPolish = false
            model.state = state
            cancelHide()
            present(flight: false)
            scheduleHide(after: .seconds(2), flight: false)
        case .copied:
            // The coordinator holds `.copied` for its duration; the `.idle` branch hides it.
            model.state = state
            cancelHide()
            present(flight: false)
        case .idle, .unavailable:
            // The model is not updated: the pill leaves with what it showed. The clipboard hint
            // and a pill held for polish dive like a pasted dictation; a discard and an error fade.
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

    // Errors and the clipboard hint skip the flight and fade in where the pill rests:
    // they must be immediate.
    private func present(flight: Bool) {
        guard !visible else { return }
        visible = true
        holdingDisc = false
        if flight {
            model.presentation = .flyingIn
            panel.show(flight: true) {
                // A release during the flight has already gathered the disc for the dive, and a
                // waiting disc must not open into the row.
                guard self.visible else { return }
                self.model.presentation = .settled
            }
        } else {
            model.presentation = .settled
            panel.show(flight: false)
        }
    }

    // Not when already up (a press inside the last fade-out would blink it) or already
    // waiting (a partial re-applying `.recording` must not push it back).
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

    private func scheduleHide(after delay: Duration, flight: Bool) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.visible else { return }
            self.visible = false
            if flight {
                self.model.presentation = .flyingOut
                try? await Task.sleep(for: .seconds(self.model.speed.morphDuration))
                guard !Task.isCancelled, !self.visible else { return }
                // Nothing pasted yet (a cold engine, a release inside an engine pass), so the disc
                // waits with a spinner until the `.idle` branch sends it down.
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

    private func dive() async {
        panel.hide(flight: true)
        try? await Task.sleep(for: .seconds(model.speed.flightDuration))
        guard !Task.isCancelled, !visible else { return }
        park()
    }

    // `OverlayPill` restarts the Minimal dot when the phase leaves `.recording`, so a model
    // left at the last recording would open the next take on bare bars.
    private func park() {
        model.presentation = .hidden
        model.state = .idle
        model.partialTranscript = nil
    }
}
