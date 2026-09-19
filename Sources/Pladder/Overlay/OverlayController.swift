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
    private var spinnerTask: Task<Void, Never>?
    private var running = false
    private var visible = false

    /// How long transcription has to run before the pill comes back to say so.
    /// A normal dictation is pasted well inside this, and progress shown for
    /// work shorter than the indicator's own animation says nothing.
    private static let spinnerDelay: Duration = .milliseconds(300)

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
        cancelSpinner()
        hideTask?.cancel()
        panel.orderOut(nil)
        visible = false
    }

    /// Pushes the app's appearance onto the panel. Borderless panels that are
    /// never key or main do not reliably follow an `NSApp.appearance` change
    /// after creation, so it is set explicitly.
    func applyAppearance(_ appearance: Appearance) {
        model.appearance = appearance
        panel.appearance = appearance == .system ? NSApp.appearance : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }

    /// Pushes the overlay style and background choice onto the model, which
    /// the pill and the panel's size both read.
    func applyStyle(_ style: OverlayStyle, glass: Bool) {
        model.style = style
        model.glass = glass
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
        switch state {
        case .recording:
            cancelSpinner()
            // Menu Bar relies on the menu bar glyph alone, so nothing is
            // presented. If the style was switched mid-dictation the pill may
            // already be up; fade it out the same way idle does.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero) }
                return
            }
            model.state = state
            model.partialTranscript = coordinator.partialTranscript
            cancelHide()
            present()
        case .transcribing:
            // The pill fades out from the recording row it was showing at the
            // release, and the model is deliberately left alone so that is
            // what fades. The text normally lands before a "Transcribing…"
            // morph could even finish, and the paste is the confirmation.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .zero) }
                return
            }
            // A new partial can re-run this while the spinner is already
            // armed or on screen; only the first `.transcribing` acts.
            guard spinnerTask == nil else { return }
            if visible { scheduleHide(after: .zero) }
            // Only a transcription that outlasts the delay — a cold engine, a
            // long merge, a release inside a warm pass — brings the pill back.
            spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: Self.spinnerDelay)
                guard !Task.isCancelled, let self, self.running else { return }
                guard self.coordinator.state == .transcribing, self.model.style != .menuBar else { return }
                self.model.partialTranscript = nil
                self.model.state = .transcribing
                self.cancelHide()
                self.present()
            }
        case .inserting:
            // Milliseconds long, and `.idle` or `.copied` follows at once, so
            // nothing is shown and nothing is hidden here: hiding would
            // flicker between the paste and the clipboard hint.
            cancelSpinner()
        case .error:
            // Errors show in every style, Menu Bar included: a failed paste
            // must never be silent.
            cancelSpinner()
            model.state = state
            cancelHide()
            present()
            scheduleHide(after: .seconds(2))
        case .copied:
            // Same rule as an error: the text is on the clipboard and nothing
            // pasted it, so the user has to be told in every style. No hide is
            // scheduled here — the coordinator holds `.copied` for its display
            // duration and the `.idle` branch below fades the pill out.
            cancelSpinner()
            model.state = state
            cancelHide()
            present()
        case .idle, .unavailable:
            // Deliberately *not* updating the model here: the pill keeps
            // whatever it was showing — the recording row, the spinner, the
            // clipboard hint — and fades out with it. `scheduleHide` resets
            // the model once the panel is out.
            cancelSpinner()
            guard visible else { return }
            scheduleHide(after: .zero)
        }
    }

    private func present() {
        guard !visible else { return }
        visible = true
        panel.show()
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func cancelSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.visible else { return }
            self.visible = false
            self.panel.hide()
            // Once the panel is out, put the model back to idle. `OverlayPill`
            // restarts the Minimal dot and its pulse when the phase *leaves*
            // `.recording`, so a model left at the last recording level would
            // open the next take on bare bars. A press inside the fade cancels
            // this task, so that one take skips the dot intro.
            try? await Task.sleep(for: .seconds(OverlayPanel.fadeOutDuration))
            guard !Task.isCancelled, !self.visible else { return }
            self.model.state = .idle
            self.model.partialTranscript = nil
        }
    }
}
