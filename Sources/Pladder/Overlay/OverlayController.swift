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
    private var running = false
    private var visible = false

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
        case .recording, .transcribing, .inserting:
            // Menu Bar relies on the menu bar glyph alone, so nothing is
            // presented. If the style was switched mid-dictation the pill may
            // already be up; fade it out the same way idle does.
            guard model.style != .menuBar else {
                if visible { scheduleHide(after: .milliseconds(400)) }
                return
            }
            model.state = state
            model.partialTranscript = coordinator.partialTranscript
            cancelHide()
            present()
        case .error:
            // Errors show in every style, Menu Bar included: a failed paste
            // must never be silent.
            model.state = state
            cancelHide()
            present()
            scheduleHide(after: .seconds(2))
        case .copied:
            // Same rule as an error: the text is on the clipboard and nothing
            // pasted it, so the user has to be told in every style. No hide is
            // scheduled here — the coordinator holds `.copied` for its display
            // duration and the `.idle` branch below fades the pill out.
            model.state = state
            cancelHide()
            present()
        case .idle, .unavailable:
            // Deliberately *not* updating the model here: `.inserting` now lasts
            // only a few milliseconds (the pasteboard restore no longer blocks
            // it), so swapping to the empty idle pill on the way out would make
            // the "Done" tick flash. Keep the last content on screen and let the
            // pill fade out with it; the next `present()` sets fresh content
            // before the panel is shown again.
            guard visible else { return }
            scheduleHide(after: .milliseconds(400))
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

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.visible else { return }
            self.visible = false
            self.panel.hide()
        }
    }
}
