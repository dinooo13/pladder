import AppKit
import Foundation
import Observation
import SpeakUpCore

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

    /// `withObservationTracking` fires once per change, so we re-arm it every
    /// time. The callback runs *before* the new value is stored, hence the hop
    /// onto a task to read it.
    private func observe() {
        withObservationTracking {
            _ = coordinator.state
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
            model.state = state
            cancelHide()
            present()
        case .error:
            model.state = state
            cancelHide()
            present()
            scheduleHide(after: .seconds(2))
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
